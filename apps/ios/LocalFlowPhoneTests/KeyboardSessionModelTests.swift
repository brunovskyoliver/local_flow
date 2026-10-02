import XCTest

@testable import LocalFlow

@MainActor
final class KeyboardSessionModelTests: XCTestCase {
  private final class Host: KeyboardHost {
    var documentID: UUID? = UUID()
    var text = ""
    var contextBefore: String? { text }
    func insert(_ text: String) { self.text += text }
    func deleteBackward(_ count: Int) { text = String(text.dropLast(count)) }
  }

  private var store: HandoffStore!
  private var rung: [Bell] = []
  private var scheduled: [(Duration, @MainActor () -> Void)] = []
  private var now = Date(timeIntervalSince1970: 1_790_000_000)
  private let host = Host()
  private let sessionID = UUID()

  override func setUp() async throws {
    store = HandoffStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "keyboard-\(UUID().uuidString)", isDirectory: true))
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: store.directory) }

  private func model(fullAccess: Bool = true) -> KeyboardSessionModel {
    let model = KeyboardSessionModel(
      hasFullAccess: fullAccess, store: store, ring: { [unowned self] in rung.append($0) },
      now: { [unowned self] in now }, schedule: { [unowned self] in scheduled.append(($0, $1)) })
    model.host = host
    return model
  }

  private func writeSession(
    _ state: SessionFile.State, lastRequest: UUID? = nil, outcome: SessionFile.Outcome? = nil,
    source: SessionFile.Source? = nil, recordingStartedAt: Date? = nil, inputName: String? = nil
  ) throws {
    try store.write(
      SessionFile(
        sessionID: sessionID, state: state, idleTimeout: "5m", lastRequestID: lastRequest,
        lastOutcome: outcome, updatedAt: 0,
        recordingStartedAt: recordingStartedAt.map(Handoff.milliseconds), inputName: inputName,
        dictationSource: source ?? (state == .recording ? .keyboard : nil)), .session)
  }

  private func result(_ requestID: UUID, _ text: String) -> ResultFile {
    ResultFile(
      requestID: requestID, dictationID: UUID(), text: text, limitReached: false,
      createdAt: Handoff.milliseconds(now))
  }

  private func runScheduled(_ delay: Duration) {
    let due = scheduled.filter { $0.0 == delay }
    scheduled.removeAll { $0.0 == delay }
    for (_, action) in due { action() }
  }

  /// Appears, gets a pong, and starts a dictation from a `ready` session.
  private func startedModel() throws -> (KeyboardSessionModel, UUID) {
    try writeSession(.ready)
    let model = model()
    model.appear()
    model.pong()
    XCTAssertEqual(model.tap(), .none)
    let request = try XCTUnwrap(store.read(RequestFile.self, .request))
    return (model, request.requestID)
  }

  func testNoPongMeansNoSession() throws {
    try writeSession(.ready)
    let model = model()
    model.appear()
    XCTAssertEqual(rung, [.ping])
    XCTAssertEqual(model.sessionView, .unknown)
    runScheduled(KeyboardSessionModel.pongTimeout)
    XCTAssertEqual(model.sessionView, .none)
    guard case .openApp(let url) = model.tap() else { return XCTFail("expected open") }
    XCTAssertEqual(url.host(), "session")
    XCTAssertEqual(url.path(), "/start")
  }

  func testMissingOrEndedSessionFileMeansNoSession() throws {
    let model = model()
    model.appear()
    model.pong()
    XCTAssertEqual(model.sessionView, .none)
    try writeSession(.ended)
    model.refresh()
    XCTAssertEqual(model.sessionView, .none)
  }

  func testRecordingShowsOnlyAfterTheAppSaysSo() throws {
    let (model, requestID) = try startedModel()
    let request = try XCTUnwrap(store.read(RequestFile.self, .request))
    XCTAssertEqual(request.kind, .start)
    XCTAssertEqual(request.sessionID, sessionID)
    XCTAssertEqual(rung.last, .request)
    XCTAssertEqual(model.sessionView, .working)
    try writeSession(.recording)
    model.refresh()
    XCTAssertEqual(model.sessionView, .recording)
    _ = model.tap()
    let stop = try XCTUnwrap(store.read(RequestFile.self, .request))
    XCTAssertEqual(stop.kind, .stop)
    XCTAssertEqual(stop.requestID, requestID)
    XCTAssertEqual(model.sessionView, .working)
  }

  func testNoResultFifteenSecondsAfterStopSaysLocalFlowStopped() throws {
    let (model, _) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    _ = model.tap()
    runScheduled(KeyboardSessionModel.resultTimeout)
    XCTAssertEqual(rung.last, .ping)
    runScheduled(KeyboardSessionModel.pongTimeout)
    XCTAssertEqual(model.message, KeyboardSessionModel.stoppedMessage)
    XCTAssertNil(model.pending)
  }

  /// A first model load after an install takes up to a minute; a live LocalFlow that is
  /// still finishing keeps the keyboard waiting, up to `resultWaits` rounds.
  func testAnsweredResultTimeoutKeepsWaitingThenGivesUp() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    _ = model.tap()
    try writeSession(.finishing)
    for _ in 0..<KeyboardSessionModel.resultWaits {
      runScheduled(KeyboardSessionModel.resultTimeout)
      model.pong()
      runScheduled(KeyboardSessionModel.pongTimeout)
      XCTAssertEqual(model.surface, .transcribing)
    }
    try store.write(result(requestID, "Late."), .result)
    model.checkResult()
    XCTAssertEqual(host.text, "Late.")

    let (other, _) = try startedModel()
    try writeSession(.recording)
    other.refresh()
    _ = other.tap()
    try writeSession(.finishing)
    for _ in 0..<KeyboardSessionModel.resultWaits {
      runScheduled(KeyboardSessionModel.resultTimeout)
      other.pong()
    }
    runScheduled(KeyboardSessionModel.resultTimeout)
    XCTAssertEqual(other.message, KeyboardSessionModel.stoppedMessage)
  }

  func testMatchingOutcomeShowsItsMessageAndOtherOutcomesAreIgnored() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.ready, lastRequest: UUID(), outcome: .empty)
    model.refresh()
    XCTAssertNil(model.message)
    XCTAssertNotNil(model.pending)
    try writeSession(.ready, lastRequest: requestID, outcome: .empty)
    model.refresh()
    XCTAssertEqual(model.surface, .notice(.nothingHeard))
    XCTAssertNil(model.pending)
    XCTAssertEqual(model.sessionView, .ready)
  }

  func testMatchingResultIsInsertedAndAcknowledged() throws {
    let (model, requestID) = try startedModel()
    let result = ResultFile(
      requestID: requestID, dictationID: UUID(), text: "Hello there.", limitReached: false,
      createdAt: Handoff.milliseconds(now))
    try store.write(result, .result)
    model.checkResult()
    XCTAssertEqual(host.text, "Hello there.")
    XCTAssertEqual(store.read(DeliveryFile.self, .delivery)?.delivery, .inserted)
    XCTAssertEqual(rung.last, .delivery)
    XCTAssertTrue(model.canUndo)
    model.undo()
    XCTAssertEqual(host.text, "")
    model.checkResult()
    XCTAssertEqual(host.text, "", "a handled result is not inserted twice")
  }

  func testChangedDocumentOffersTheResult() throws {
    let (model, requestID) = try startedModel()
    host.documentID = UUID()
    let result = ResultFile(
      requestID: requestID, dictationID: UUID(), text: "Offered.", limitReached: false,
      createdAt: Handoff.milliseconds(now))
    try store.write(result, .result)
    model.checkResult()
    XCTAssertEqual(host.text, "")
    XCTAssertEqual(model.offered, result)
    XCTAssertEqual(store.read(DeliveryFile.self, .delivery)?.delivery, .offered)
    model.insertOffered()
    XCTAssertEqual(host.text, "Offered.")
    XCTAssertEqual(store.read(DeliveryFile.self, .delivery)?.delivery, .inserted)
  }

  func testOldResultIsNotOffered() throws {
    try store.write(
      ResultFile(
        requestID: UUID(), dictationID: UUID(), text: "Old.", limitReached: false,
        createdAt: Handoff.milliseconds(now) - Handoff.resultLifetime), .result)
    let model = model()
    model.appear()
    XCTAssertNil(model.offered)
    XCTAssertEqual(host.text, "")
  }

  func testWithoutFullAccessNothingIsWritten() throws {
    let model = model(fullAccess: false)
    model.appear()
    XCTAssertEqual(model.sessionView, .none)
    XCTAssertEqual(model.tap(), .none)
    XCTAssertEqual(model.surface, .notice(.fullAccess))
    XCTAssertEqual(model.openSettings(), .none)
    XCTAssertTrue(rung.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
  }

  /// FR-009: a session that ended for a missing model or microphone says to open the app.
  func testEndedSessionForAMissingPrerequisiteShowsAHint() throws {
    try store.write(
      SessionFile(
        sessionID: sessionID, state: .ended, idleTimeout: "5m", endReason: .modelUnavailable,
        updatedAt: 0), .session)
    let model = model()
    model.appear()
    model.pong()
    XCTAssertEqual(model.sessionView, .none)
    XCTAssertEqual(model.message, KeyboardSessionModel.hint(for: .modelUnavailable))
    XCTAssertNotNil(KeyboardSessionModel.hint(for: .permissionDenied))
    XCTAssertNil(KeyboardSessionModel.hint(for: .idleTimeout))
  }

  // MARK: Feature 017 (US2, US3)

  func testEndSessionWritesEndForTheCurrentSession() throws {
    try writeSession(.ready)
    let model = model()
    model.appear()
    model.pong()
    model.endSession()
    let request = try XCTUnwrap(store.read(RequestFile.self, .request))
    XCTAssertEqual(request.kind, .end)
    XCTAssertEqual(request.sessionID, sessionID)
    XCTAssertEqual(rung.last, .request)
  }

  func testInsertLastDictationReinsertsTheLastKeyboardResult() throws {
    let (model, requestID) = try startedModel()
    XCTAssertNil(model.lastInserted)
    try store.write(result(requestID, "Hello."), .result)
    model.checkResult()
    XCTAssertEqual(model.lastInserted, "Hello.")
    model.insertLast()
    XCTAssertEqual(host.text, "Hello.Hello.")
    model.undo()
    XCTAssertEqual(host.text, "Hello.", "Undo removes exactly the reinserted text")
  }

  func testOfferedResultBecomesTheLastDictation() throws {
    let (model, requestID) = try startedModel()
    host.documentID = UUID()
    try store.write(result(requestID, "Offered."), .result)
    model.checkResult()
    XCTAssertEqual(model.lastInserted, "Offered.")
    model.insertLast()
    XCTAssertEqual(host.text, "Offered.")
    XCTAssertEqual(store.read(DeliveryFile.self, .delivery)?.delivery, .inserted)
  }

  func testListeningStraightAfterTheTapThenRecordingDetails() throws {
    let (model, _) = try startedModel()
    XCTAssertEqual(model.surface, .listening(startedAt: nil, inputName: nil))
    let started = now.addingTimeInterval(-1)
    try writeSession(.recording, recordingStartedAt: started, inputName: "iPhone Microphone")
    model.refresh()
    XCTAssertEqual(
      model.surface,
      .listening(
        startedAt: Date(timeIntervalSince1970: Double(Handoff.milliseconds(started)) / 1000),
        inputName: "iPhone Microphone"))
  }

  func testNoRecordingWithinTwoSecondsMeansNotRunning() throws {
    let (model, _) = try startedModel()
    XCTAssertEqual(model.startSentAt, now)
    runScheduled(KeyboardSessionModel.startTimeout)
    XCTAssertEqual(model.surface, .notice(.notRunning))
    XCTAssertNil(model.pending)
    model.dismissNotice()
    guard case .openApp(let url) = model.tap() else { return XCTFail("expected open") }
    XCTAssertEqual(url.host(), "session")
  }

  func testRecordingWithinTwoSecondsKeepsListening() throws {
    let (model, _) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    runScheduled(KeyboardSessionModel.startTimeout)
    if case .listening = model.surface {} else { XCTFail("expected listening") }
  }

  func testBusySaysRecordingElsewhereAndReturnsToKeys() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.recording, lastRequest: requestID, outcome: .busy, source: .control)
    model.refresh()
    XCTAssertEqual(model.surface, .keys)
    XCTAssertEqual(model.message, BarStatus.elsewhere)
    XCTAssertEqual(model.barStatus(now: now), BarStatus.elsewhere)
  }

  func testCancelReturnsToKeysAndIgnoresALateResult() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    model.cancel()
    let cancel = try XCTUnwrap(store.read(RequestFile.self, .request))
    XCTAssertEqual(cancel.kind, .cancel)
    XCTAssertEqual(cancel.requestID, requestID)
    XCTAssertEqual(model.surface, .keys)
    try store.write(result(requestID, "Late."), .result)
    model.checkResult()
    XCTAssertEqual(host.text, "")
    XCTAssertNil(model.offered)
  }

  func testTranscribingFromStopUntilTheResult() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    _ = model.tap()
    XCTAssertEqual(model.surface, .transcribing)
    try writeSession(.finishing)
    model.refresh()
    XCTAssertEqual(model.surface, .transcribing)
    try store.write(result(requestID, "Done."), .result)
    model.checkResult()
    XCTAssertEqual(model.surface, .keys)
  }

  func testTranscribingEndsAfterTheResultTimeout() throws {
    let (model, _) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    _ = model.tap()
    runScheduled(KeyboardSessionModel.resultTimeout)
    runScheduled(KeyboardSessionModel.pongTimeout)
    XCTAssertEqual(model.surface, .keys)
  }

  func testNothingHeardAndFailedClearAfterFourSecondsOrATap() throws {
    var (model, requestID) = try startedModel()
    try writeSession(.ready, lastRequest: requestID, outcome: .empty)
    model.refresh()
    XCTAssertEqual(model.surface, .notice(.nothingHeard))
    runScheduled(KeyboardSessionModel.noticeTimeout)
    XCTAssertEqual(model.surface, .keys)

    (model, requestID) = try startedModel()
    try writeSession(.ready, lastRequest: requestID, outcome: .failed)
    model.refresh()
    guard case .notice(.failed) = model.surface else { return XCTFail("expected failed") }
    model.dismissNotice()
    XCTAssertEqual(model.surface, .keys)
  }

  func testDisappearingWhileRecordingSendsStop() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.recording)
    model.refresh()
    model.stop()
    let stop = try XCTUnwrap(store.read(RequestFile.self, .request))
    XCTAssertEqual(stop.kind, .stop)
    XCTAssertEqual(stop.requestID, requestID)
    rung.removeAll()
    model.stop()
    XCTAssertTrue(rung.isEmpty, "a stopped request is not stopped twice")
  }
}
