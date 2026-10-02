import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 019 T007 and T046: migration `input-device-v18` keeps existing rows with NULL
/// device fields, its CHECKs hold, and the history and pending stores carry the device.
final class InputDeviceMigrationTests: XCTestCase {
  private let meeting = "00000000-0000-0000-0000-0000000000b1"
  private let track = "00000000-0000-0000-0000-0000000000b2"
  private var directories: [URL] = []

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories.removeAll()
    super.tearDown()
  }

  private func migratedFromV17() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try HistoryMigrations.migrator().migrate(queue, upTo: "one-server-v17")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision)
          VALUES ('00000000-0000-0000-0000-000000000001','old text',1,'confirmed','resolved','complete','key_release',0)
          """)
      try db.execute(
        sql: "INSERT INTO meetings (id,state,created_at,updated_at) VALUES (?,'completed',1,1)",
        arguments: [meeting])
      try db.execute(
        sql: """
          INSERT INTO meeting_tracks (id,meeting_id,type,codec,container,sample_rate,channel_count,bitrate,health)
          VALUES (?,?,'microphone','aac_lc','adts',48000,1,64000,'finalized')
          """, arguments: [track, meeting])
      try insertSegment(db, sequence: 1)
      try db.execute(
        sql: """
          INSERT INTO pending_remote_dictations
            (id,audio_file,sample_count,created_at,attempts,next_attempt_at,last_failure,target_bundle_id)
          VALUES ('00000000-0000-0000-0000-0000000000c1','a.f32',16000,1,0,2,'unreachable',NULL)
          """)
    }
    try HistoryMigrations.migrator().migrate(queue)
    return queue
  }

  private func insertSegment(_ db: Database, sequence: Int, deviceName: String? = nil) throws {
    if let deviceName {
      try db.execute(
        sql: """
          INSERT INTO meeting_segments
            (id,track_id,sequence,relative_path,state,start_offset_ms,started_at,host_start_ns,open_reason,input_device_name)
          VALUES (?,?,?,?,'finalized',0,1,0,'start',?)
          """,
        arguments: [UUID().uuidString, track, sequence, "m/\(sequence).aac", deviceName])
    } else {
      try db.execute(
        sql: """
          INSERT INTO meeting_segments
            (id,track_id,sequence,relative_path,state,start_offset_ms,started_at,host_start_ns,open_reason)
          VALUES (?,?,?,?,'finalized',0,1,0,'start')
          """, arguments: [UUID().uuidString, track, sequence, "m/\(sequence).aac"])
    }
  }

  func testExistingRowsKeepNullDeviceFields() throws {
    let queue = try migratedFromV17()
    try queue.read { db in
      let transcription = try XCTUnwrap(
        Row.fetchOne(db, sql: "SELECT input_device_name, input_device_kind FROM transcriptions"))
      XCTAssertNil(transcription["input_device_name"] as String?)
      XCTAssertNil(transcription["input_device_kind"] as String?)
      XCTAssertNil(try String.fetchOne(db, sql: "SELECT input_device_name FROM meeting_segments"))
      let pending = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT input_device_name, input_device_kind FROM pending_remote_dictations"))
      XCTAssertNil(pending["input_device_name"] as String?)
      XCTAssertNil(pending["input_device_kind"] as String?)
      XCTAssertEqual(try String.fetchOne(db, sql: "SELECT text FROM transcriptions"), "old text")
    }
  }

  func testNameLengthAndKindChecksHold() throws {
    let queue = try migratedFromV17()
    for name in ["", String(repeating: "x", count: 129)] {
      XCTAssertThrowsError(
        try queue.write { db in
          try db.execute(sql: "UPDATE transcriptions SET input_device_name = ?", arguments: [name])
        })
      XCTAssertThrowsError(
        try queue.write { db in
          try db.execute(
            sql: "UPDATE pending_remote_dictations SET input_device_name = ?", arguments: [name])
        })
      XCTAssertThrowsError(
        try queue.write { db in try self.insertSegment(db, sequence: 9, deviceName: name) })
    }
    for table in ["transcriptions", "pending_remote_dictations"] {
      XCTAssertThrowsError(
        try queue.write { db in
          try db.execute(sql: "UPDATE \(table) SET input_device_kind = 'webcam'")
        })
      for kind in InputDeviceKind.allCases {
        try queue.write { db in
          try db.execute(
            sql: "UPDATE \(table) SET input_device_name = ?, input_device_kind = ?",
            arguments: [String(repeating: "y", count: 128), kind.rawValue])
        }
      }
    }
    try queue.write { db in try insertSegment(db, sequence: 2, deviceName: "Blue Yeti") }
  }

  // T046
  func testTranscriptionStoreReadsBackTheDeviceAndOldRowsReadNil() async throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("InputDeviceMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    directories.append(directory)
    let path = directory.appendingPathComponent("history.sqlite").path
    let store = try TranscriptionStore(path: path)
    let device = try XCTUnwrap(
      DictationInputDevice(name: "Oliver's iPhone Microphone", kind: .iPhone))
    let withDevice = try TranscriptionEntry(
      id: UUID(), text: "with device", createdAtMilliseconds: 2, quality: .complete,
      stopReason: .keyRelease, inputDevice: device)
    let without = try TranscriptionEntry(
      id: UUID(), text: "without", createdAtMilliseconds: 1, quality: .complete,
      stopReason: .keyRelease)
    for entry in [withDevice, without] {
      let reservation = try await store.reserve()
      _ = try await store.commit(reservation: reservation, entry: entry)
    }
    let reopened = try TranscriptionStore(path: path)
    let saved = try await reopened.get(withDevice.id)
    XCTAssertEqual(saved?.inputDevice, device)
    let old = try await reopened.get(without.id)
    XCTAssertNil(old?.inputDevice)
    // Delivery updates keep the device.
    let attempt = try await reopened.beginAttempt(id: withDevice.id, revision: 0)
    let delivered = try await reopened.recordOutcome(
      id: withDevice.id, revision: attempt.entry.revision, attemptID: attempt.id,
      outcome: .confirmed)
    XCTAssertEqual(delivered.inputDevice, device)
    XCTAssertEqual(
      HistoryViewModel.microphoneLabel(for: delivered), "Microphone: Oliver's iPhone Microphone")
    XCTAssertEqual(
      HistoryViewModel.microphoneLabel(for: try XCTUnwrap(old)), "Microphone: Not recorded")
  }

  func testDeviceNamesAreBoundedBeforeStorage() {
    XCTAssertNil(DictationInputDevice(name: "  ", kind: .usb))
    XCTAssertEqual(
      DictationInputDevice(name: String(repeating: "n", count: 300), kind: .usb)?.name.count, 128)
    XCTAssertNil(DictationInputDevice(storedName: "Mic", storedKind: "webcam"))
    XCTAssertEqual(MeetingStore.boundedDeviceName(""), nil)
    XCTAssertEqual(MeetingStore.boundedDeviceName(String(repeating: "m", count: 200))?.count, 128)
  }

  func testPendingRemoteDictationKeepsItsDeviceAcrossAReopen() async throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("InputDevicePending-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    directories.append(directory)
    let history = try TranscriptionStore(path: directory.appendingPathComponent("h.sqlite").path)
    let pendingDirectory = directory.appendingPathComponent("PendingAudio")
    let store = try PendingRemoteDictationStore(
      database: history.database, directory: pendingDirectory)
    let device = try XCTUnwrap(DictationInputDevice(name: "Blue Yeti", kind: .usb))
    let id = UUID()
    let file = directory.appendingPathComponent("a.f32")
    try Data(count: 1_600 * 4).write(to: file)
    _ = try await store.add(
      id: id, audio: file, sampleCount: 1_600, failure: .unreachable, targetBundleID: nil,
      inputDevice: device, now: 1)
    let reopened = try PendingRemoteDictationStore(
      database: history.database, directory: pendingDirectory)
    let item = try await reopened.get(id)
    XCTAssertEqual(item?.inputDevice, device)
  }
}
