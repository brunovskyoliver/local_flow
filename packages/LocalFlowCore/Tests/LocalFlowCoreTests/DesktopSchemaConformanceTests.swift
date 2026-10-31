import GRDB
import XCTest

@testable import LocalFlowCore

/// Feature 024: the Rust desktop client builds its test databases from a schema file made by
/// this migrator, and opens only the migrations it lists. This keeps that file from drifting.
final class DesktopSchemaConformanceTests: XCTestCase {
  private var schemaFile: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("crates/flow-core/schema/history-schema.sql")
  }

  private func dump() throws -> String {
    let queue = try DatabaseQueue()
    try HistoryMigrations.migrator().migrate(queue)
    return try queue.read { db in
      var out = ""
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
          ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, rowid
          """)
      {
        out += (row["sql"] as String) + ";\n"
      }
      // Singleton rows the migrations insert, such as vocabulary_state and history_usage.
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
      for table in tables {
        let columns = try db.columns(in: table).map(\.name)
        let literals = columns.map { "quote(\"\($0)\")" }.joined(separator: " || ', ' || ")
        for values in try String.fetchAll(db, sql: "SELECT \(literals) FROM \"\(table)\"") {
          out += "INSERT INTO \"\(table)\" VALUES (\(values));\n"
        }
      }
      return out
    }
  }

  func testRustSchemaFileMatchesTheSwiftMigrator() throws {
    let current = try dump()
    if ProcessInfo.processInfo.environment["LOCALFLOW_WRITE_SCHEMA"] == "1" {
      try current.write(to: schemaFile, atomically: true, encoding: .utf8)
    }
    XCTAssertEqual(try String(contentsOf: schemaFile, encoding: .utf8), current)
  }
}
