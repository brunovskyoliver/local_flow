import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

@MainActor
final class DictateViewModelTests: XCTestCase {
  private var clock: ManualClock!
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var model: DictateViewModel!
  private var keyboardResults: [SessionController.DictationResult] = []

  override func setUp() async throws {
    clock = ManualClock()
    harness = try PhoneHarness(clock: clock)
    controller = harness.makeController()
    controller.onResult = { [unowned self] in keyboardResults.append($0) }
    model = DictateViewModel(controller: controller, keepReady: harness.keepReady)
  }

  override func tearDown() async throws {
    model = nil
    controller = nil
    harness = nil
  }

  /// Taps Dictate, then taps again to stop.
  private func dictate() async {
    await model.toggle()
    XCTAssertTrue(model.isRecording)
    await model.toggle()
  }

  func testANoteIsSavedAsAnAppDictationAndNeverGoesToTheKeyboard() async throws {
    await dictate()
    let note = try XCTUnwrap(model.note)
    XCTAssertEqual(note.text, "hello from the phone")
    let row = try XCTUnwrap(try harness.row(note.dictationID))
    XCTAssertEqual(row["source"] as String?, "app")
    XCTAssertEqual(row["delivery"] as String?, "saved_only")
    XCTAssertTrue(keyboardResults.isEmpty)
  }

  func testWithoutASessionTheNoteRunsAOneShotSessionThatTurnsTheEngineOff() async {
    harness.timeout = .oneHour
    await dictate()
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertEqual(controller.session?.endReason, .afterOneDictation)
    XCTAssertFalse(harness.capture.engineRunning)
  }

  func testAReadyKeyboardSessionIsUsedAndKeepsRunning() async {
    await controller.open(origin: .keyboard)
    let id = controller.session?.id
    await dictate()
    XCTAssertEqual(controller.session?.id, id)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertNotNil(model.note)
  }

  func testTheFiveMinuteLimitStopsAndKeepsTheText() async throws {
    await model.toggle()
    await controller.finish(.durationLimit)
    let note = try XCTUnwrap(model.note)
    XCTAssertTrue(note.limitReached)
    XCTAssertNotNil(model.message)
    XCTAssertEqual(try harness.row(note.dictationID)?["end_detail"] as String?, "limit_reached")
  }

  func testANoteCannotStartWhileTheKeyboardIsRecording() async {
    await controller.open(origin: .keyboard)
    controller.start(requestID: UUID())
    await model.toggle()
    XCTAssertFalse(model.isRecording)
    XCTAssertEqual(controller.lastOutcome, .busy)
    XCTAssertEqual(controller.lastRequestID, model.requestID)
    XCTAssertNotNil(model.message)
  }

  func testTheScreenKeepsTheModelReadyAndTheCooldownReleasesIt() async throws {
    model.appear()
    XCTAssertEqual(harness.keepReady.holders, [.dictateScreen])
    await harness.keepReady.settle()
    var snapshot = await harness.lifecycle.snapshot()
    XCTAssertTrue(snapshot.loaded)
    model.disappear()
    await harness.keepReady.settle()
    XCTAssertTrue(harness.keepReady.holders.isEmpty)
    snapshot = await harness.lifecycle.snapshot()
    XCTAssertTrue(snapshot.loaded, "leaving the screen does not unload at once")
    for _ in 0..<200 where await clock.sleeps == 0 { await Task.yield() }
    await clock.advance(by: .seconds(29))
    for _ in 0..<50 { await Task.yield() }
    snapshot = await harness.lifecycle.snapshot()
    XCTAssertTrue(snapshot.loaded)
    await clock.advance(by: .seconds(1))
    for _ in 0..<500 {
      if !(await harness.lifecycle.snapshot().loaded) { break }
      await Task.yield()
    }
    snapshot = await harness.lifecycle.snapshot()
    XCTAssertFalse(snapshot.loaded, "released 30 s after the screen went away")
  }
}
