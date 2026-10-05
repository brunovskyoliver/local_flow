import GRDB
import XCTest

@testable import LocalFlowCore

/// Feature 020 T003: `phone-meetings-v19` rebuilds meeting_segments without losing rows,
/// indexes or the track cascade, accepts `rotated`, and adds `meetings.origin`.
final class PhoneMeetingsMigrationTests: XCTestCase {
  private let meeting = "00000000-0000-0000-0000-0000000000d1"
  private let track = "00000000-0000-0000-0000-0000000000d2"

  private func migratedFromV18() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try HistoryMigrations.migrator().migrate(queue, upTo: "input-device-v18")
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO meetings (id,state,created_at,updated_at) VALUES (?,'completed',1,1)",
        arguments: [meeting])
      try db.execute(
        sql: """
          INSERT INTO meeting_tracks (id,meeting_id,type,codec,container,sample_rate,channel_count,bitrate,health)
          VALUES (?,?,'microphone','aac_lc','adts',48000,1,64000,'finalized')
          """, arguments: [track, meeting])
      try db.execute(
        sql: """
          INSERT INTO meeting_segments
            (id,track_id,sequence,relative_path,state,start_offset_ms,duration_ms,byte_size,
             started_at,host_start_ns,open_reason,close_reason,dropped_frames,recovery_note,input_device_name)
          VALUES ('s1',?,1,'m/1.aac','finalized',0,360000,2880000,5,7,'start','device_changed',3,'note','Blue Yeti'),
                 ('s2',?,2,'m/2.aac','finalized',360000,1000,8000,6,8,'device_changed','stop',0,NULL,NULL)
          """, arguments: [track, track])
    }
    try HistoryMigrations.migrator().migrate(queue)
    return queue
  }

  func testSegmentRowsAndIndexSurvive() throws {
    let queue = try migratedFromV18()
    try queue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM meeting_segments ORDER BY sequence")
      XCTAssertEqual(rows.count, 2)
      XCTAssertEqual(rows[0]["duration_ms"] as Int?, 360000)
      XCTAssertEqual(rows[0]["byte_size"] as Int?, 2_880_000)
      XCTAssertEqual(rows[0]["close_reason"] as String?, "device_changed")
      XCTAssertEqual(rows[0]["dropped_frames"] as Int?, 3)
      XCTAssertEqual(rows[0]["recovery_note"] as String?, "note")
      XCTAssertEqual(rows[0]["input_device_name"] as String?, "Blue Yeti")
      XCTAssertEqual(rows[1]["open_reason"] as String?, "device_changed")
      XCTAssertTrue(try db.indexes(on: "meeting_segments").contains { $0.isUnique })
      XCTAssertEqual(
        try db.foreignKeys(on: "meeting_segments").first?.destinationTable, "meeting_tracks")
      XCTAssertEqual(try String.fetchOne(db, sql: "SELECT origin FROM meetings"), "local")
    }
  }

  func testRotatedIsAcceptedAndOtherChecksHold() throws {
    let queue = try migratedFromV18()
    try queue.write { db in
      try db.execute(sql: "UPDATE meeting_segments SET close_reason = 'rotated' WHERE id = 's1'")
      try db.execute(
        sql: """
          INSERT INTO meeting_segments
            (id,track_id,sequence,relative_path,state,start_offset_ms,started_at,host_start_ns,open_reason)
          VALUES ('s3',?,3,'m/3.aac','open',361000,9,9,'rotated')
          """, arguments: [track])
      try db.execute(sql: "UPDATE meetings SET origin = 'iphone'")
    }
    for sql in [
      "UPDATE meeting_segments SET open_reason = 'bogus' WHERE id = 's3'",
      "UPDATE meeting_segments SET close_reason = 'bogus' WHERE id = 's3'",
      "UPDATE meeting_segments SET sequence = 1 WHERE id = 's3'",  // unique (track, sequence)
      "UPDATE meetings SET origin = 'android'",
    ] {
      XCTAssertThrowsError(try queue.write { db in try db.execute(sql: sql) }, sql)
    }
    try queue.write { db in
      try db.execute(sql: "DELETE FROM meeting_tracks")
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_segments"), 0)
    }
  }
}
