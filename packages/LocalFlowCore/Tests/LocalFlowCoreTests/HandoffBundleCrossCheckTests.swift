import GRDB
import XCTest

@testable import LocalFlowCore

/// Feature 025: the Rust client's handoff must make the same `bundle.sqlite` and the same merge as
/// this code. What Swift makes is checked in as SQL text in `fixtures/handoff`, written with
/// LOCALFLOW_WRITE_HANDOFF_BUNDLE=1; `crates/flow-core/src/remote/handoff/tests.rs` compares against it.
final class HandoffBundleCrossCheckTests: XCTestCase {
  private let meeting = UUID(uuidString: "6F3A1C52-8D47-4E19-9B21-0C7E5A2D4F10")!
  private let other = "1B2C3D4E-0000-4000-8000-000000000001"

  private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/handoff")
  }

  private func sql(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
      .replacingOccurrences(of: "{ID}", with: meeting.uuidString)
      .replacingOccurrences(of: "{OTHER}", with: other)
  }

  /// The whole database as SQL: schema, then every row. `handoff/tests.rs` makes the same text.
  private static func dump(_ db: Database) throws -> String {
    var out = ""
    for sql in try String.fetchAll(
      db,
      sql: """
        SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
        ORDER BY type DESC, name
        """)
    {
      out += sql + ";\n"
    }
    let tables = try String.fetchAll(
      db,
      sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
    for table in tables {
      let columns = try db.columns(in: table).map(\.name)
      let literals = columns.map { "quote(\"\($0)\")" }.joined(separator: " || ', ' || ")
      for values in try String.fetchAll(
        db, sql: "SELECT \(literals) FROM \"\(table)\" ORDER BY 1")
      {
        out += "INSERT INTO \"\(table)\" VALUES (\(values));\n"
      }
    }
    return out
  }

  private func check(_ current: String, _ name: String) throws {
    let file = fixtures.appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["LOCALFLOW_WRITE_HANDOFF_BUNDLE"] == "1" {
      try current.write(to: file, atomically: true, encoding: .utf8)
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), current)
  }

  func testExportAndMergeOfTheSharedMeeting() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-cross-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try TranscriptionStore(path: temp.appendingPathComponent("db.sqlite").path)
    let seed = try sql("meeting-seed.sql")
    let output = try sql("processed.sql")
    try await store.database.write { try $0.execute(sql: seed) }
    let handoff = MeetingHandoff(
      exchange: { _ in throw RemoteChannelError.closed }, database: store.database,
      root: MeetingStorageRoot(url: temp.appendingPathComponent("Meetings")),
      eligible: { _ in true }, defaultLanguage: { .automatic })

    let bundle = temp.appendingPathComponent("bundle.sqlite")
    let exported = try await handoff.export(meeting, to: bundle)
    XCTAssertTrue(exported)

    let staged = try DatabaseQueue(path: bundle.path)
    try check(try await staged.read { try Self.dump($0) }, "swift-bundle.sql")
    try staged.close()

    let result = temp.appendingPathComponent("result.sqlite")
    try FileManager.default.copyItem(at: bundle, to: result)
    let processed = try DatabaseQueue(path: result.path)
    try await processed.write { try $0.execute(sql: output) }
    try processed.close()
    let labeled = try await handoff.merge(meeting, from: result)
    XCTAssertTrue(labeled)
    try check(try await store.database.read { try Self.dump($0) }, "swift-merged.sql")

  }
}
