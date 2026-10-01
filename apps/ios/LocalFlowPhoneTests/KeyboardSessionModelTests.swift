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
    _ state: SessionFile.State, lastRequest: UUID? = nil, outcome: SessionFile.Outcome? = nil
  ) throws {
    try store.write(
      SessionFile(
        sessionID: sessionID, state: state, idleTimeout: "5m", lastRequestID: lastRequest,
        lastOutcome: outcome, updatedAt: 0), .session)
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
    XCTAssertEqual(model.message, KeyboardSessionModel.stoppedMessage)
    XCTAssertNil(model.pending)
  }

  func testMatchingOutcomeShowsItsMessageAndOtherOutcomesAreIgnored() throws {
    let (model, requestID) = try startedModel()
    try writeSession(.ready, lastRequest: UUID(), outcome: .empty)
    model.refresh()
    XCTAssertNil(model.message)
    XCTAssertNotNil(model.pending)
    try writeSession(.ready, lastRequest: requestID, outcome: .empty)
    model.refresh()
    XCTAssertEqual(model.message, "Didn't catch that")
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
    XCTAssertEqual(model.message, KeyboardSessionModel.fullAccessMessage)
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
}
