import Foundation
import GRDB
import XCTest

@testable import LocalFlow

/// Deletes a test database with the WAL and shared-memory files SQLite leaves beside it.
func removeDatabase(at url: URL) {
  for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(atPath: url.path + suffix)
  }
}

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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
    // Every commit that still leaves room for one full reservation (Feature 012
    // widened it by the context row's maximum).
    let fits =
      (TranscriptionStore.maximumPayloadBytes - TranscriptionStore.reservationBytes) / 65_536 + 1
    for _ in 0..<fits {
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
    removeDatabase(at: url)
  }

  func testDismissKeepsTextQualityAndUsage() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
    try Data("this is not sqlite".utf8).write(to: url)
    XCTAssertThrowsError(try TranscriptionStore(path: url.path))
    XCTAssertEqual(try Data(contentsOf: url), Data("this is not sqlite".utf8))
  }

  func testRowCountReservationCapacityIsEnforced() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
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
    defer { removeDatabase(at: url) }
    // Freeze the page limit after the schema and first entry fit. This keeps the
    // failure test independent of schema growth while leaving no room for a second
    // 64 KiB entry. Deletion must still free enough pages to retry that same write.
    let store = try TranscriptionStore(path: url.path)
    let first = try entry(text: String(repeating: "a", count: 65_536))
    _ = try await store.commit(reservation: try await store.reserve(), entry: first)
    try await store.database.write { db in
      let pages = try XCTUnwrap(Int.fetchOne(db, sql: "PRAGMA page_count"))
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA max_page_count=\(pages)"), pages)
    }
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
    defer { removeDatabase(at: url) }
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

  func testQualityEnvelopeRoundTripsExactBytesAndHashesWithoutLoadingDetailsInSummaries()
    async throws
  {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let envelope = try makeQualityEnvelope(raw: "e\u{301}  raw\r\n", text: "é assembled")
    let saved = try await store.commit(reservation: try await store.reserve(), envelope: envelope)
    let detail = try await store.qualityDetail(saved.id)
    let restored = try XCTUnwrap(detail)
    XCTAssertEqual(
      Array(restored.rawWindows[0].text.utf8), Array(envelope.detail!.rawWindows[0].text.utf8))
    XCTAssertEqual(restored.contentHash, envelope.detail!.contentHash)
    XCTAssertEqual(try restored.serialized(), try envelope.detail!.serialized())
    XCTAssertEqual(try usage(at: url).bytes, envelope.entry.text.utf8.count + restored.payloadBytes)
    let rows = try await store.recent()
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows[0].hasQualityDetail)
    XCTAssertEqual(rows[0].text, envelope.entry.text)
  }

  func testQualityRetryRejectsProvenanceOrRawChangesButKeepsDeliveryRevisions() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let original = try makeQualityEnvelope()
    _ = try await store.commit(reservation: try await store.reserve(), envelope: original)
    let dismissed = try await store.dismissRecovery(id: original.entry.id, revision: 0)
    let retried = try await store.commit(reservation: try await store.reserve(), envelope: original)
    XCTAssertEqual(retried.revision, dismissed.revision)
    for changed in [
      try makeQualityEnvelope(id: original.entry.id, raw: "different raw"),
      try makeQualityEnvelope(id: original.entry.id, build: "different-build"),
      TranscriptionEnvelope(entry: original.entry, detail: nil),
    ] {
      let reservation = try await store.reserve()
      do {
        _ = try await store.commit(reservation: reservation, envelope: changed)
        XCTFail("immutable processing differences must reject retries")
      } catch let error as TranscriptionStore.Error {
        XCTAssertEqual(error, .conflictingContent)
      }
      await store.releaseReservation(reservation)
    }
    let detail = try await store.qualityDetail(original.entry.id)
    XCTAssertEqual(detail?.contentHash, original.detail?.contentHash)
  }

  func testCanonicallyEquivalentLegacyRetryStillRequiresExactUTF8() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let original = try entry(text: "e\u{301}")
    _ = try await store.commit(reservation: try await store.reserve(), entry: original)
    do {
      _ = try await store.commit(
        reservation: try await store.reserve(), entry: try entry(id: original.id, text: "é"))
      XCTFail("Swift canonical string equality must not replace byte equality")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .conflictingContent)
    }
  }

  func testQualityDeleteAndRestartReconcileEveryRepresentation() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let envelope = try makeQualityEnvelope()
    _ = try await store.commit(reservation: try await store.reserve(), envelope: envelope)
    let legacy = try entry(text: "legacy")
    _ = try await store.commit(reservation: try await store.reserve(), entry: legacy)
    let expectedBytes = try usage(at: url).bytes
    let database = try DatabaseQueue(path: url.path)
    try await database.write {
      try $0.execute(sql: "UPDATE history_usage SET row_count=0,payload_bytes=0")
    }
    let restarted = try TranscriptionStore(path: url.path)
    XCTAssertEqual(try usage(at: url).bytes, expectedBytes)
    XCTAssertEqual(try usage(at: url).count, 2)
    let detail = try await restarted.qualityDetail(envelope.entry.id)
    XCTAssertEqual(detail?.contentHash, envelope.detail?.contentHash)
    let legacyDetail = try await restarted.qualityDetail(legacy.id)
    XCTAssertNil(legacyDetail)
    try await restarted.deleteConfirmed(id: envelope.entry.id, revision: 0)
    XCTAssertEqual(try usage(at: url).bytes, legacy.text.utf8.count)
    let count = try await database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM transcription_quality")
    }
    XCTAssertEqual(count, 0)
  }

  func testFullEnvelopeReservationRejectsBeforeCaptureEvenForTinyRequestedText() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try await database.write {
      try $0.execute(
        sql: "UPDATE history_usage SET payload_bytes=?",
        arguments: [TranscriptionStore.maximumPayloadBytes - 393_216 + 1])
    }
    do {
      _ = try await store.reserve(maxBytes: 1)
      XCTFail("capture must reserve all representations")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .capacityExceeded)
    }
  }

  func testQualityTransactionFailureRollsBackParentDetailAndCounterAndAllowsSameRetry() async throws
  {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try await database.write {
      try $0.execute(
        sql:
          "CREATE TRIGGER fail_quality BEFORE INSERT ON transcription_quality BEGIN SELECT RAISE(ABORT, 'injected'); END"
      )
    }
    let envelope = try makeQualityEnvelope()
    let reservation = try await store.reserve()
    do {
      _ = try await store.commit(reservation: reservation, envelope: envelope)
      XCTFail("detail failure must roll back parent")
    } catch is DatabaseError {}
    let parent = try await store.get(envelope.entry.id)
    XCTAssertNil(parent)
    XCTAssertEqual(try usage(at: url).bytes, 0)
    XCTAssertEqual(try usage(at: url).count, 0)
    try await database.write { try $0.execute(sql: "DROP TRIGGER fail_quality") }
    _ = try await store.commit(reservation: reservation, envelope: envelope)
    let detail = try await store.qualityDetail(envelope.entry.id)
    XCTAssertEqual(detail?.contentHash, envelope.detail?.contentHash)
  }

  func testHistoryV1MigrationPreservesRowsWithoutInventingRawDetail() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-v1-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try HistoryMigrations.migrator().migrate(database, upTo: "history-v1")
    let id = UUID()
    try await database.write {
      try $0.execute(
        sql:
          "INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision) VALUES (?, 'legacy', 1, 'not_attempted', 'needs_review', 'complete', 'key_release', 0)",
        arguments: [id.uuidString])
    }
    let store = try TranscriptionStore(path: url.path)
    let saved = try await store.get(id)
    XCTAssertEqual(saved?.text, "legacy")
    XCTAssertFalse(try XCTUnwrap(saved).hasQualityDetail)
    let detail = try await store.qualityDetail(id)
    XCTAssertNil(detail)
    let tables = try await database.read { db in
      try ["transcription_quality", "vocabulary_entries", "vocabulary_state"].map {
        try db.tableExists($0)
      }
    }
    XCTAssertEqual(tables, [true, true, true])
    XCTAssertEqual(try usage(at: url).bytes, 6)
  }

  func testQualityHashesRejectTamperingAndRespectUnicodeBytes() throws {
    let envelope = try makeQualityEnvelope(raw: "e\u{301}")
    let detail = try XCTUnwrap(envelope.detail)
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: detail.serialized()) as? [String: Any])
    var content = try XCTUnwrap(json["content"] as? [String: Any])
    var windows = try XCTUnwrap(content["rawWindows"] as? [[String: Any]])
    windows[0]["text"] = "é"
    content["rawWindows"] = windows
    json["content"] = content
    XCTAssertThrowsError(
      try TranscriptionQualityDetail.decode(
        JSONSerialization.data(withJSONObject: json), normalizedText: envelope.entry.text))
    XCTAssertNotEqual(
      TranscriptionQualityDetail.hash("é"), TranscriptionQualityDetail.hash("e\u{301}"))
    XCTAssertThrowsError(try detail.validate(normalizedText: "different"))
  }

  func testQualityBoundsAndTaggedInvalidTimings() throws {
    let base = try XCTUnwrap(makeQualityEnvelope().detail)
    let raw = TranscriptionQualityDetail.RawWindow(
      sequence: 0, sampleStart: 0, sampleCount: 16_000,
      paddedSampleCount: 16_000, text: String(repeating: "x", count: 65_536),
      timings: nil, timingValidation: .unavailable)
    let exact = try TranscriptionQualityDetail(
      rawWindows: [raw], assembledText: raw.text, normalizedText: raw.text,
      assemblyVersion: "test", normalizationVersion: "identity-v1", provenance: base.provenance)
    XCTAssertEqual(exact.rawWindows[0].text.utf8.count, 65_536)
    XCTAssertThrowsError(try makeQualityEnvelope(raw: String(repeating: "x", count: 65_537)))
    XCTAssertThrowsError(try makeQualityEnvelope(text: String(repeating: "x", count: 65_537)))
    XCTAssertThrowsError(
      try TranscriptionQualityDetail(
        rawWindows: Array(repeating: raw, count: 15),
        assembledText: "x", normalizedText: "x", assemblyVersion: "test",
        normalizationVersion: "identity-v1", provenance: base.provenance))
    XCTAssertThrowsError(
      try TranscriptionQualityDetail(
        rawWindows: [], assembledText: "x", normalizedText: "x",
        assemblyVersion: String(repeating: "v", count: 129), normalizationVersion: "identity-v1",
        provenance: base.provenance))
    let invalid = TranscriptionQualityDetail.RawWindow(
      sequence: 0, sampleStart: 0, sampleCount: 16_000,
      paddedSampleCount: 16_000, text: "raw",
      timings: [.init(text: "raw", start: .init(.nan), end: .init(.infinity))],
      timingValidation: .invalid)
    let retained = try TranscriptionQualityDetail(
      rawWindows: [invalid], assembledText: "raw", normalizedText: "raw",
      assemblyVersion: "test", normalizationVersion: "identity-v1", provenance: base.provenance,
      completionReasons: [.init(.invalidResult, window: 0)])
    let restored = try TranscriptionQualityDetail.decode(
      retained.serialized(), normalizedText: "raw")
    XCTAssertEqual(restored.rawWindows[0].timings?.first?.start.invalid, .nan)
    XCTAssertEqual(restored.rawWindows[0].timings?.first?.end.invalid, .positiveInfinity)
    XCTAssertTrue(restored.incomplete)
  }

  func testIncompleteDetailCannotBeStoredAsComplete() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let envelope = try makeQualityEnvelope(reasons: [.init(.uncertainJoin, window: 0)])
    let complete = try entry(id: envelope.entry.id, text: envelope.entry.text)
    do {
      _ = try await store.commit(
        reservation: try await store.reserve(),
        envelope: .init(entry: complete, detail: envelope.detail))
      XCTFail("known loss must remain incomplete")
    } catch is TranscriptionQualityDetail.Failure {}
    XCTAssertEqual(try usage(at: url).count, 0)
  }

  func testDetailBytesParticipateInCommitCapacityChecks() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let envelope = try makeQualityEnvelope()
    let reservation = try await store.reserve()
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      try db.execute(
        sql: "UPDATE history_usage SET payload_bytes=?",
        arguments: [TranscriptionStore.maximumPayloadBytes - envelope.entry.text.utf8.count])
    }
    do {
      _ = try await store.commit(reservation: reservation, envelope: envelope)
      XCTFail("normalized text alone fits, but the detail does not")
    } catch let error as TranscriptionStore.Error { XCTAssertEqual(error, .capacityExceeded) }
    let absent = try await store.get(envelope.entry.id)
    XCTAssertNil(absent)
  }

  func testCompletionOverflowUsesReservedReasonWithoutLosingText() throws {
    let base = try XCTUnwrap(makeQualityEnvelope().detail)
    let codes: [TranscriptionQualityDetail.CompletionReason.Code] = [
      .uncertainJoin, .rawCapacity, .mappingCapacity, .invalidResult, .failed,
    ]
    let reasons = (0..<64).map {
      TranscriptionQualityDetail.CompletionReason(codes[$0 / 14], window: $0 % 14)
    }
    let detail = try TranscriptionQualityDetail(
      rawWindows: base.rawWindows, assembledText: base.assembledText,
      normalizedText: "assembled", assemblyVersion: "test", normalizationVersion: "identity-v1",
      provenance: base.provenance, completionReasons: reasons)
    let cancelled = try detail.addingCompletionReasons(
      [.init(.cancelled)], normalizedText: "assembled")
    XCTAssertLessThanOrEqual(cancelled.completionReasons.count, 64)
    XCTAssertTrue(cancelled.completionReasons.contains { $0.code == .diagnosticCapacity })
    XCTAssertTrue(cancelled.incomplete)
    XCTAssertEqual(cancelled.assembledText, base.assembledText)
    XCTAssertEqual(cancelled.rawWindows.first?.textHash, base.rawWindows.first?.textHash)
  }

  func testMetadataEscapingAndTimingTokenBudgetsRejectWithoutTruncation() throws {
    let base = try XCTUnwrap(makeQualityEnvelope().detail)
    XCTAssertThrowsError(try makeQualityEnvelope(raw: String(repeating: "\u{0001}", count: 30_000)))
    let window = TranscriptionQualityDetail.RawWindow(
      sequence: 0, sampleStart: 0, sampleCount: 16_000,
      paddedSampleCount: 16_000, text: "raw",
      timings: Array(repeating: .init(text: "x", start: .init(0), end: .init(0)), count: 4_000),
      timingValidation: .valid)
    XCTAssertThrowsError(
      try TranscriptionQualityDetail(
        rawWindows: [window], assembledText: "raw", normalizedText: "raw",
        assemblyVersion: "test", normalizationVersion: "identity-v1", provenance: base.provenance))
  }

  func testAppliedIDsCanonicalizeAndHashIsIndependentOfInputOrder() throws {
    let base = try XCTUnwrap(makeQualityEnvelope().detail)
    func detail(_ ids: [String]) throws -> TranscriptionQualityDetail {
      try TranscriptionQualityDetail(
        rawWindows: base.rawWindows, assembledText: base.assembledText, normalizedText: "assembled",
        assemblyVersion: "test", normalizationVersion: "test", appliedRuleIDs: ids,
        provenance: base.provenance)
    }
    XCTAssertEqual(
      try detail(["N002", "N001", "N001"]).contentHash, try detail(["N001", "N002"]).contentHash)
    XCTAssertThrowsError(try detail(Array(repeating: "N001", count: 33)))
    XCTAssertThrowsError(try detail([String(repeating: "x", count: 129)]))
  }

  /// Deleting a parent row must not scan a child table: every foreign-key column has
  /// a full (non-partial) index whose leading column is that column.
  func testEveryForeignKeyColumnHasALeadingIndex() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let unindexed = try await store.database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          WITH t AS (SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'),
          fk AS (SELECT t.name AS tbl, f."from" AS col FROM t, pragma_foreign_key_list(t.name) f),
          lead AS (
            SELECT t.name AS tbl, ii.name AS col FROM t, pragma_index_list(t.name) il,
              pragma_index_info(il.name) ii WHERE ii.seqno=0 AND il.partial=0)
          SELECT tbl, col FROM fk
          WHERE NOT EXISTS (SELECT 1 FROM lead WHERE lead.tbl=fk.tbl AND lead.col=fk.col)
          ORDER BY tbl, col
          """
      ).map { "\($0["tbl"] as String).\($0["col"] as String)" }
    }
    XCTAssertEqual(unindexed, [])
    let foreignKeys = try await store.database.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM sqlite_master t, pragma_foreign_key_list(t.name)
          WHERE t.type='table'
          """)
    }
    XCTAssertGreaterThan(foreignKeys ?? 0, 40, "the check must see the whole schema")
    let segmentPlan = try await store.database.read { db in
      try Row.fetchAll(
        db, sql: "EXPLAIN QUERY PLAN SELECT 1 FROM analysis_sources WHERE segment_id=?",
        arguments: ["x"]
      ).map { $0["detail"] as String }.joined(separator: "; ")
    }
    XCTAssertTrue(segmentPlan.contains("analysis_sources_fk_segment_id"), segmentPlan)
  }

  /// WAL keeps FULL synchronous commits with full fsyncs on the writer and readers,
  /// and a bounded WAL file after checkpoints.
  func testDatabaseUsesDurableWriteAheadLog() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    @Sendable func pragmas(_ db: Database) throws -> [String] {
      try [
        String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
        String(Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1),
        String(Int.fetchOne(db, sql: "PRAGMA fullfsync") ?? -1),
        String(Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") ?? -1),
        String(Int.fetchOne(db, sql: "PRAGMA journal_size_limit") ?? -1),
      ]
    }
    let expected = ["wal", "2", "1", "1", String(TranscriptionStore.journalSizeLimitBytes)]
    let writer = try await store.database.write { try pragmas($0) }
    let reader = try await store.database.read { try pragmas($0) }
    XCTAssertEqual(writer, expected)
    XCTAssertEqual(reader, expected)
    _ = try await store.commit(reservation: try await store.reserve(), entry: try entry())
    let restarted = try TranscriptionStore(path: url.path)
    let reopened = try await restarted.database.write { try pragmas($0) }
    XCTAssertEqual(reopened, expected)
    let mode =
      try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.posixPermissions]
      as? Int
    XCTAssertEqual(mode, 0o600)
  }

  /// A clean relaunch trusts the transactional usage counters and writes nothing:
  /// no payload rescan and no empty fsynced transaction.
  func testCleanRestartPerformsNoStartupWrites() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    _ = try await store.commit(reservation: try await store.reserve(), entry: try entry())
    let before = try usage(at: url)
    try await store.database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE startup_writes (tbl TEXT);
          CREATE TRIGGER usage_written AFTER UPDATE ON history_usage
            BEGIN INSERT INTO startup_writes VALUES ('history_usage'); END;
          CREATE TRIGGER transcription_written AFTER UPDATE ON transcriptions
            BEGIN INSERT INTO startup_writes VALUES ('transcriptions'); END;
          CREATE TRIGGER attempt_written AFTER UPDATE ON rewrite_attempts
            BEGIN INSERT INTO startup_writes VALUES ('rewrite_attempts'); END;
          """)
    }
    let restarted = try TranscriptionStore(path: url.path)
    let interrupted = try await restarted.cancelPendingOnStartup()
    XCTAssertEqual(interrupted, 0)
    let writes = try await restarted.database.read {
      try String.fetchAll($0, sql: "SELECT tbl FROM startup_writes")
    }
    XCTAssertEqual(writes, [])
    XCTAssertEqual(try usage(at: url).count, before.count)
    XCTAssertEqual(try usage(at: url).bytes, before.bytes)
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
