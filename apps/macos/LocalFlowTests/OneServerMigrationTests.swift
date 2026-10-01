import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 018 T025: migration `one-server-v17` adds where-it-ran provenance and keeps
/// every existing row and value.
final class OneServerMigrationTests: XCTestCase {
  private let meeting = "00000000-0000-0000-0000-0000000000a1"

  private func migratedFromV16() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try HistoryMigrations.migrator().migrate(queue, upTo: "dictionary-usage-v16")
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO meetings (id,state,created_at,updated_at) VALUES (?,'completed',1,1)",
        arguments: [meeting])
      try db.execute(
        sql: """
          INSERT INTO meeting_transcriptions (meeting_id,state,live_requested,updated_at)
          VALUES (?,'final',1,1)
          """, arguments: [meeting])
      for reason in LiveGapReason.allCases where reason != .serverUnavailable {
        try db.execute(
          sql: """
            INSERT INTO transcript_live_gaps
              (id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,covered_by_final,created_at)
            VALUES (?,?,'pass',1,0,1000,?,1,5)
            """, arguments: [UUID().uuidString, meeting, reason.rawValue])
      }
    }
    try HistoryMigrations.migrator().migrate(queue)
    return queue
  }

  func testExistingRowsReadLocalAndKeepTheirValues() throws {
    let queue = try migratedFromV16()
    try queue.read { db in
      let row = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT state, inference_path, server_failure FROM meeting_transcriptions"))
      XCTAssertEqual(row["state"], "final")
      XCTAssertEqual(row["inference_path"], "local")
      XCTAssertNil(row["server_failure"] as String?)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT run_locally FROM meetings"), 0)
      let reasons = try String.fetchAll(
        db, sql: "SELECT reason FROM transcript_live_gaps ORDER BY reason")
      XCTAssertEqual(
        reasons, LiveGapReason.allCases.filter { $0 != .serverUnavailable }.map(\.rawValue).sorted()
      )
      XCTAssertEqual(
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM transcript_live_gaps WHERE covered_by_final = 1"),
        LiveGapReason.allCases.count - 1)
      XCTAssertTrue(
        try db.indexes(on: "transcript_live_gaps").contains { $0.columns == ["meeting_id"] })
      for table in [
        "meeting_transcriptions", "diarization_runs", "identification_runs", "analysis_runs",
      ] {
        let columns = try db.columns(in: table).map(\.name)
        XCTAssertTrue(columns.contains("inference_path"), table)
        XCTAssertTrue(columns.contains("server_failure"), table)
      }
    }
  }

  func testThePathAndFailureRulesAreEnforced() throws {
    let queue = try migratedFromV16()
    try queue.write { db in
      let update = "UPDATE meeting_transcriptions SET inference_path = ?, server_failure = ?"
      try db.execute(sql: update, arguments: ["server", nil])
      try db.execute(sql: update, arguments: ["local_after_server_failure", "user_ran_locally"])
      for code in ["unreachable", "busy", "worker_unavailable", "not_offered"] {
        try db.execute(sql: update, arguments: ["local_after_server_failure", code])
      }
      // A server pass has no failure; unknown paths and codes are refused.
      XCTAssertThrowsError(try db.execute(sql: update, arguments: ["server", "busy"]))
      XCTAssertThrowsError(try db.execute(sql: update, arguments: ["custom", nil]))
      XCTAssertThrowsError(try db.execute(sql: update, arguments: ["local", "timeout"]))
      try db.execute(sql: "UPDATE meetings SET run_locally = 1")
      XCTAssertThrowsError(try db.execute(sql: "UPDATE meetings SET run_locally = 2"))
      try db.execute(
        sql: """
          INSERT INTO transcript_live_gaps
            (id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,created_at)
          VALUES (?,?,'pass',1,0,500,'server_unavailable',6)
          """, arguments: [UUID().uuidString, meeting])
    }
    // `custom` is a summaries path only.
    try queue.read { db in
      let sql = try String.fetchOne(
        db, sql: "SELECT sql FROM sqlite_master WHERE name = 'analysis_runs'")
      XCTAssertTrue(sql?.contains("'custom'") == true)
    }
  }
}
