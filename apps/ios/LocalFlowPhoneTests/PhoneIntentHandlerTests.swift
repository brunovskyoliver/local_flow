import XCTest

@testable import LocalFlow

/// The app's side of the intents (contracts/system-entry-points.md).
@MainActor
final class PhoneIntentHandlerTests: XCTestCase {
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var pasteboard: FakePasteboard!
  private var requester: FakeActivityRequester!
  private var center: FakeNotificationCenter!
  private var activity: ActivityController!
  private var handler: PhoneIntentHandler!
  private var notify = false
  private var keyboardResults: [SessionController.DictationResult] = []

  override func setUp() async throws {
    harness = try PhoneHarness()
    pasteboard = FakePasteboard()
    requester = FakeActivityRequester()
    center = FakeNotificationCenter()
    make(harness.makeController())
  }

  override func tearDown() async throws {
    handler = nil
    activity = nil
    controller = nil
    harness = nil
  }

  /// The app's wiring around one controller, as `PhoneApp` builds it.
  private func make(_ controller: SessionController) {
    self.controller = controller
    controller.onResult = { [unowned self] in keyboardResults.append($0) }
    activity = ActivityController(
      controller: controller, requester: requester,
      idleTimeout: { [unowned self] in harness.timeout }, now: { [unowned self] in harness.now })
    activity.start()
    handler = PhoneIntentHandler(
      controller: controller, dictations: harness.dictations, pasteboard: pasteboard,
      activity: activity,
      notifier: ResultNotifier(center: center, enabled: { [unowned self] in notify }))
  }

  private func dictate() async {
    let request = UUID()
    XCTAssertEqual(controller.start(requestID: request), .started)
    await controller.stop(requestID: request)
  }

  func testEndSessionEndsARunningSessionAndIsANoOpWithout() async {
    await handler.endSession()
    XCTAssertNil(controller.session)
    await controller.open(origin: .keyboard)
    await handler.endSession()
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertEqual(controller.session?.endReason, .userEnded)
    XCTAssertFalse(harness.capture.engineRunning)
  }

  func testCopyLastWritesTheLastResult() async throws {
    await harness.runtime.set(text: "the newest words")
    await controller.open(origin: .keyboard)
    await dictate()
    XCTAssertEqual(controller.lastResult?.text, "the newest words")
    let copied = try await handler.copyLast()
    XCTAssertTrue(copied)
    XCTAssertEqual(pasteboard.string, "the newest words")
  }

  func testCopyLastReadsHistoryAfterARelaunch() async throws {
    await harness.runtime.set(text: "from before the relaunch")
    await controller.open(origin: .keyboard)
    await dictate()
    let relaunched = harness.makeController()
    XCTAssertNil(relaunched.lastResult)
    make(relaunched)
    _ = try await handler.copyLast()
    XCTAssertEqual(pasteboard.string, "from before the relaunch")
  }

  func testCopyLastWithNothingThrows() async {
    do {
      _ = try await handler.copyLast()
      XCTFail("copied nothing")
    } catch LocalFlowIntentError.nothingToCopy {
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertTrue(pasteboard.attempts.isEmpty)
  }

  /// R4: iOS drops background writes. The newest text waits for LocalFlow to be active.
  func testADroppedWriteIsAppliedWhenTheAppBecomesActive() async throws {
    await harness.runtime.set(text: "first")
    await controller.open(origin: .keyboard)
    await dictate()
    pasteboard.accepts = false
    let copied = try await handler.copyLast()
    XCTAssertFalse(copied)
    await harness.runtime.set(text: "second")
    await dictate()
    _ = try await handler.copyLast()
    XCTAssertNil(pasteboard.string)
    pasteboard.accepts = true
    await handler.becameActive()
    XCTAssertEqual(pasteboard.string, "second", "newest wins")
    await handler.becameActive()
    XCTAssertEqual(pasteboard.attempts.filter { $0 == "second" }.count, 2, "applied once")
  }

  // MARK: The control (User Story 6, research R1)

  private func toggle() async throws -> ToggleOutcome { try await handler.toggleDictation() }

  private func refused(_ expected: LocalFlowIntentError) async {
    do {
      _ = try await toggle()
      XCTFail("toggle went through")
    } catch let error as LocalFlowIntentError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("\(error)")
    }
  }

