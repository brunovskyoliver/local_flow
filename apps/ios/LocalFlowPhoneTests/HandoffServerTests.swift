import XCTest

@testable import LocalFlow

@MainActor
final class HandoffServerTests: XCTestCase {
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var server: HandoffServer!
  private var store: HandoffStore!
  private var rung: [Bell] = []
  private var rowsAtResultBell: Int?

  override func setUp() async throws {
    harness = try PhoneHarness()
    controller = harness.makeController()
    store = harness.handoffStore()
    server = HandoffServer(
      store: store, controller: controller, dictations: harness.dictations,
      ring: { [unowned self] bell in
        rung.append(bell)
        if bell == .result { rowsAtResultBell = try? harness.rowCount() }
      }, now: { [unowned self] in harness.now })
    controller.onChange = { [unowned self] in server.writeSession() }
    controller.onResult = { [unowned self] in server.publish($0) }
    controller.onLevel = { [unowned self] in server.writeLevel($0) }
  }

  override func tearDown() async throws {
    server = nil
    controller = nil
    harness = nil
  }

  private func request(_ kind: RequestFile.Kind, _ id: UUID, age: TimeInterval = 0) throws {
    try store.write(
      RequestFile(
        requestID: id, kind: kind, sessionID: controller.session!.id,
        createdAt: Handoff.milliseconds(harness.now.addingTimeInterval(-age))), .request)
    server.handleRequest()
  }

