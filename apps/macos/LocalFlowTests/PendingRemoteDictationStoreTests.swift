import GRDB
import XCTest

@testable import LocalFlow

/// Feature 014 client storage: migration `remote-dictation-v15`, the recognition path
/// on history entries and the bounded pending-retry table with its audio files.
final class PendingRemoteDictationStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = try makeSpoolRoot()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testMigrationAppliesToAVersion14DatabaseAndOldRowsReadAsLocal() throws {
    let queue = try DatabaseQueue(path: root.appendingPathComponent("v14.sqlite").path)
    try HistoryMigrations.migrator().migrate(queue, upTo: "term-suggestions-v14")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision)
          VALUES ('00000000-0000-0000-0000-000000000001','old text',1,'confirmed','resolved','complete','key_release',0)
          """)
    }
    try HistoryMigrations.migrator().migrate(queue)
    try queue.read { db in
      let path = try String.fetchOne(db, sql: "SELECT recognition_path FROM transcriptions")
      XCTAssertEqual(path, "local")
      XCTAssertNil(try String.fetchOne(db, sql: "SELECT server_failure FROM transcriptions"))
      let columns = try db.columns(in: "pending_remote_dictations").map(\.name)
      XCTAssertEqual(
        columns,
        [
          "id", "audio_file", "sample_count", "created_at", "attempts", "next_attempt_at",
          "last_failure", "target_bundle_id",
        ])
    }
    try queue.write { db in
      XCTAssertThrowsError(
        try db.execute(sql: "UPDATE transcriptions SET recognition_path='cloud'"))
      XCTAssertThrowsError(
        try db.execute(
          sql: "UPDATE transcriptions SET server_failure=?",
          arguments: [String(repeating: "x", count: 33)]))
      for samples in [0, 2_880_001] {
        XCTAssertThrowsError(
          try db.execute(
            sql: """
              INSERT INTO pending_remote_dictations (id,audio_file,sample_count,created_at,next_attempt_at)
              VALUES ('x','a.f32',?,1,1)
              """, arguments: [samples]), "\(samples)")
      }
    }
  }

  func testRecognitionPathAndFailureRoundTrip() async throws {
    let store = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let cases: [(TranscriptionEntry.RecognitionPath, RemoteFailureReason?)] =
      [(.local, nil), (.server, nil), (.server, .pendingRetry)]
      + RemoteFailureReason.allCases.filter { $0 != .pendingRetry }.map {
        (.localAfterServerFailure, $0)
      }
    for (path, failure) in cases {
      let reservation = try await store.reserve()
      let saved = try await store.commit(
        reservation: reservation,
        entry: try TranscriptionEntry(
          id: UUID(), text: "text", createdAtMilliseconds: 1, quality: .complete,
          stopReason: .keyRelease, recognitionPath: path, serverFailure: failure))
      let loaded = try await store.get(saved.id)
      XCTAssertEqual(loaded?.recognitionPath, path)
      XCTAssertEqual(loaded?.serverFailure, failure)
    }
    XCTAssertEqual(
      Set(RemoteFailureReason.allCases.map(\.rawValue)),
      [
        "unreachable", "timeout", "busy", "unauthorized", "not_approved", "revoked",
        "pin_mismatch", "worker_unavailable", "protocol_error", "limit_exceeded", "pending_retry",
      ])
  }

  func testPendingStoreMovesAudioIntoPrivateDirectoryAndIsBounded() async throws {
    let history = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let directory = root.appendingPathComponent("PendingAudio", isDirectory: true)
    let store = try PendingRemoteDictationStore(database: history.database, directory: directory)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    var ids: [UUID] = []
    for index in 0..<PendingRemoteDictationStore.maximumRows {
      let spool = try makeSpoolFile(samples: 16_000)
      let id = UUID()
      ids.append(id)
      let item = try await store.add(
        id: id, audio: spool, sampleCount: 16_000, failure: .unreachable,
        targetBundleID: "com.example.app", now: 1_000 + Int64(index))
      XCTAssertFalse(item.audioFile.contains("/"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(item).path))
      XCTAssertEqual(item.nextAttemptAt, 1_000 + Int64(index) + 10_000)
    }
    let overflow = try makeSpoolFile(samples: 10)
    do {
      _ = try await store.add(
        id: UUID(), audio: overflow, sampleCount: 10, failure: .unreachable, targetBundleID: nil,
        now: 5_000)
      XCTFail("expected the store to be full")
    } catch {
      XCTAssertEqual(error as? PendingRemoteDictationStore.Failure, .full)
    }
    // A refused dictation keeps its audio where it was.
    XCTAssertTrue(FileManager.default.fileExists(atPath: overflow.path))
    let items = try await store.all()
    XCTAssertEqual(items.count, 20)
    XCTAssertEqual(items.first?.id, ids.first)
    let first = try XCTUnwrap(items.first)
    let file = store.audioURL(first)
    try await store.remove(id: first.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    let remaining = try await store.all()
    XCTAssertEqual(remaining.count, 19)
  }

  func testAttemptsAreRecorded() async throws {
    let history = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let store = try PendingRemoteDictationStore(
      database: history.database, directory: root.appendingPathComponent("PendingAudio"))
    let id = UUID()
    _ = try await store.add(
      id: id, audio: try makeSpoolFile(samples: 4), sampleCount: 4, failure: .busy,
      targetBundleID: nil, now: 0)
    try await store.recordAttempt(id: id, failure: .timeout, nextAttemptAt: 99)
    let item = try await store.all().first
    XCTAssertEqual(item?.attempts, 1)
    XCTAssertEqual(item?.lastFailure, .timeout)
    XCTAssertEqual(item?.nextAttemptAt, 99)
  }

  func testStartupDropsOrphansBothWays() async throws {
    let history = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let directory = root.appendingPathComponent("PendingAudio", isDirectory: true)
    let store = try PendingRemoteDictationStore(database: history.database, directory: directory)
    let kept = UUID()
    let lost = UUID()
    _ = try await store.add(
      id: kept, audio: try makeSpoolFile(samples: 4), sampleCount: 4, failure: .busy,
      targetBundleID: nil, now: 0)
    let lostItem = try await store.add(
      id: lost, audio: try makeSpoolFile(samples: 4), sampleCount: 4, failure: .busy,
      targetBundleID: nil, now: 0)
    try FileManager.default.removeItem(at: store.audioURL(lostItem))
    let stray = directory.appendingPathComponent("stray.f32")
    try Data([1, 2, 3, 4]).write(to: stray)
    let result = try await store.reconcile()
    XCTAssertEqual(result.removedFiles, 1)
    XCTAssertEqual(result.droppedRows, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    let ids = try await store.all().map(\.id)
    XCTAssertEqual(ids, [kept])
  }

  func testAudioFileNamesArePlainNames() {
    XCTAssertTrue(PendingRemoteDictationStore.isPlainFileName("A.f32"))
    for bad in ["", "../x.f32", "a/b.f32", ".", "..", "/abs.f32"] {
      XCTAssertFalse(PendingRemoteDictationStore.isPlainFileName(bad), bad)
    }
  }

  private func makeSpoolFile(samples: Int) throws -> URL {
    let url = root.appendingPathComponent("\(UUID().uuidString).f32")
    try Data(count: samples * 4).write(to: url)
    return url
  }
}