  /// Spool folders left in `TemporaryAudio/`, one per kept dictation.
  private func spools() -> [URL] {
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: harness.spoolRoot, includingPropertiesForKeys: nil)) ?? []
    return items.filter { UUID(uuidString: $0.lastPathComponent) != nil }
  }

  private func blockSaves(_ blocked: Bool) throws {
    try harness.history.database.write { db in
      try db.execute(
        sql: blocked
          ? "CREATE TRIGGER locked BEFORE INSERT ON phone_dictations BEGIN SELECT RAISE(ABORT, 'locked'); END"
          : "DROP TRIGGER locked")
    }
  }

  func testToggleWithNoSessionStartsAControlSessionAfterItsActivity() async throws {
    let outcome = try await toggle()
    XCTAssertEqual(outcome, .started)
    XCTAssertEqual(controller.session?.origin, .control)
    XCTAssertEqual(controller.session?.state, .recording)
    XCTAssertEqual(controller.sessionFile()?.dictationSource, .control)
    XCTAssertEqual(requester.calls.first, .request(.control, .init(phase: .idle)))
    XCTAssertEqual(requester.updates.map(\.phase), [.recording])
  }

  func testToggleInAReadySessionRecordsThereAndKeepsItsOrigin() async throws {
    await controller.open(origin: .keyboard)
    let started = try await toggle()
    XCTAssertEqual(started, .started)
    XCTAssertEqual(controller.session?.origin, .keyboard)
    XCTAssertEqual(controller.sessionFile()?.dictationSource, .control)
    let stopped = try await toggle()
    XCTAssertEqual(stopped, .stopped)
    XCTAssertEqual(controller.session?.state, .ready, "the keyboard session goes on")
    XCTAssertTrue(keyboardResults.isEmpty, "a control result never goes to result.json")
    let id = try XCTUnwrap(controller.lastResult?.dictationID)
    XCTAssertEqual(try harness.row(id)?["source"] as String?, "control")
    XCTAssertEqual(requester.requests.count, 1)
    guard case .request(let kind, _) = requester.requests.first else { return XCTFail() }
    XCTAssertEqual(kind, .session, "the session's own activity, not a second one")
  }

  func testToggleDuringAKeyboardRecordingStopsItIntoTheKeyboard() async throws {
    await controller.open(origin: .keyboard)
    let request = UUID()
    XCTAssertEqual(controller.start(requestID: request), .started)
    let outcome = try await toggle()
    XCTAssertEqual(outcome, .stopped)
    let result = try XCTUnwrap(keyboardResults.first)
    XCTAssertEqual(result.requestID, request)
    XCTAssertEqual(try harness.row(result.dictationID)?["source"] as String?, "keyboard")
    XCTAssertTrue(pasteboard.attempts.isEmpty)
  }

  /// A finished control dictation: History, then the clipboard, then `copied`; the
  /// activity ends on its result card and the notification goes out when allowed.
  func testAControlDictationIsSavedCopiedAndShownOnTheResultCard() async throws {
    let text = String(repeating: "word ", count: 40)
    await harness.runtime.set(text: text)
    notify = true
    _ = try await toggle()
    harness.now += 15
    let outcome = try await toggle()
    XCTAssertEqual(outcome, .stopped)
    XCTAssertEqual(controller.session?.endReason, .afterOneDictation)
    let result = try XCTUnwrap(controller.lastResult)
    XCTAssertEqual(pasteboard.string, result.text)
    let row = try XCTUnwrap(try harness.row(result.dictationID))
    XCTAssertEqual(row["source"] as String?, "control")
    XCTAssertEqual(row["delivery"] as String?, "copied")
    XCTAssertEqual(row["delivery_state"] as String?, "not_inserted")
    let card = DictationActivityAttributes.ContentState(
      phase: .result, preview: String(result.text.prefix(120)), canCopy: true)
    XCTAssertEqual(card.preview?.count, 120)
    XCTAssertEqual(
      requester.calls.last, .end(card, .after(harness.now.addingTimeInterval(5 * 60))))
    let note = try XCTUnwrap(center.requests.first)
    XCTAssertEqual(note.content.title, "LocalFlow note")
    XCTAssertEqual(note.content.body, String(result.text.prefix(120)))
    XCTAssertEqual(note.content.threadIdentifier, "localflow.dictation")
    XCTAssertEqual(note.content.categoryIdentifier, ResultNotifier.category)
    XCTAssertNotNil(handler.lastControlStopToResult)
  }

  /// The previous note's result card goes before the next recording's activity, so the
  /// Lock Screen never shows old text over a new recording.
  func testANewControlRecordingDismissesTheLastResultCard() async throws {
    _ = try await toggle()
    _ = try await toggle()
    XCTAssertTrue(requester.isShowing, "the result card stays up")
    let before = requester.calls.count
    _ = try await toggle()
    let next = Array(requester.calls[before...])
    XCTAssertEqual(next.first, .end(nil, .immediate))
    XCTAssertEqual(next.filter { if case .request = $0 { true } else { false } }.count, 1)
  }

  /// R4: the write is dropped in the background. The row stays `saved_only` until the
  /// held write lands with LocalFlow active.
  func testADroppedControlWriteStaysSavedOnlyUntilLocalFlowIsActive() async throws {
    pasteboard.accepts = false
    _ = try await toggle()
    _ = try await toggle()
    let id = try XCTUnwrap(controller.lastResult?.dictationID)
    XCTAssertEqual(try harness.row(id)?["delivery"] as String?, "saved_only")
    guard case .end(let card?, _) = requester.calls.last else { return XCTFail("not ended") }
    XCTAssertEqual(card.phase, .result)
    XCTAssertEqual(card.message, ActivityController.copyLater)
    XCTAssertTrue(center.requests.isEmpty, "notifications are off by default")
    pasteboard.accepts = true
    await handler.becameActive()
    XCTAssertEqual(pasteboard.string, controller.lastResult?.text)
    XCTAssertEqual(try harness.row(id)?["delivery"] as String?, "copied")
  }

  /// FR-030: no visible activity, no recording.
  func testToggleIsRefusedWithoutALiveActivity() async throws {
    requester.areActivitiesEnabled = false
    await refused(.liveActivitiesOff)
    XCTAssertNil(controller.session)
    requester.areActivitiesEnabled = true
    requester.requestFails = true
    await refused(.liveActivitiesOff)
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertNil(controller.current)
    XCTAssertFalse(harness.capture.engineRunning)
    XCTAssertTrue(spools().isEmpty)
  }

  func testMissingModelOrMicrophoneRefusesAndNotifiesOnlyWhenAllowed() async throws {
    harness.modelReady = false
    await refused(.modelMissing)
    XCTAssertTrue(center.requests.isEmpty)
    notify = true
    await refused(.modelMissing)
    XCTAssertEqual(center.requests.count, 1)
    harness.modelReady = true
    harness.capture.permission = false
    await refused(.microphoneDenied)
    XCTAssertEqual(center.requests.count, 2)
    center.status = .denied
    await refused(.microphoneDenied)
    XCTAssertEqual(center.requests.count, 2)
    XCTAssertTrue(requester.requests.isEmpty)
  }

  /// Before the first unlock History cannot be written. The text and its spool wait;
  /// the next toggle says why it cannot start.
  func testAPendingSaveBlocksTheNextToggleUntilItIsSaved() async throws {
    try blockSaves(true)
    _ = try await toggle()
    _ = try await toggle()
    let id = try XCTUnwrap(controller.lastResult?.dictationID)
    XCTAssertEqual(controller.pendingSave?.dictation.id, id)
    XCTAssertEqual(try harness.rowCount(), 0)
    XCTAssertEqual(spools().count, 1, "the spool stays until the save")
    await refused(.pendingSave)
    await controller.retryPendingSave()
    XCTAssertEqual(controller.pendingSave?.dictation.id, id, "still locked")
    try blockSaves(false)
    await controller.retryPendingSave()
    XCTAssertNil(controller.pendingSave)
    XCTAssertEqual(try harness.row(id)?["source"] as String?, "control")
    XCTAssertTrue(spools().isEmpty)
    let outcome = try await toggle()
    XCTAssertEqual(outcome, .started)
  }

  /// If the process ends first, 016 recovery finds the spool on the next launch.
  func testAPendingSaveLeftByAProcessDeathIsAnOrphan() async throws {
    try blockSaves(true)
    _ = try await toggle()
    _ = try await toggle()
    handler = nil
    activity = nil
    controller = nil
    let orphans = OrphanSpoolRecovery(root: harness.spoolRoot)
    orphans.adopt()
    XCTAssertTrue(orphans.hasOrphan)
  }

  /// FR-032: one recording at a time.
  func testAKeyboardStartDuringAControlRecordingIsBusy() async throws {
    _ = try await toggle()
    XCTAssertEqual(controller.start(requestID: UUID()), .busy)
    XCTAssertEqual(controller.sessionFile()?.dictationSource, .control)
  }
}
