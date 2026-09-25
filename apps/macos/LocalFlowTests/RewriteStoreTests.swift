import GRDB
import XCTest

@testable import LocalFlow

/// Migration `rewrite-v4`, attempt admission, terminal recording, quota and the
/// startup fix-up, all against the real GRDB store on a private temporary file.
final class RewriteStoreTests: XCTestCase {
  private var ownedDirectories: [URL] = []

  override func tearDown() async throws {
    for directory in ownedDirectories.reversed() {
      try? FileManager.default.removeItem(at: directory)
    }
    ownedDirectories.removeAll()
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rewrite-store-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return directory
  }

  private func makeStore(directory: URL? = nil) throws -> TranscriptionStore {
    let directory = try directory ?? makeDirectory()
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func commit(_ store: TranscriptionStore, text: String = "peter can you move it")
    async throws
    -> TranscriptionEntry
  {
    let entry = try TranscriptionEntry(
      id: UUID(), text: text, createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
      quality: .complete, stopReason: .keyRelease)
    return try await store.commit(reservation: try await store.reserve(), entry: entry)
  }

  private func admission(
    _ entry: TranscriptionEntry, mode: RewriteMode = .clean, text: String? = nil
  )
    -> RewriteAdmission
  {
    RewriteAdmission(
      transcriptionID: entry.id, mode: mode, inputText: text ?? entry.text,
      endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false)
  }

  private func spans(duration: Int = 900) -> RewriteSpans {
    RewriteSpans(
      durationMilliseconds: duration, firstByteMilliseconds: 200, networkMilliseconds: 800,
      requestBytes: 120, responseBytes: 340)
  }

  private func result(text: String = "Peter, can you move it?") -> RewriteResult {
    RewriteResult(
      text: text, unchanged: false, serverName: "flowd", serverVersion: "0.2.0",
      backendKind: "openai-compatible", backendModel: "qwen2.5-3b", promptVersion: 1,
      shieldVersion: 1, serverQueueMilliseconds: 3, backendFirstTokenMilliseconds: 180,
      backendMilliseconds: 610)
  }

  private func payloadBytes(_ store: TranscriptionStore) throws -> Int {
    try store.database.read { db in
      try Int.fetchOne(db, sql: "SELECT payload_bytes FROM history_usage WHERE id=1") ?? -1
    }
  }

  private func rewriteFailure(_ body: () async throws -> Void) async -> RewriteFailureCategory? {
    do {
      try await body()
      return nil
    } catch let failure as RewriteFailure {
      return failure.category
    } catch {
      XCTFail("unexpected error \(error)")
      return nil
    }
  }

  // MARK: Migration

  func testMigrationCreatesAttemptTableAndTranscriptionColumns() throws {
    let store = try makeStore()
    try store.database.read { db in
      XCTAssertTrue(try db.tableExists("rewrite_attempts"))
      let columns = try db.columns(in: "rewrite_attempts").map(\.name)
      for expected in [
        "id", "transcription_id", "ordinal", "mode", "state", "input_text", "input_hash",
        "output_text", "output_hash", "unchanged", "failure_category", "stale", "started_at",
        "duration_ms", "first_byte_ms", "network_ms", "server_queue_ms", "backend_first_token_ms",
        "backend_ms", "protocol_version", "server_name", "server_version", "backend_kind",
        "backend_model", "prompt_version", "shield_version", "endpoint_origin", "insecure_override",
        "request_bytes", "response_bytes", "delivered",
      ] {
        XCTAssertTrue(columns.contains(expected), expected)
      }
      let transcriptionColumns = try db.columns(in: "transcriptions")
      let rewriteState = try XCTUnwrap(transcriptionColumns.first { $0.name == "rewrite_state" })
      XCTAssertEqual(rewriteState.defaultValueSQL, "'not_requested'")
      XCTAssertTrue(transcriptionColumns.contains { $0.name == "delivered_source" })
      XCTAssertTrue(transcriptionColumns.contains { $0.name == "delivered_rewrite_attempt_id" })
      let deliveredKey = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(transcriptions)")
        .first { $0["from"] == "delivered_rewrite_attempt_id" }
      XCTAssertEqual(deliveredKey?["on_delete"], "SET NULL")
      XCTAssertEqual(deliveredKey?["table"], "rewrite_attempts")
      let attemptKey = try Row.fetchOne(db, sql: "PRAGMA foreign_key_list(rewrite_attempts)")
      XCTAssertEqual(attemptKey?["on_delete"], "CASCADE")
      XCTAssertEqual(attemptKey?["table"], "transcriptions")
      let indexes = try db.indexes(on: "rewrite_attempts")
      XCTAssertTrue(
        indexes.contains { $0.isUnique && $0.columns == ["transcription_id", "ordinal"] })
    }
  }

  func testLegacyDatabaseOpensWithNotRequestedAndNoAttempts() async throws {
    let directory = try makeDirectory()
    let path = directory.appendingPathComponent("history.sqlite").path
    // Build a pre-003 database by running only the earlier migrations.
    let queue = try DatabaseQueue(path: path)
    try HistoryMigrations.migrator().migrate(queue, upTo: "vocabulary-v3")
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,target_bundle_id,attempt_id,attempt_started_at,revision)
          VALUES (?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          UUID().uuidString, "legacy text", 5, "confirmed", "resolved", "complete", "key_release",
          nil, nil, nil, 0,
        ])
      try db.execute(sql: "UPDATE history_usage SET row_count=1, payload_bytes=11 WHERE id=1")
    }
    try queue.close()
    let store = try TranscriptionStore(path: path)
    let entries = try await store.recent()
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    XCTAssertNil(entry.deliveredSource)
    XCTAssertNil(entry.deliveredRewriteAttemptID)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
    XCTAssertEqual(try payloadBytes(store), 11)
  }

  // MARK: Admission

  func testBeginAssignsOrdinalsHashesInputAndMirrorsPendingState() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let before = try payloadBytes(store)
    let first = try await store.begin(admission(entry))
    XCTAssertEqual(first.ordinal, 1)
    XCTAssertEqual(first.state, .pending)
    XCTAssertEqual(first.transcriptionID, entry.id)
    XCTAssertEqual(first.mode, .clean)
    XCTAssertEqual(first.inputText, entry.text)
    XCTAssertEqual(first.inputHash, TranscriptionQualityDetail.hash(entry.text))
    XCTAssertEqual(first.inputHash.count, 64)
    XCTAssertNil(first.outputText)
    XCTAssertEqual(first.protocolVersion, 1)
    XCTAssertEqual(first.endpointOrigin, "http://127.0.0.1:8080")
    XCTAssertFalse(first.delivered)
    let inputBytes = entry.text.utf8.count
    XCTAssertEqual(try payloadBytes(store), before + inputBytes + min(4 * inputBytes, 65_536))
    let pendingFetched = try await store.get(entry.id)
    let pending = try XCTUnwrap(pendingFetched)
    XCTAssertEqual(pending.rewriteState, .pending)
    XCTAssertEqual(pending.revision, entry.revision, "rewrite changes never bump the revision")
    _ = try await store.recordFailure(id: first.id, category: .serverUnreachable, spans: spans())
    let second = try await store.begin(admission(entry, mode: .polished))
    XCTAssertEqual(second.ordinal, 2)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.map(\.ordinal), [1, 2])
    XCTAssertEqual(Set(attempts.map(\.id)).count, 2)
  }

  func testEleventhBeginThrowsAttemptLimitAndWritesNothing() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    for _ in 0..<10 {
      let attempt = try await store.begin(admission(entry))
      _ = try await store.recordFailure(id: attempt.id, category: .timeout, spans: spans())
    }
    let bytes = try payloadBytes(store)
    let category = await rewriteFailure { _ = try await store.begin(self.admission(entry)) }
    XCTAssertEqual(category, .attemptLimit)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.count, 10)
    XCTAssertEqual(attempts.map(\.ordinal), Array(1...10))
    XCTAssertEqual(try payloadBytes(store), bytes)
    let currentFetched = try await store.get(entry.id)
    let current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .timedOut)
  }

  func testBeginWhilePendingThrowsConcurrencyLimitAndWritesNothing() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let pending = try await store.begin(admission(entry))
    let bytes = try payloadBytes(store)
    let category = await rewriteFailure { _ = try await store.begin(self.admission(entry)) }
    XCTAssertEqual(category, .concurrencyLimit)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.map(\.id), [pending.id])
    XCTAssertEqual(try payloadBytes(store), bytes)
    // Two pending attempts overall is the global cap, re-checked in the transaction.
    let second = try await commit(store, text: "second dictation")
    let third = try await commit(store, text: "third dictation")
    _ = try await store.begin(admission(second))
    let overall = await rewriteFailure { _ = try await store.begin(self.admission(third)) }
    XCTAssertEqual(overall, .concurrencyLimit)
    let thirdAttempts = try await store.attempts(for: third.id)
    XCTAssertTrue(thirdAttempts.isEmpty)
    let thirdEntryFetched = try await store.get(third.id)
    let thirdEntry = try XCTUnwrap(thirdEntryFetched)
    XCTAssertEqual(thirdEntry.rewriteState, .notRequested)
  }

  func testBeginThrowsCapacityExceededWithoutRowOrOrdinal() async throws {
    let store = try makeStore()
    let entry = try await commit(store, text: String(repeating: "\u{1F600}", count: 16_384))
    // Fill the quota so the next reservation of 65,536 + 65,536 bytes cannot fit.
    try await store.database.write { db in
      try db.execute(
        sql: "UPDATE history_usage SET payload_bytes=? WHERE id=1",
        arguments: [TranscriptionStore.maximumPayloadBytes - 131_071])
    }
    let bytes = try payloadBytes(store)
    let category = await rewriteFailure { _ = try await store.begin(self.admission(entry)) }
    XCTAssertEqual(category, .capacityExceeded)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
    XCTAssertEqual(try payloadBytes(store), bytes)
    let currentFetched = try await store.get(entry.id)
    let current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .notRequested)
    try await store.database.write { db in
      try db.execute(
        sql: "UPDATE history_usage SET payload_bytes=? WHERE id=1",
        arguments: [TranscriptionStore.maximumPayloadBytes - 131_072])
    }
    let admitted = try await store.begin(admission(entry))
    XCTAssertEqual(admitted.ordinal, 1, "a refused admission consumes no ordinal")
    XCTAssertEqual(try payloadBytes(store), TranscriptionStore.maximumPayloadBytes)
  }

  func testBeginRequiresAnExistingTranscription() async throws {
    let store = try makeStore()
    let entry = try TranscriptionEntry(
      id: UUID(), text: "ghost", createdAtMilliseconds: 1, quality: .complete,
      stopReason: .keyRelease)
    do {
      _ = try await store.begin(admission(entry))
      XCTFail("must reject an unknown dictation")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .missingEntry) }
  }

  // MARK: Terminal states

  func testRecordResultStoresOutputIdentityAndSpansAndAdjustsQuota() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    let before = try payloadBytes(store)
    let inputBytes = entry.text.utf8.count
    let output = "Peter, can you move it?"
    let recorded = try await store.recordResult(
      id: attempt.id, result: result(text: output), spans: spans())
    XCTAssertEqual(recorded.state, .succeeded)
    XCTAssertEqual(recorded.outputText, output)
    XCTAssertEqual(recorded.outputHash, TranscriptionQualityDetail.hash(output))
    XCTAssertFalse(recorded.unchanged)
    XCTAssertNil(recorded.failureCategory)
    XCTAssertEqual(recorded.identity.serverName, "flowd")
    XCTAssertEqual(recorded.identity.serverVersion, "0.2.0")
    XCTAssertEqual(recorded.identity.backendKind, "openai-compatible")
    XCTAssertEqual(recorded.identity.backendModel, "qwen2.5-3b")
    XCTAssertEqual(recorded.identity.promptVersion, 1)
    XCTAssertEqual(recorded.identity.shieldVersion, 1)
    XCTAssertEqual(recorded.spans.durationMilliseconds, 900)
    XCTAssertEqual(recorded.spans.firstByteMilliseconds, 200)
    XCTAssertEqual(recorded.spans.networkMilliseconds, 800)
    XCTAssertEqual(recorded.spans.requestBytes, 120)
    XCTAssertEqual(recorded.spans.responseBytes, 340)
    XCTAssertEqual(recorded.serverQueueMilliseconds, 3)
    XCTAssertEqual(recorded.backendFirstTokenMilliseconds, 180)
    XCTAssertEqual(recorded.backendMilliseconds, 610)
    XCTAssertEqual(
      try payloadBytes(store), before - min(4 * inputBytes, 65_536) + output.utf8.count)
    let currentFetched = try await store.get(entry.id)
    let current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .succeeded)
    let unchanged = try await store.begin(admission(entry))
    let same = try await store.recordResult(
      id: unchanged.id, result: result(text: entry.text), spans: spans())
    XCTAssertTrue(same.unchanged)
  }

  func testRecordFailureAcceptsOnlyPersistedCodes() async throws {
    let store = try makeStore()
    for category in RewriteFailureCategory.persisted {
      let entry = try await commit(store, text: "twelve bytes")
      let attempt = try await store.begin(admission(entry))
      let recorded = try await store.recordFailure(
        id: attempt.id, category: category, spans: spans())
      XCTAssertEqual(recorded.state, category == .timeout ? .timedOut : .failed)
      XCTAssertEqual(recorded.failureCategory, category)
      XCTAssertNil(recorded.outputText)
      XCTAssertNil(recorded.outputHash)
    }
    // Each dictation holds its text once and its failed attempt's input once.
    XCTAssertEqual(try payloadBytes(store), RewriteFailureCategory.persisted.count * 2 * 12)
    let fresh = try await commit(store, text: "another")
    for refusal in RewriteFailureCategory.allCases where !refusal.isPersistable {
      let attempt = try await store.begin(admission(fresh))
      do {
        _ = try await store.recordFailure(id: attempt.id, category: refusal, spans: spans())
        XCTFail("\(refusal) must not be persisted")
      } catch {
        // The check constraint rejects it; the row stays pending for a valid terminal write.
        XCTAssertTrue(error is DatabaseError, "\(error)")
      }
      let stillPending = try await store.attempts(for: fresh.id).last
      XCTAssertEqual(stillPending?.state, .pending)
      _ = try await store.recordCancelled(id: attempt.id, spans: spans())
    }
  }

  func testRecordCancelledLeavesOutputNullAndReleasesReservation() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let before = try payloadBytes(store)
    let attempt = try await store.begin(admission(entry))
    let cancelled = try await store.recordCancelled(id: attempt.id, spans: spans(duration: 50))
    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertNil(cancelled.outputText)
    XCTAssertNil(cancelled.failureCategory)
    XCTAssertEqual(cancelled.spans.durationMilliseconds, 50)
    XCTAssertEqual(try payloadBytes(store), before + entry.text.utf8.count)
    let currentFetched = try await store.get(entry.id)
    let current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .cancelled)
  }

  func testTerminalStatesAreFinal() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    _ = try await store.recordCancelled(id: attempt.id, spans: spans())
    do {
      _ = try await store.recordResult(id: attempt.id, result: result(), spans: spans())
      XCTFail("a terminal attempt must not change state")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .invalidAttempt) }
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.first?.state, .cancelled)
  }

  func testMarkStaleSetsFlagWithoutChangingState() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    _ = try await store.recordFailure(id: attempt.id, category: .timeout, spans: spans())
    try await store.markStale(id: attempt.id)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.first?.state, .timedOut)
    XCTAssertEqual(attempts.first?.stale, true)
    let currentFetched = try await store.get(entry.id)
    let current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .timedOut)
  }

  func testRewriteStateMirrorsNewestAttempt() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let first = try await store.begin(admission(entry))
    _ = try await store.recordResult(id: first.id, result: result(), spans: spans())
    let second = try await store.begin(admission(entry, mode: .concise))
    var currentFetched = try await store.get(entry.id)
    var current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .pending)
    _ = try await store.recordFailure(id: second.id, category: .backendUnavailable, spans: spans())
    let refetched = try await store.get(entry.id)
    current = try XCTUnwrap(refetched)
    XCTAssertEqual(current.rewriteState, .failed)
  }

  // MARK: Delivery, startup, deletion

  func testRecordOutcomeWritesDeliveredSourceAndAttemptFlag() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    _ = try await store.recordResult(id: attempt.id, result: result(), spans: spans())
    let insertion = try await store.beginAttempt(id: entry.id, revision: entry.revision)
    let delivered = try await store.recordOutcome(
      id: entry.id, revision: insertion.entry.revision, attemptID: insertion.id,
      outcome: .confirmed,
      delivery: RewriteDelivery(
        source: .rewrite, attemptID: attempt.id, durationMilliseconds: 1_250))
    XCTAssertEqual(delivered.deliveredSource, .rewrite)
    XCTAssertEqual(delivered.deliveredRewriteAttemptID, attempt.id)
    XCTAssertEqual(delivered.deliveryState, .confirmed)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.first?.delivered, true)
    XCTAssertEqual(attempts.first?.spans.durationMilliseconds, 1_250)
    // The Feature 002 call records a faithful delivery with no attempt reference.
    let faithful = try await commit(store, text: "plain")
    let plain = try await store.beginAttempt(id: faithful.id, revision: faithful.revision)
    let recorded = try await store.recordOutcome(
      id: faithful.id, revision: plain.entry.revision, attemptID: plain.id, outcome: .notInserted)
    XCTAssertEqual(recorded.deliveredSource, .faithful)
    XCTAssertNil(recorded.deliveredRewriteAttemptID)
    XCTAssertEqual(recorded.rewriteState, .notRequested)
  }

  func testCancelPendingOnStartupTurnsPendingIntoInterrupted() async throws {
    let directory = try makeDirectory()
    let path = directory.appendingPathComponent("history.sqlite").path
    var store = try TranscriptionStore(path: path)
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    let bytes = try payloadBytes(store)
    let interruptedCount = try await store.cancelPendingOnStartup()
    XCTAssertEqual(interruptedCount, 1)
    let interrupted = try await store.attempts(for: entry.id)
    XCTAssertEqual(interrupted.first?.id, attempt.id)
    XCTAssertEqual(interrupted.first?.state, .failed)
    XCTAssertEqual(interrupted.first?.failureCategory, .interrupted)
    XCTAssertEqual(try payloadBytes(store), bytes - min(4 * entry.text.utf8.count, 65_536))
    var currentFetched = try await store.get(entry.id)
    var current = try XCTUnwrap(currentFetched)
    XCTAssertEqual(current.rewriteState, .failed)
    let secondCount = try await store.cancelPendingOnStartup()
    XCTAssertEqual(secondCount, 0)
    // A pending row left by a crash is fixed by the next open, and reconciliation
    // counts attempt bytes.
    let second = try await store.begin(admission(entry, mode: .polished))
    XCTAssertEqual(second.state, .pending)
    store = try TranscriptionStore(path: path)
    let reopened = try await store.attempts(for: entry.id)
    XCTAssertEqual(reopened.map(\.state), [.failed, .failed])
    XCTAssertEqual(reopened.last?.failureCategory, .interrupted)
    let reopenedEntry = try await store.get(entry.id)
    current = try XCTUnwrap(reopenedEntry)
    XCTAssertEqual(current.rewriteState, .failed)
    XCTAssertEqual(try payloadBytes(store), entry.text.utf8.count * 3)
  }

  func testDeleteConfirmedCascadesToAttemptsAndReleasesTheirBytes() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    let first = try await store.begin(admission(entry))
    _ = try await store.recordResult(id: first.id, result: result(), spans: spans())
    let second = try await store.begin(admission(entry))
    _ = try await store.recordFailure(id: second.id, category: .timeout, spans: spans())
    let insertion = try await store.beginAttempt(id: entry.id, revision: entry.revision)
    let delivered = try await store.recordOutcome(
      id: entry.id, revision: insertion.entry.revision, attemptID: insertion.id,
      outcome: .confirmed,
      delivery: RewriteDelivery(source: .rewrite, attemptID: first.id, durationMilliseconds: nil))
    XCTAssertEqual(delivered.text, entry.text)
    try await store.deleteConfirmed(id: entry.id, revision: delivered.revision)
    let rows = try await store.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM rewrite_attempts WHERE transcription_id=?",
        arguments: [entry.id.uuidString]) ?? -1
    }
    XCTAssertEqual(rows, 0)
    XCTAssertEqual(try payloadBytes(store), 0)
    let remaining = try await store.recent()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testDeleteIsRefusedWhileAnAttemptIsPending() async throws {
    let store = try makeStore()
    let entry = try await commit(store)
    _ = try await store.begin(admission(entry))
    do {
      try await store.deleteConfirmed(id: entry.id, revision: entry.revision)
      XCTFail("a pending attempt keeps the dictation")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .busy) }
  }
}