  private func waitForReady() async throws {
    for _ in 0..<100 where controller.session?.state != .ready {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testStartThenStopPublishesAfterHistory() async throws {
    await controller.open(origin: .keyboard)
    let id = UUID()
    try request(.start, id)
    XCTAssertEqual(store.read(SessionFile.self, .session)?.state, .recording)
    server.writeLevel(0.5)
    XCTAssertEqual(store.readData(.levels)?.count, LevelsFile.byteCount)
    try request(.stop, id)
    try await waitForReady()
    let result = try XCTUnwrap(store.read(ResultFile.self, .result))
    XCTAssertEqual(result.requestID, id)
    XCTAssertEqual(rowsAtResultBell, 1, "History is saved before the result bell")
    XCTAssertTrue(rung.contains(.result))
    XCTAssertEqual(store.read(SessionFile.self, .session)?.state, .ready)
  }

  func testInsertedDeliveryUpdatesHistoryAndDeletesTheResult() async throws {
    await controller.open(origin: .keyboard)
    let id = UUID()
    try request(.start, id)
    try request(.stop, id)
    try await waitForReady()
    let result = try XCTUnwrap(store.read(ResultFile.self, .result))
    try store.write(
      DeliveryFile(dictationID: result.dictationID, delivery: .inserted, at: 0), .delivery)
    server.handleDelivery()
    XCTAssertNil(store.read(ResultFile.self, .result))
    for _ in 0..<50 {
      if try harness.row(result.dictationID)?["delivery"] as String? == "inserted" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let row = try XCTUnwrap(try harness.row(result.dictationID))
    XCTAssertEqual(row["delivery"] as String?, "inserted")
    XCTAssertEqual(row["delivery_state"] as String?, "confirmed")
  }

  func testEmptyReplyUpdatesSessionAndKeepsAnEarlierResult() async throws {
    let earlier = ResultFile(
      requestID: UUID(), dictationID: UUID(), text: "Earlier.", limitReached: false,
      createdAt: Handoff.milliseconds(harness.now))
    try store.write(earlier, .result)
    await harness.runtime.set(text: "")
    await controller.open(origin: .keyboard)
    let id = UUID()
    try request(.start, id)
    try request(.stop, id)
    try await waitForReady()
    XCTAssertEqual(store.read(ResultFile.self, .result), earlier)
    let session = try XCTUnwrap(store.read(SessionFile.self, .session))
    XCTAssertEqual(session.lastRequestID, id)
    XCTAssertEqual(session.lastOutcome, .empty)
  }

  func testStaleAndForeignRequestsAreIgnored() async throws {
    await controller.open(origin: .keyboard)
    try request(.start, UUID(), age: 11)
    XCTAssertEqual(controller.session?.state, .ready)
    try store.write(
      RequestFile(
        requestID: UUID(), kind: .start, sessionID: UUID(),
        createdAt: Handoff.milliseconds(harness.now)), .request)
    server.handleRequest()
    XCTAssertEqual(controller.session?.state, .ready)
  }

  func testLevelsAreWrittenOnlyWhileRecording() async throws {
    await controller.open(origin: .keyboard)
    server.writeLevel(0.4)
    XCTAssertNil(store.readData(.levels))
  }

  func testExpiredResultIsDeletedAtLaunchActivationAndSessionEnd() async throws {
    let old = ResultFile(
      requestID: UUID(), dictationID: UUID(), text: "Old.", limitReached: false,
      createdAt: Handoff.milliseconds(harness.now) - Handoff.resultLifetime)
    try store.write(old, .result)
    server.launched()
    XCTAssertNil(store.read(ResultFile.self, .result))
    try store.write(old, .result)
    server.becameActive()
    XCTAssertNil(store.read(ResultFile.self, .result))
    await controller.open(origin: .keyboard)
    try store.write(old, .result)
    controller.end(.userEnded)
    XCTAssertNil(store.read(ResultFile.self, .result))
    XCTAssertEqual(store.read(SessionFile.self, .session)?.state, .ended)
  }

  // MARK: Feature 017 additions

  func testEndWithTheSessionIDEndsTheSessionAndDiscardsTheRecording() async throws {
    await controller.open(origin: .keyboard)
    try request(.start, UUID())
    try request(.end, UUID())
    XCTAssertEqual(controller.session?.endReason, .userEnded)
    XCTAssertEqual(store.read(SessionFile.self, .session)?.state, .ended)
    XCTAssertNil(store.read(ResultFile.self, .result))
    XCTAssertEqual(try harness.rowCount(), 0, "the recording in progress is discarded")
  }

  func testEndWithAStaleSessionIDIsIgnored() async throws {
    await controller.open(origin: .keyboard)
    try store.write(
      RequestFile(
        requestID: UUID(), kind: .end, sessionID: UUID(),
        createdAt: Handoff.milliseconds(harness.now)), .request)
    server.handleRequest()
    XCTAssertEqual(controller.session?.state, .ready)
  }

  func testCancelWritesNoResult() async throws {
    await controller.open(origin: .keyboard)
    let id = UUID()
    try request(.start, id)
    try request(.cancel, id)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertNil(store.read(ResultFile.self, .result))
    XCTAssertFalse(rung.contains(.result))
  }

  func testSessionFileCarriesNeverAndTheRecordingFieldsOnlyWhileRecording() async throws {
    harness.timeout = .never
    await controller.open(origin: .keyboard)
    var file = try XCTUnwrap(store.read(SessionFile.self, .session))
    XCTAssertEqual(file.idleTimeout, "never")
    XCTAssertNil(file.idleDeadline)
    XCTAssertNil(file.recordingStartedAt)
    XCTAssertNil(file.inputName)
    XCTAssertNil(file.dictationSource)

    let id = UUID()
    try request(.start, id)
    file = try XCTUnwrap(store.read(SessionFile.self, .session))
    XCTAssertEqual(file.state, .recording)
    XCTAssertEqual(file.recordingStartedAt, Handoff.milliseconds(harness.now))
    XCTAssertEqual(file.inputName, harness.capture.inputName)
    XCTAssertEqual(file.dictationSource, .keyboard)

    try request(.stop, id)
    try await waitForReady()
    file = try XCTUnwrap(store.read(SessionFile.self, .session))
    XCTAssertNil(file.idleDeadline)
    XCTAssertNil(file.recordingStartedAt)
    XCTAssertNil(file.inputName)
    XCTAssertNil(file.dictationSource)
  }

  func testCleanLaunchRemovesAStaleSessionFile() throws {
    try store.write(
      SessionFile(sessionID: UUID(), state: .ready, idleTimeout: "5m", updatedAt: 0), .session)
    server.launched()
    XCTAssertNil(store.read(SessionFile.self, .session))
  }
}
