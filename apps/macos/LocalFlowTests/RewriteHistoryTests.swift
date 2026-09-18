import GRDB
import XCTest

@testable import LocalFlow

/// US5 (T047): history rows, the detail's Rewrite section, restart survival,
/// deletion and legacy rows, against the real store on a private file.
@MainActor
final class RewriteHistoryTests: XCTestCase {
  private var ownedDirectories: [URL] = []
  private var rigs: [RewriteRig] = []

  override func tearDown() async throws {
    for rig in rigs { rig.removeSuite() }
    rigs.removeAll()
    for directory in ownedDirectories.reversed() {
      try? FileManager.default.removeItem(at: directory)
    }
    ownedDirectories.removeAll()
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rewrite-history-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return directory
  }

  private func commit(_ store: TranscriptionStore, text: String = "move it to monday")
    async throws -> TranscriptionEntry
  {
    let entry = try TranscriptionEntry(
      id: UUID(), text: text, createdAtMilliseconds: 10, quality: .complete,
      stopReason: .keyRelease)
    return try await store.commit(reservation: try await store.reserve(), entry: entry)
  }

  private func admission(_ entry: TranscriptionEntry, mode: RewriteMode = .clean)
    -> RewriteAdmission
  {
    RewriteAdmission(
      transcriptionID: entry.id, mode: mode, inputText: entry.text,
      endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false)
  }

  private func result(_ text: String) -> RewriteResult {
    RewriteResult(
      text: text, unchanged: false, serverName: "flowd", serverVersion: "0.2.0",
      backendKind: "openai-compatible", backendModel: "qwen2.5-3b", promptVersion: 1,
      shieldVersion: 1, serverQueueMilliseconds: 2, backendFirstTokenMilliseconds: 150,
      backendMilliseconds: 500)
  }

  private func spans() -> RewriteSpans {
    RewriteSpans(
      durationMilliseconds: 900, firstByteMilliseconds: 200, networkMilliseconds: 700,
      requestBytes: 100, responseBytes: 300)
  }

