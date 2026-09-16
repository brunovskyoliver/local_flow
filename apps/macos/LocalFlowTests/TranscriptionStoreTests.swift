import Foundation
import GRDB
import XCTest

@testable import LocalFlow

final class TranscriptionStoreTests: XCTestCase {
  private func makeStore() throws -> (TranscriptionStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-history-\(UUID().uuidString).sqlite")
    return (try TranscriptionStore(path: url.path), url)
  }

  private func entry(id: UUID = UUID(), text: String = "hello") throws -> TranscriptionEntry {
    try TranscriptionEntry(
      id: id, text: text, createdAtMilliseconds: 1, quality: .complete, stopReason: .keyRelease)
  }

  func testStableIDRetryReturnsExistingWithoutResettingStatus() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try entry()
    let reservation = try await store.reserve()
    _ = try await store.commit(reservation: reservation, entry: original)
    let attempt = try await store.beginAttempt(id: original.id, revision: 0)
    let confirmed = try await store.recordOutcome(
      id: original.id, revision: attempt.entry.revision, attemptID: attempt.id, outcome: .confirmed)
    let retryReservation = try await store.reserve()
    let retried = try await store.commit(reservation: retryReservation, entry: original)
    XCTAssertEqual(retried.deliveryState, .confirmed)
    XCTAssertEqual(retried.revision, confirmed.revision)
  }

  func testSameIDConflictingTextFailsAndReservationCanBeReleased() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let id = UUID()
    let first = try entry(id: id, text: "one")
    _ = try await store.commit(reservation: try await store.reserve(), entry: first)
    do {
      _ = try await store.commit(
        reservation: try await store.reserve(), entry: try entry(id: id, text: "two"))
      XCTFail("conflicting content should be rejected")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .conflictingContent)
    }
  }

  func testReservationCountsAgainstPayloadCapacity() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    for _ in 0..<512 {
      let reservation = try await store.reserve()
      let text = String(repeating: "x", count: 65_536)
      _ = try await store.commit(reservation: reservation, entry: try entry(id: UUID(), text: text))
    }
    do {
      _ = try await store.reserve()
      XCTFail("full history should reject capture admission")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .capacityExceeded)
    }
  }

  func testAttemptingRowsBecomeUncertainAfterRestart() async throws {
    let (store, url) = try makeStore()
    let original = try entry()
    _ = try await store.commit(reservation: try await store.reserve(), entry: original)
    _ = try await store.beginAttempt(id: original.id, revision: 0)
    let restarted = try TranscriptionStore(path: url.path)
    let recovered = try await restarted.get(original.id)
    XCTAssertEqual(recovered?.deliveryState, .uncertain)
    XCTAssertEqual(recovered?.recoveryState, .needsReview)
    try? FileManager.default.removeItem(at: url)
  }

  func testDismissKeepsTextQualityAndUsage() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try entry()
    _ = try await store.commit(reservation: try await store.reserve(), entry: original)
    let dismissed = try await store.dismissRecovery(id: original.id, revision: original.revision)
    XCTAssertEqual(dismissed.text, original.text)
    XCTAssertEqual(dismissed.quality, original.quality)
    let recent = try await store.recent()
    XCTAssertEqual(recent.count, 1)
  }

  func testOnlyOneCaptureReservationIsAdmitted() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await store.reserve()
    do {
      _ = try await store.reserve()
      XCTFail("a second reservation must be rejected")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .reservationBusy)
    }
  }

  func testCommitCanonicalizesInitialDeliveryAndRecoveryState() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let supplied = try TranscriptionEntry(
      id: UUID(), text: "saved", createdAtMilliseconds: 1, deliveryState: .confirmed,
      recoveryState: .resolved, quality: .incomplete, stopReason: .failure, revision: 42)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: supplied)
    XCTAssertEqual(saved.deliveryState, .notAttempted)
    XCTAssertEqual(saved.recoveryState, .needsReview)
    XCTAssertEqual(saved.revision, 0)
  }

  func testLegacyPendingRowsArePreservedAndMapped() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-legacy-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let old = try DatabaseQueue(path: url.path)
    let id = UUID().uuidString
    try await old.write { db in
      try db.execute(
        sql:
          "CREATE TABLE pending_dictations (id TEXT PRIMARY KEY, text TEXT NOT NULL, created_at INTEGER NOT NULL, delivery_state TEXT NOT NULL, quality TEXT NOT NULL)"
      )
      try db.execute(
        sql: "INSERT INTO pending_dictations VALUES (?, ?, ?, ?, ?)",
        arguments: [id, "legacy", 77, "attempting", "duration_limited"])
    }
    let store = try TranscriptionStore(path: url.path)
    let migrated = try await store.get(UUID(uuidString: id)!)
    XCTAssertEqual(migrated?.text, "legacy")
    XCTAssertEqual(migrated?.createdAtMilliseconds, 77)
    XCTAssertEqual(migrated?.deliveryState, .uncertain)
    XCTAssertEqual(migrated?.recoveryState, .needsReview)
    XCTAssertEqual(migrated?.quality, .durationLimited)
    let legacyExists = try await old.read { try $0.tableExists("pending_dictations") }
    XCTAssertFalse(legacyExists, "Migrated text must not survive deletion in a second table")
  }

  func testDamagedDatabaseIsRejectedWithoutReset() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-damaged-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("this is not sqlite".utf8).write(to: url)
    XCTAssertThrowsError(try TranscriptionStore(path: url.path))
    XCTAssertEqual(try Data(contentsOf: url), Data("this is not sqlite".utf8))
  }

  func testRowCountReservationCapacityIsEnforced() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      for index in 0..<TranscriptionStore.maximumRows {
        try db.execute(
          sql:
            "INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision) VALUES (?,?,?,?,?,?,?,0)",
          arguments: [
            UUID().uuidString, "row-\(index)", index, "not_attempted", "needs_review", "complete",
            "key_release",
          ])
      }
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=?, payload_bytes=(SELECT sum(length(cast(text AS blob))) FROM transcriptions) WHERE id=1",
        arguments: [TranscriptionStore.maximumRows])
    }
    do {
      _ = try await store.reserve()
      XCTFail("row capacity must include the pending reservation")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .capacityExceeded)
    }
  }

  func testStatusUpdatesDoNotChangeUsageAndConfirmedDeleteFreesIt() async throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try entry(text: "usage")
    _ = try await store.commit(reservation: try await store.reserve(), entry: original)
    let before = try usage(at: url)

    let dismissed = try await store.dismissRecovery(id: original.id, revision: original.revision)
    XCTAssertEqual(try usage(at: url).count, before.count)
    XCTAssertEqual(try usage(at: url).bytes, before.bytes)
    let attempt = try await store.beginAttempt(id: original.id, revision: dismissed.revision)
    let confirmed = try await store.recordOutcome(
      id: original.id, revision: attempt.entry.revision, attemptID: attempt.id, outcome: .confirmed)
    XCTAssertEqual(try usage(at: url).count, before.count)
    XCTAssertEqual(try usage(at: url).bytes, before.bytes)

    try await store.deleteConfirmed(id: confirmed.id, revision: confirmed.revision)
    XCTAssertEqual(try usage(at: url).count, 0)
    XCTAssertEqual(try usage(at: url).bytes, 0)
  }

  func testSQLiteFullRollsBackSaveAndKeepsReservationForRetry() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-full-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    // Limit SQLite itself instead of filling the host disk.
    let store = try TranscriptionStore(path: url.path, maximumDatabaseBytes: 128 * 1024)
    let first = try entry(text: String(repeating: "a", count: 65_536))
    _ = try await store.commit(reservation: try await store.reserve(), entry: first)
    let before = try usage(at: url)
    let reservation = try await store.reserve()
    let second = try entry(text: String(repeating: "b", count: 65_536))
    do {
      _ = try await store.commit(reservation: reservation, entry: second)
      XCTFail("The SQLite page limit must fail the second large write")
    } catch let error as DatabaseError {
      XCTAssertEqual(error.resultCode, .SQLITE_FULL)
    }
    let unchanged = try await store.get(first.id)
    let absent = try await store.get(second.id)
    XCTAssertEqual(unchanged?.text, first.text)
    XCTAssertNil(absent)
    XCTAssertEqual(try usage(at: url).count, before.count)
    XCTAssertEqual(try usage(at: url).bytes, before.bytes)
    try await store.deleteConfirmed(id: first.id, revision: first.revision)
    let retried = try await store.commit(reservation: reservation, entry: second)
    XCTAssertEqual(retried.text, second.text)
    XCTAssertEqual(try usage(at: url).count, 1)
  }

  func testFailedLegacyMigrationPreservesOriginalRows() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-invalid-legacy-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      try db.execute(
        sql: "CREATE TABLE pending_dictations (id TEXT, text TEXT, created_at INTEGER)")
      try db.execute(
        sql: "INSERT INTO pending_dictations VALUES (?, '', 1)",
        arguments: [UUID().uuidString])
    }
    XCTAssertThrowsError(try TranscriptionStore(path: url.path))
    let count = try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_dictations")
    }
    XCTAssertEqual(count, 1)
    let newTable = try await database.read { try $0.tableExists("transcriptions") }
    XCTAssertFalse(newTable, "Migration failure must roll back the new schema")
  }

  private func usage(at url: URL) throws -> (count: Int, bytes: Int) {
    let database = try DatabaseQueue(path: url.path)
    return try database.read { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT row_count, payload_bytes FROM history_usage WHERE id=1")!
      return (row["row_count"], row["payload_bytes"])
    }
  }
}
