import XCTest

@testable import LocalFlow

final class HandoffCodecTests: XCTestCase {
  private var store: HandoffStore!

  override func setUpWithError() throws {
    store = HandoffStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "handoff-\(UUID().uuidString)", isDirectory: true))
  }

  override func tearDown() { try? FileManager.default.removeItem(at: store.directory) }

  func testEveryFileRoundTrips() throws {
    let session = SessionFile(
      sessionID: UUID(), state: .ended, idleDeadline: 1_790_000_000_000, idleTimeout: "5m",
      dictationID: UUID(), endReason: .idleTimeout, lastRequestID: UUID(), lastOutcome: .noSession,
      updatedAt: 1_790_000_000_000)
    let request = RequestFile(requestID: UUID(), kind: .stop, sessionID: UUID(), createdAt: 5)
    let result = ResultFile(
      requestID: UUID(), dictationID: UUID(), text: "Hi, Zabbix.", limitReached: true, createdAt: 6)
    let delivery = DeliveryFile(dictationID: UUID(), delivery: .offered, at: 7)
    let status = KeyboardStatusFile(
      hasFullAccess: true, lastSeen: 8, peakFootprintBytes: 31_457_280)
    try store.write(session, .session)
    try store.write(request, .request)
    try store.write(result, .result)
    try store.write(delivery, .delivery)
    try store.write(status, .keyboardStatus)
    XCTAssertEqual(store.read(SessionFile.self, .session), session)
    XCTAssertEqual(store.read(RequestFile.self, .request), request)
    XCTAssertEqual(store.read(ResultFile.self, .result), result)
    XCTAssertEqual(store.read(DeliveryFile.self, .delivery), delivery)
    XCTAssertEqual(store.read(KeyboardStatusFile.self, .keyboardStatus), status)
  }

  func testWireKeysAreSnakeCase() throws {
    let result = ResultFile(
      requestID: UUID(), dictationID: UUID(), text: "x", limitReached: false, createdAt: 1)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      ["v", "request_id", "dictation_id", "outcome", "text", "limit_reached", "created_at"])
    XCTAssertEqual(object["outcome"] as? String, "text")
  }

  func testUnknownVersionAndGarbageReadAsAbsent() throws {
    let id = UUID().uuidString
    try store.write(
      data: Data(#"{"v":2,"dictation_id":"\#(id)","delivery":"inserted","at":1}"#.utf8), .delivery)
    XCTAssertNil(store.read(DeliveryFile.self, .delivery))
    try store.write(data: Data("{not json".utf8), .delivery)
    XCTAssertNil(store.read(DeliveryFile.self, .delivery))
    try store.write(
      data: Data(#"{"v":1,"dictation_id":"\#(id)","delivery":"thrown","at":1}"#.utf8), .delivery)
    XCTAssertNil(store.read(DeliveryFile.self, .delivery))
    XCTAssertNil(store.read(SessionFile.self, .session))
  }

  func testLevelsFileIsFixedSizeAndWraps() throws {
    var levels = LevelsFile()
    XCTAssertEqual(levels.data.count, 128)
    for index in 0..<40 { levels.append(Float(index) / 40) }
    levels.append(7)
    XCTAssertEqual(levels.data.count, 128)
    let decoded = try XCTUnwrap(LevelsFile(data: levels.data))
    XCTAssertEqual(decoded, levels)
    XCTAssertEqual(decoded.writeIndex, 41)
    XCTAssertEqual(decoded.levels.count, 31)
    XCTAssertEqual(decoded.levels.last, 1, "clamped to 1")
    XCTAssertEqual(decoded.levels.first ?? 0, Float(10) / 40, accuracy: 0.0001, "oldest first")
    XCTAssertNil(LevelsFile(data: Data(count: 127)))
  }

  func testAtomicWritesAreNeverReadHalfWritten() async throws {
    let store = store!
    try store.prepare()
    let long = String(repeating: "word ", count: 20_000)
    let writer = Task.detached {
      for index in 0..<200 {
        let file = ResultFile(
          requestID: UUID(), dictationID: UUID(), text: long + "\(index)", limitReached: false,
          createdAt: Int64(index))
        try store.write(file, .result)
      }
    }
    var reads = 0
    while !writer.isCancelled, reads < 2_000 {
      if let data = store.readData(.result) {
        XCTAssertNoThrow(try JSONDecoder().decode(ResultFile.self, from: data))
      }
      reads += 1
      if reads % 100 == 0 { await Task.yield() }
    }
    try await writer.value
  }
}