  private func settle(_ model: HistoryViewModel) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while model.isLoading || model.isDetailLoading || model.isRewriteBusy {
      guard clock.now < deadline else { return XCTFail("history did not settle") }
      await Task.yield()
    }
  }

  private func openDetail(_ model: HistoryViewModel, _ entry: TranscriptionEntry) async throws {
    model.refresh()
    try await settle(model)
    model.showDetail(entry)
    try await settle(model)
  }

  // MARK: Badges and detail state

  func testBadgesMirrorTheNewestAttemptAndNotRequestedHasNone() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let plain = try await commit(store, text: "nothing requested")
    let rewritten = try await commit(store, text: "rewrite me")
    let attempt = try await store.begin(admission(rewritten))
    _ = try await store.recordResult(
      id: attempt.id, result: result("Rewrite me."), spans: spans())
    let rows = try await store.recent()
    let plainRow = try XCTUnwrap(rows.first { $0.id == plain.id })
    let rewrittenRow = try XCTUnwrap(rows.first { $0.id == rewritten.id })
    XCTAssertNil(plainRow.rewriteLabel)
    XCTAssertEqual(rewrittenRow.rewriteLabel, "Rewritten")
  }

  func testDetailOrdersAttemptsAndNamesTheCurrentAndDeliveredText() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    let first = try await store.begin(admission(entry, mode: .clean))
    let delivered = try await store.recordResult(
      id: first.id, result: result("Move it to Monday."), spans: spans())
    // The first attempt is what was inserted.
    let attempt = try await store.beginAttempt(id: entry.id, revision: entry.revision)
    let saved = try await store.recordOutcome(
      id: entry.id, revision: attempt.entry.revision, attemptID: attempt.id, outcome: .confirmed,
      delivery: RewriteDelivery(
        source: .rewrite, attemptID: delivered.id, durationMilliseconds: 1_100))
    let second = try await store.begin(admission(entry, mode: .polished))
    _ = try await store.recordResult(
      id: second.id, result: result("Please move it to Monday."), spans: spans())

    let model = HistoryViewModel(store: store)
    try await openDetail(model, saved)
    XCTAssertEqual(model.detailAttempts.map(\.ordinal), [1, 2])
    XCTAssertEqual(model.detailAttempts.map(\.mode), [.clean, .polished])
    XCTAssertEqual(model.detailAttempts.first?.spans.firstByteMilliseconds, 200)
    XCTAssertEqual(model.detailAttempts.first?.identity.backendModel, "qwen2.5-3b")
    XCTAssertTrue(try XCTUnwrap(model.detailAttempts.first).delivered)
    XCTAssertEqual(model.currentRewrite?.ordinal, 2, "the newest succeeded attempt is current")
    XCTAssertEqual(model.deliveredRewrite?.ordinal, 1)
    XCTAssertEqual(
      model.deliveredLine,
      "Delivered: rewrite attempt 1 (Clean). The current rewrite is not the text that was delivered."
    )
    XCTAssertEqual(model.rewriteStateLine, "Rewrite: succeeded")
  }

  func testAStaleSucceededAttemptIsNeverTheCurrentRewrite() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    let first = try await store.begin(admission(entry))
    _ = try await store.recordResult(id: first.id, result: result("Good."), spans: spans())
    let second = try await store.begin(admission(entry))
    _ = try await store.recordResult(id: second.id, result: result("Late."), spans: spans())
    try await store.markStale(id: second.id)
    let model = HistoryViewModel(store: store)
    try await openDetail(model, entry)
    XCTAssertEqual(model.detailAttempts.count, 2)
    XCTAssertEqual(model.currentRewrite?.ordinal, 1)
    let preserved = try await store.get(entry.id)
    XCTAssertEqual(preserved?.text, entry.text)
  }

  func testAttemptLimitExplanationAppearsAtTenAttempts() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    for _ in 0..<RewriteAttempt.maximumPerDictation {
      let attempt = try await store.begin(admission(entry))
      _ = try await store.recordFailure(
        id: attempt.id, category: .serverUnreachable, spans: spans())
    }
    let model = HistoryViewModel(store: store)
    try await openDetail(model, entry)
    XCTAssertEqual(
      model.rewriteLimitExplanation, "This dictation already has ten rewrite attempts.")
    XCTAssertFalse(model.canRequestRewrite)
  }

  // MARK: Restart, deletion and legacy rows

  func testAttemptsSurviveAReopenAndAPendingAttemptReadsInterrupted() async throws {
    let directory = try makeDirectory()
    let path = directory.appendingPathComponent("history.sqlite").path
    let entryID: UUID
    do {
      let store = try TranscriptionStore(path: path)
      let entry = try await commit(store)
      entryID = entry.id
      let first = try await store.begin(admission(entry))
      _ = try await store.recordResult(id: first.id, result: result("Done."), spans: spans())
      _ = try await store.begin(admission(entry, mode: .concise))
    }
    let reopened = try TranscriptionStore(path: path)
    let model = HistoryViewModel(store: reopened)
    let fetched = try await reopened.get(entryID)
    let entry = try XCTUnwrap(fetched)
    try await openDetail(model, entry)
    XCTAssertEqual(model.detailAttempts.map(\.ordinal), [1, 2])
    XCTAssertEqual(model.detailAttempts[0].state, .succeeded)
    XCTAssertEqual(model.detailAttempts[0].outputText, "Done.")
    XCTAssertEqual(model.detailAttempts[0].identity.promptVersion, 1)
    XCTAssertEqual(model.detailAttempts[1].state, .failed)
    XCTAssertEqual(model.detailAttempts[1].failureCategory, .interrupted)
    XCTAssertEqual(model.detailAttempts[1].endpointOrigin, "http://127.0.0.1:8080")
  }

  func testDeletionLeavesNoAttemptRows() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    let attempt = try await store.begin(admission(entry))
    let recorded = try await store.recordResult(
      id: attempt.id, result: result("Done."), spans: spans())
    let insertion = try await store.beginAttempt(id: entry.id, revision: entry.revision)
    let saved = try await store.recordOutcome(
      id: entry.id, revision: insertion.entry.revision, attemptID: insertion.id,
      outcome: .confirmed,
      delivery: RewriteDelivery(source: .rewrite, attemptID: recorded.id, durationMilliseconds: 1))
    try await store.deleteConfirmed(id: saved.id, revision: saved.revision)
    let attempts = try await store.attempts(for: saved.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testLegacyRowShowsNotRequestedAndNoAttempts() async throws {
    let directory = try makeDirectory()
    let path = directory.appendingPathComponent("history.sqlite").path
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
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await settle(model)
    let entry = try XCTUnwrap(model.entries.first)
    XCTAssertNil(entry.rewriteLabel)
    model.showDetail(entry)
    try await settle(model)
    XCTAssertTrue(model.detailAttempts.isEmpty)
    XCTAssertEqual(model.rewriteStateLine, "Rewrite: not requested")
    XCTAssertEqual(model.currentRewrite, nil)
  }

  // MARK: Retry from history

  func testPendingHistoryRewriteCanBeCancelledFromDetail() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    let rig = RewriteRig(store: store, enabled: true, script: .hang, failOnAnyCall: false)
    rigs.append(rig)
    let model = HistoryViewModel(store: store, rewriter: rig.coordinator)
    try await openDetail(model, entry)
    model.requestRewrite()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.pendingRewrite == nil && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertNotNil(model.pendingRewrite, "Cancel must be available while the request is running")
    XCTAssertEqual(model.rewriteStateLine, "Rewrite: pending")
    model.cancelRewrite()
    // Clean up even when the Cancel control was not exposed.
    if model.pendingRewrite == nil { rig.coordinator.cancel(dictation: entry.id) }
    try await settle(model)
    XCTAssertEqual(model.detailAttempts.last?.state, .cancelled)
    XCTAssertTrue(model.canRequestRewrite)
    XCTAssertEqual(model.detailEnvelope?.entry.text, entry.text)
  }

  func testClosingDetailDuringRewriteDoesNotLeaveOtherEntriesBusy() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let first = try await commit(store)
    let second = try await commit(store, text: "another dictation")
    let rig = RewriteRig(store: store, enabled: true, script: .hang, failOnAnyCall: false)
    rigs.append(rig)
    let model = HistoryViewModel(store: store, rewriter: rig.coordinator)
    try await openDetail(model, first)
    model.requestRewrite()
    await rig.transport.waitUntilCalled()
    model.clearDetail()
    model.showDetail(second)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.isDetailLoading && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertFalse(model.isRewriteBusy)
    XCTAssertTrue(model.canRequestRewrite)
    rig.coordinator.cancel(dictation: first.id)
    await Task.yield()
    XCTAssertNil(model.rewriteNotice, "The other entry must not inherit a cancellation notice")
    XCTAssertTrue(model.detailAttempts.isEmpty)
  }

  func testRetryFromTheDetailUpdatesTheAttemptsAndNeverInserts() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    let rig = RewriteRig(
      store: store, enabled: true, script: .succeed(text: "Move it to Monday."),
      failOnAnyCall: false)
    rigs.append(rig)
    let insertion = FakeInsertion(store: store)
    let model = HistoryViewModel(store: store, rewriter: rig.coordinator)
    try await openDetail(model, entry)
    XCTAssertTrue(model.detailAttempts.isEmpty)
    XCTAssertTrue(model.canRequestRewrite)
    model.rewriteMode = .polished
    model.requestRewrite()
    try await settle(model)
    XCTAssertEqual(rig.callCount, 1)
    XCTAssertEqual(model.detailAttempts.map(\.ordinal), [1])
    XCTAssertEqual(model.detailAttempts.first?.mode, .polished)
    XCTAssertEqual(model.currentRewrite?.outputText, "Move it to Monday.")
    XCTAssertNil(model.rewriteNotice)
    XCTAssertEqual(insertion.dispatchCount, 0, "history never inserts automatically")
    XCTAssertEqual(model.deliveredLine, "Delivered: nothing yet")
    let preserved = try await store.get(entry.id)
    XCTAssertEqual(preserved?.text, entry.text)
  }

  func testAHistoryRefusalShowsTheHistoryNoticeAndLeavesNoRow() async throws {
    let store = try TranscriptionStore(
      path: try makeDirectory().appendingPathComponent("history.sqlite").path)
    let entry = try await commit(store)
    // An https endpoint with no stored credential is refused before any row.
    let rig = RewriteRig(
      store: store, enabled: true, endpoint: "https://rewrite.example", failOnAnyCall: true)
    rigs.append(rig)
    let model = HistoryViewModel(store: store, rewriter: rig.coordinator)
    try await openDetail(model, entry)
    model.requestRewrite()
    try await settle(model)
    XCTAssertEqual(rig.callCount, 0)
    XCTAssertEqual(model.rewriteNotice, "Rewriting skipped: no credential for this server.")
    XCTAssertFalse(
      try XCTUnwrap(model.rewriteNotice).contains("Original text inserted."),
      "history notices never claim an insertion")
    XCTAssertTrue(model.detailAttempts.isEmpty)
    let reloaded = try await store.get(entry.id)
    XCTAssertEqual(reloaded?.rewriteState, .notRequested)
  }
}
