import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class SessionControllerTests: XCTestCase {
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var results: [SessionController.DictationResult] = []

  override func setUp() async throws {
    harness = try PhoneHarness()
    controller = harness.makeController()
    controller.onResult = { [unowned self] in results.append($0) }
  }

  override func tearDown() async throws {
    controller = nil
    harness = nil
  }

  private func dictate(_ request: UUID = UUID(), end: CaptureEnd = .stopped) async {
    XCTAssertEqual(controller.start(requestID: request), .started)
    if end == .stopped {
      await controller.stop(requestID: request)
    } else {
      await controller.finish(end)
    }
  }

  func testStartingEndsWithoutModelMicrophoneOrEngine() async {
    harness.modelReady = false
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.endReason, .modelUnavailable)
    harness.modelReady = true
    harness.capture.permission = false
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.endReason, .permissionDenied)
    harness.capture.permission = true
    harness.capture.startFails = true
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.endReason, .audioFailure)
    XCTAssertTrue(harness.keepReady.holders.isEmpty)
  }

  func testDictationReturnsToReadyWithAFreshDeadline() async throws {
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertEqual(harness.keepReady.holders, [.session])
    let request = UUID()
    controller.start(requestID: request)
    XCTAssertEqual(controller.session?.state, .recording)
    XCTAssertNil(controller.session?.idleDeadline)
    harness.now += 30
    await controller.stop(requestID: request)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertEqual(controller.session?.idleDeadline, harness.now.addingTimeInterval(300))
    let result = try XCTUnwrap(results.first)
    XCTAssertEqual(result.requestID, request)
    XCTAssertFalse(result.limitReached)
    let row = try XCTUnwrap(try harness.row(result.dictationID))
    XCTAssertEqual(row["source"] as String?, "keyboard")
    XCTAssertEqual(row["delivery"] as String?, "saved_only")
    XCTAssertEqual(row["delivery_state"] as String?, "not_inserted")
    XCTAssertEqual(row["recovery_state"] as String?, "resolved")
  }

  func testAfterOneDictationEndsTheSession() async {
    harness.timeout = .afterOne
    await controller.open(origin: .keyboard)
    await dictate()
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertEqual(controller.session?.endReason, .afterOneDictation)
    XCTAssertFalse(harness.capture.engineRunning)
  }

  func testInAppSessionEndsAfterItsDictationEvenWithAnHourTimeout() async {
    harness.timeout = .oneHour
    await controller.open(origin: .app)
    await dictate()
    XCTAssertEqual(controller.session?.endReason, .afterOneDictation)
  }

  func testBusyAndNoSessionAreReportedInSessionFile() async {
    let lonely = UUID()
    XCTAssertEqual(controller.start(requestID: lonely), .noSession)
    await controller.open(origin: .keyboard)
    controller.start(requestID: UUID())
    let second = UUID()
    XCTAssertEqual(controller.start(requestID: second), .busy)
    XCTAssertEqual(controller.sessionFile()?.lastRequestID, second)
    XCTAssertEqual(controller.sessionFile()?.lastOutcome, .busy)
  }

  func testMismatchedStopIsIgnored() async {
    await controller.open(origin: .keyboard)
    controller.start(requestID: UUID())
    await controller.stop(requestID: UUID())
    XCTAssertEqual(controller.session?.state, .recording)
  }

  func testSilenceReportsEmptyAndSavesNothing() async throws {
    await harness.runtime.set(text: " ")
    await controller.open(origin: .keyboard)
    let request = UUID()
    await dictate(request)
    XCTAssertTrue(results.isEmpty)
    XCTAssertEqual(controller.sessionFile()?.lastOutcome, .empty)
    XCTAssertEqual(controller.sessionFile()?.lastRequestID, request)
    XCTAssertEqual(try harness.rowCount(), 0)
  }

  func testLimitAndOverflowEndTheDictationAndKeepTheText() async throws {
    await controller.open(origin: .keyboard)
    await dictate(end: .durationLimit)
    let limited = try XCTUnwrap(results.last)
    XCTAssertTrue(limited.limitReached)
    let limitedRow = try XCTUnwrap(try harness.row(limited.dictationID))
    XCTAssertEqual(limitedRow["stop_reason"] as String?, "duration_limit")
    XCTAssertEqual(limitedRow["end_detail"] as String?, "limit_reached")
    await dictate(end: .overflow)
    let overflow = try XCTUnwrap(results.last)
    XCTAssertEqual(try harness.row(overflow.dictationID)?["stop_reason"] as String?, "overflow")
  }

  func testIdleDeadlineEndsTheSessionOnTheNextTick() async {
    await controller.open(origin: .keyboard)
    harness.now += 299
    controller.tick()
    XCTAssertEqual(controller.session?.state, .ready)
    harness.now += 1
    controller.tick()
    XCTAssertEqual(controller.session?.endReason, .idleTimeout)
    XCTAssertFalse(harness.capture.engineRunning)
    XCTAssertTrue(harness.keepReady.holders.isEmpty)
  }

  func testInterruptionWhileRecordingSavesThenEnds() async throws {
    await controller.open(origin: .keyboard)
    controller.start(requestID: UUID())
    harness.capture.onInterruption?()
    for _ in 0..<50 where controller.session?.state != .ended {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(controller.session?.endReason, .interrupted)
    let result = try XCTUnwrap(results.first)
    XCTAssertEqual(try harness.row(result.dictationID)?["end_detail"] as String?, "interrupted")
  }

  func testMemoryWarningDropsKeepReadyOnlyWhenNotRecording() async {
    await controller.open(origin: .keyboard)
    controller.start(requestID: UUID())
    controller.memoryWarning()
    XCTAssertEqual(harness.keepReady.holders, [.session])
    await controller.finish(.stopped)
    controller.memoryWarning()
    XCTAssertTrue(harness.keepReady.holders.isEmpty)
  }

  func testEndReleasesTheSessionHoldButNotTheDictateScreen() async {
    harness.keepReady.hold(.dictateScreen)
    await controller.open(origin: .keyboard)
    controller.end(.userEnded)
    XCTAssertEqual(harness.keepReady.holders, [.dictateScreen])
    XCTAssertFalse(harness.capture.engineRunning)
  }

  func testEachDictationUsesTheDictionaryCurrentAtStop() async throws {
    await controller.open(origin: .keyboard)
    await dictate()
    _ = try await harness.vocabulary.save(VocabularyEntry(canonical: "Zabbix"))
    await dictate()
    let keys = await harness.runtime.boostKeys
    XCTAssertEqual(keys.count, 2)
    XCTAssertNotEqual(keys[0], keys[1])
    let leased = await harness.lifecycle.snapshot().leased
    XCTAssertFalse(leased, "every dictation finishes its lease")
  }

  func testOpeningAgainKeepsTheSessionAndAdoptsAnInAppOne() async {
    await controller.open(origin: .app)
    let id = controller.session?.id
    controller.start(requestID: UUID())
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.id, id)
    XCTAssertEqual(controller.session?.state, .recording)
    XCTAssertEqual(controller.session?.origin, .keyboard)
    await controller.finish(.stopped)
    XCTAssertEqual(controller.session?.state, .ready)
  }
}
