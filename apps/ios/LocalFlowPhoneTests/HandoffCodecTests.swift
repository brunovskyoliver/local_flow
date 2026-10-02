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

  func testKeyboardStatusCarriesTheCurrentFootprintAndReadsOlderFiles() throws {
    let status = KeyboardStatusFile(
      hasFullAccess: true, lastSeen: 8, peakFootprintBytes: 31_457_280,
      footprintBytes: 20_971_520)
    let json = try XCTUnwrap(String(data: try JSONEncoder().encode(status), encoding: .utf8))
    XCTAssertTrue(json.contains("\"footprint_bytes\":20971520"))
    XCTAssertEqual(try JSONDecoder().decode(KeyboardStatusFile.self, from: Data(json.utf8)), status)

    let older = #"{"v":1,"has_full_access":true,"last_seen":8,"peak_footprint_bytes":31457280}"#
    let decoded = try JSONDecoder().decode(KeyboardStatusFile.self, from: Data(older.utf8))
    XCTAssertNil(decoded.footprintBytes)
    XCTAssertEqual(decoded.peakFootprintBytes, 31_457_280)
  }

  func testKeyboardStatusCarriesTheSurfaceFootprintsAndReadsOlderFiles() throws {
    let status = KeyboardStatusFile(
      hasFullAccess: true, lastSeen: 8, peakFootprintBytes: 31_457_280,
      footprintBytes: 20_971_520, footprintRestBytes: 18_874_368,
      footprintListeningBytes: 25_165_824)
    let json = try XCTUnwrap(String(data: try JSONEncoder().encode(status), encoding: .utf8))
    XCTAssertTrue(json.contains("\"footprint_rest_bytes\":18874368"))
    XCTAssertTrue(json.contains("\"footprint_listening_bytes\":25165824"))
    XCTAssertEqual(try JSONDecoder().decode(KeyboardStatusFile.self, from: Data(json.utf8)), status)

    let older = #"{"v":1,"has_full_access":true,"last_seen":8,"peak_footprint_bytes":31457280}"#
    let decoded = try JSONDecoder().decode(KeyboardStatusFile.self, from: Data(older.utf8))
    XCTAssertNil(decoded.footprintRestBytes)
    XCTAssertNil(decoded.footprintListeningBytes)
  }

  // MARK: Feature 017 additions (contracts/keyboard-handoff-v1-additions.md)

  func testSessionFileCarriesThe017FieldsAndNever() throws {
    let session = SessionFile(
      sessionID: UUID(), state: .recording, idleDeadline: nil, idleTimeout: "never",
      dictationID: UUID(), updatedAt: 1_790_000_000_000, recordingStartedAt: 1_790_000_000_000,
      inputName: "iPhone Microphone", dictationSource: .keyboard)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
    XCTAssertEqual(object["idle_timeout"] as? String, "never")
    XCTAssertEqual(object["recording_started_at"] as? Int64, 1_790_000_000_000)
    XCTAssertEqual(object["input_name"] as? String, "iPhone Microphone")
    XCTAssertEqual(object["dictation_source"] as? String, "keyboard")
    for source in [SessionFile.Source.keyboard, .app, .control] {
      var file = session
      file.dictationSource = source
      try store.write(file, .session)
      XCTAssertEqual(store.read(SessionFile.self, .session), file)
    }
  }

  func testEndRequestRoundTrips() throws {
    let request = RequestFile(requestID: UUID(), kind: .end, sessionID: UUID(), createdAt: 5)
    try store.write(request, .request)
    XCTAssertEqual(store.read(RequestFile.self, .request), request)
    let raw = #"""
      {"v":1,"request_id":"\#(UUID())","kind":"end","session_id":"\#(UUID())","created_at":1}
      """#
    XCTAssertEqual(try JSONDecoder().decode(RequestFile.self, from: Data(raw.utf8)).kind, .end)
  }

  /// The 016 contract examples, written before any 017 field existed.
  func testEvery016FileStillDecodes() throws {
    let id = UUID().uuidString
    let session = #"""
      { "v": 1, "session_id": "\#(id)", "state": "ready", "idle_deadline": 1790000000000,
        "idle_timeout": "5m", "dictation_id": null, "end_reason": null,
        "last_request_id": "\#(id)", "last_outcome": "empty", "updated_at": 1790000000000 }
      """#
    let decoded = try JSONDecoder().decode(SessionFile.self, from: Data(session.utf8))
    XCTAssertEqual(decoded.idleTimeout, "5m")
    XCTAssertNil(decoded.recordingStartedAt)
    XCTAssertNil(decoded.inputName)
    XCTAssertNil(decoded.dictationSource)
    let request = #"""
      { "v": 1, "request_id": "\#(id)", "kind": "start", "session_id": "\#(id)",
        "created_at": 1790000000000 }
      """#
    XCTAssertEqual(
      try JSONDecoder().decode(RequestFile.self, from: Data(request.utf8)).kind, .start)
    let result = #"""
      { "v": 1, "request_id": "\#(id)", "dictation_id": "\#(id)", "outcome": "text",
        "text": "…", "limit_reached": false, "created_at": 1790000000000 }
      """#
    XCTAssertNoThrow(try JSONDecoder().decode(ResultFile.self, from: Data(result.utf8)))
    let delivery = #"""
      { "v": 1, "dictation_id": "\#(id)", "delivery": "inserted", "at": 1790000000000 }
      """#
    XCTAssertNoThrow(try JSONDecoder().decode(DeliveryFile.self, from: Data(delivery.utf8)))
    let status = #"""
      { "v": 1, "has_full_access": true, "last_seen": 1790000000000, "peak_footprint_bytes": 31457280,
        "footprint_bytes": 20971520 }
      """#
    XCTAssertNoThrow(try JSONDecoder().decode(KeyboardStatusFile.self, from: Data(status.utf8)))
  }

  func testFootprintReadsThisProcess() {
    let reading = Footprint.read()
    XCTAssertGreaterThan(reading.current, 0)
    XCTAssertGreaterThanOrEqual(reading.peak, reading.current)
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
