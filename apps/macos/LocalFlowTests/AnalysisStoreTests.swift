import GRDB
import XCTest

@testable import LocalFlow

/// T018: migration, transition table, adoption atomicity and overlay
/// persistence for the seven `intelligence-v9` tables.
final class AnalysisStoreTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: AnalysisStore { fixture.analysis }
  private let now: Int64 = 1_700_000_000_000

  override func setUpWithError() throws { fixture = try MeetingTestStore.make() }
  override func tearDown() { fixture.cleanup() }

  // MARK: Helpers

  private var evidence: EvidenceVersion {
    EvidenceVersion(
      hex: String(repeating: "a", count: 64))
  }

  private var identity: RunIdentity {
    RunIdentity(
      serverVersion: "0.2.0", backendKind: "openai-compatible", backendModel: "test-model",
      promptVersions: "full=3", pipelineVersion: AnalysisPolicy.pipelineVersion)
  }

  private func meeting() async throws -> UUID {
    try await fixture.store.create(now: now).id
  }

  private func runningRun(in meetingID: UUID, at time: Int64? = nil) async throws -> AnalysisRun {
    let at = time ?? now
    let run = try await store.admit(
      meetingID: meetingID, trigger: .manual, evidence: evidence, passID: UUID(),
      policy: AnalysisPolicy(), now: at)
    return try await store.start(runID: run.id, now: at + 1)
  }

  private func validated() -> ValidatedAnalysis {
    let source = SourceRef.note(ordinal: 1, hash: String(repeating: "b", count: 64))
    return ValidatedAnalysis(
      language: .en,
      summary: ValidatedSummary(text: "Shipped the plan.", sources: [source], wholeMeeting: true),
      topics: [
        ValidatedTopic(
          title: "Planning", summary: "Dates agreed.", bullets: ["Next Tuesday"], sources: [source])
      ],
      decisions: [ValidatedItem(kind: .decision, text: "We ship Friday.", sources: [source])],
      actionItems: [
        ValidatedActionItem(
          text: "Oliver sends the invite.",
          owner: .mentioned(name: "Kat"),
          ownershipState: .supported,
          due: ValidatedDue(
            state: .explicitRelativeResolved, date: "2024-01-01", original: "tomorrow",
            source: source),
          sources: [source])
      ],
      nextSteps: [ValidatedItem(kind: .nextStep, text: "Review next week.", sources: [source])],
      openQuestions: [ValidatedItem(kind: .openQuestion, text: "Budget?", sources: [source])],
      risks: [ValidatedItem(kind: .risk, text: "Slip risk.", sources: [source])])
  }

  private func rowCount(_ table: String, meetingID: UUID) async throws -> Int {
    try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM \(table) WHERE meeting_id=?",
        arguments: [meetingID.uuidString]) ?? 0
    }
  }

  // MARK: Migration

  func testMigrationCreatesSevenTablesAndBackfillsMeetingAnalysis() async throws {
    let id = try await meeting()
    try await fixture.history.database.read { db in
      for table in [
        "analysis_runs", "meeting_analysis", "analysis_summaries", "analysis_topics",
        "analysis_items", "analysis_sources", "analysis_overlays",
      ] {
        XCTAssertTrue(try db.tableExists(table), table)
      }
      XCTAssertEqual(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM meeting_analysis WHERE meeting_id=?",
          arguments: [id.uuidString]), 1)
    }
  }

  // MARK: Admit and transitions

  func testAdmitWritesPendingAndRefusesSecondActiveRun() async throws {
    let id = try await meeting()
    let run = try await store.admit(
      meetingID: id, trigger: .automatic, evidence: evidence, passID: UUID(),
      policy: AnalysisPolicy(), now: now)
    XCTAssertEqual(run.state, .pending)
    let pointer = try await store.analysis(meetingID: id)
    XCTAssertEqual(pointer?.currentRunID, run.id)
    await XCTAssertThrowsErrorAsync(
      try await store.admit(
        meetingID: id, trigger: .manual, evidence: evidence, passID: UUID(),
        policy: AnalysisPolicy(), now: now)
    ) { error in
      XCTAssertEqual(error as? AnalysisStore.Error, .activeRunExists)
    }
  }

  func testTransitionTable() async throws {
    let id = try await meeting()
    let run = try await store.admit(
      meetingID: id, trigger: .manual, evidence: evidence, passID: UUID(),
      policy: AnalysisPolicy(), now: now)
    // pending → succeeded is not allowed.
    await XCTAssertThrowsErrorAsync(
      try await store.adopt(
        runID: run.id, result: validated(), counts: ValidationCounts(), identity: identity,
        now: now)
    ) { error in XCTAssertEqual(error as? AnalysisStore.Error, .lateWrite) }

    let started = try await store.start(runID: run.id, now: now + 10)
    XCTAssertEqual(started.state, .running)
    XCTAssertEqual(started.startedAt, now + 10)

    try await store.recordRequest(runID: run.id, inputBytes: 100, outputBytes: 50, retried: true, preempted: true)
    let recorded = try await store.latestRun(meetingID: id)
    XCTAssertEqual(recorded?.requestCount, 1)
    XCTAssertEqual(recorded?.retryCount, 1)
    XCTAssertEqual(recorded?.preemptionCount, 1)
    XCTAssertEqual(recorded?.inputBytes, 100)
    XCTAssertEqual(recorded?.outputBytes, 50)

    // A second active run still cannot be admitted while this one runs.
    await XCTAssertThrowsErrorAsync(
      try await store.admit(
        meetingID: id, trigger: .manual, evidence: evidence, passID: UUID(),
        policy: AnalysisPolicy(), now: now)
    )
  }

  func testFailCancelInterruptAndTimeout() async throws {
    let id = try await meeting()

    let failed = try await runningRun(in: id, at: now)
    try await store.fail(runID: failed.id, category: .backendTimeout, detail: "backend_timeout", now: now + 5)
    var run = try await store.latestRun(meetingID: id)
    XCTAssertEqual(run?.state, .failed)
    XCTAssertEqual(run?.failureCategory, .backendTimeout)
    XCTAssertEqual(run?.completedAt, now + 5)

    let timedOut = try await runningRun(in: id, at: now + 10)
    try await store.timeOut(runID: timedOut.id, now: now + 16)
    run = try await store.latestRun(meetingID: id)
    XCTAssertEqual(run?.state, .timedOut)
    XCTAssertEqual(run?.failureCategory, .timeout)

    let cancelled = try await runningRun(in: id, at: now + 20)
    try await store.cancel(runID: cancelled.id, now: now + 27)
    run = try await store.latestRun(meetingID: id)
    XCTAssertEqual(run?.state, .cancelled)
    XCTAssertNil(run?.failureCategory)

    let interrupted = try await runningRun(in: id, at: now + 30)
    try await store.interrupt(runID: interrupted.id, now: now + 8)
    run = try await store.latestRun(meetingID: id)
    XCTAssertEqual(run?.state, .interrupted)
    XCTAssertEqual(run?.failureCategory, .interrupted)

    // Failed/cancelled/interrupted runs own no content rows.
    let summaryRows = try await rowCount("analysis_summaries", meetingID: id)
    let itemRows = try await rowCount("analysis_items", meetingID: id)
    XCTAssertEqual(summaryRows, 0)
    XCTAssertEqual(itemRows, 0)

    // Nothing may write to a terminal run.
    await XCTAssertThrowsErrorAsync(
      try await store.recordRequest(runID: failed.id, inputBytes: 1, outputBytes: 1, retried: false, preempted: false)
    )
    await XCTAssertThrowsErrorAsync(
      try await store.fail(runID: failed.id, category: .timeout, detail: nil, now: now))
  }

  // MARK: Adoption

  func testAdoptWritesContentAndPointersAtomically() async throws {
    let id = try await meeting()
    let run = try await runningRun(in: id)
    let adopted = try await store.adopt(
      runID: run.id, result: validated(), counts: ValidationCounts(itemCount: 6),
      identity: identity, now: now + 20)
    XCTAssertEqual(adopted.state, .succeeded)
    XCTAssertEqual(adopted.itemCount, 6)
    XCTAssertEqual(adopted.serverVersion, "0.2.0")

    let pointer = try await store.analysis(meetingID: id)
    XCTAssertEqual(pointer?.acceptedRunID, run.id)
    XCTAssertEqual(pointer?.acceptedEvidenceVersion, evidence.hex)

    let model = try await store.readModel(meetingID: id)
    XCTAssertEqual(model?.summary?.text, "Shipped the plan.")
    XCTAssertEqual(model?.topics.count, 1)
    XCTAssertEqual(model?.items.count, 5)
    XCTAssertEqual(model?.items.filter { $0.kind == .actionItem }.count, 1)
    let sourceRows = try await rowCount("analysis_sources", meetingID: id)
    XCTAssertEqual(sourceRows, 7)

    // A late write for the accepted run is refused.
    await XCTAssertThrowsErrorAsync(
      try await store.recordRequest(runID: run.id, inputBytes: 1, outputBytes: 1, retried: false, preempted: false)
    )
  }

  func testAdoptSupersedesPreviousRunAndPreservesItByteIdentical() async throws {
    let id = try await meeting()
    let first = try await runningRun(in: id)
    try await store.adopt(
      runID: first.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 20)
    let firstRun = try await store.latestRun(meetingID: id)

    let second = try await runningRun(in: id)
    try await store.adopt(
      runID: second.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 30)

    // The previous accepted run is superseded and owns no content rows.
    let superseded = try await store.runs(meetingID: id, limit: 10)
      .first { $0.id == first.id }
    XCTAssertEqual(superseded?.state, .superseded)
    let orphanItems = try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM analysis_items WHERE run_id=?",
        arguments: [first.id.uuidString])
    }
    XCTAssertEqual(orphanItems, 0)
    // But the row itself is untouched apart from its state.
    XCTAssertEqual(superseded?.evidenceVersion, firstRun?.evidenceVersion)
    XCTAssertEqual(superseded?.trigger, firstRun?.trigger)

    let pointer = try await store.analysis(meetingID: id)
    XCTAssertEqual(pointer?.acceptedRunID, second.id)
  }

  func testAdoptRefusesWriteForStaleCurrentRun() async throws {
    let id = try await meeting()
    let first = try await runningRun(in: id)
    try await store.cancel(runID: first.id, now: now + 5)
    let second = try await runningRun(in: id)
    // `first` is no longer running: adopt on it must refuse.
    await XCTAssertThrowsErrorAsync(
      try await store.adopt(
        runID: first.id, result: validated(), counts: ValidationCounts(), identity: identity,
        now: now)
    ) { error in XCTAssertEqual(error as? AnalysisStore.Error, .lateWrite) }
    // `second` is current and running: works.
    try await store.adopt(
      runID: second.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 10)
  }

  func testRunRowPruningKeepsAcceptedRun() async throws {
    let id = try await meeting()
    // 25 failed runs then one accepted: only 20 rows remain, accepted kept.
    for _ in 0..<25 {
      let run = try await runningRun(in: id)
      try await store.fail(runID: run.id, category: .timeout, detail: nil, now: now)
    }
    let accepted = try await runningRun(in: id)
    try await store.adopt(
      runID: accepted.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 100)
    let runs = try await store.runs(meetingID: id, limit: 100)
    XCTAssertEqual(runs.count, 20)
    XCTAssertTrue(runs.contains { $0.id == accepted.id })
  }

  // MARK: Overlays

  func testOverlayUpsertRemoveAndCap() async throws {
    let id = try await meeting()
    let run = try await runningRun(in: id)
    try await store.adopt(
      runID: run.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 20)
    let item = try await store.readModel(meetingID: id)!.items.first { $0.kind == .decision }!

    let snapshot = OverlaySnapshot(aiValue: "AI", itemText: item.text, sourceKey: "n:1")
    try await store.setOverlay(
      meetingID: id, target: .item(item.id), field: .decisionText, value: .text("edited"),
      snapshot: snapshot, now: now + 30)
    var overlays = try await store.overlays(meetingID: id)
    XCTAssertEqual(overlays.count, 1)
    XCTAssertEqual(overlays[0].value, .text("edited"))
    XCTAssertNil(overlays[0].orphanedAt)

    // Upsert: same (item, field) replaces, does not duplicate.
    try await store.setOverlay(
      meetingID: id, target: .item(item.id), field: .decisionText, value: .text("edited twice"),
      snapshot: snapshot, now: now + 31)
    overlays = try await store.overlays(meetingID: id)
    XCTAssertEqual(overlays.count, 1)
    XCTAssertEqual(overlays[0].value, .text("edited twice"))

    // One summary overlay per meeting.
    try await store.setOverlay(
      meetingID: id, target: .summary, field: .summaryText, value: .text("my summary"),
      snapshot: OverlaySnapshot(), now: now + 32)
    overlays = try await store.overlays(meetingID: id)
    XCTAssertEqual(overlays.count, 2)

    try await store.removeOverlay(id: overlays[0].id)
    overlays = try await store.overlays(meetingID: id)
    XCTAssertEqual(overlays.count, 1)
    try await store.removeAllOverlays(meetingID: id)
    let remaining = try await store.overlays(meetingID: id)
    XCTAssertEqual(remaining.count, 0)
  }

  func testOverlayCapRefusesBeyondLimit() async throws {
    let id = try await meeting()
    let now = self.now
    // Direct inserts are fine: the cap applies to setOverlay.
    try await fixture.history.database.write { db in
      for _ in 0..<500 {
        try db.execute(
          sql: """
            INSERT INTO analysis_overlays (id, meeting_id, target_kind, item_kind, field,
              user_value, created_at, updated_at)
            VALUES (?, ?, 'item', 'decision', 'decision_text', 'x', ?, ?)
            """, arguments: [UUID().uuidString, id.uuidString, now, now])
      }
    }
    await XCTAssertThrowsErrorAsync(
      try await store.setOverlay(
        meetingID: id, target: .item(UUID()), field: .decisionText, value: .text("x"),
        snapshot: OverlaySnapshot(), now: now)
    ) { error in
      XCTAssertEqual(
        (error as? AnalysisFailure)?.category, .persistenceCapacity)
    }
  }

  func testAdoptRematchesOverlaysAndOrphansUnmatched() async throws {
    let id = try await meeting()
    let first = try await runningRun(in: id)
    try await store.adopt(
      runID: first.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 20)
    let item = try await store.readModel(meetingID: id)!.items.first { $0.kind == .decision }!
    // An overlay anchored on the item's source key re-matches the regenerated
    // item that carries the same sources.
    try await store.setOverlay(
      meetingID: id, target: .item(item.id), field: .decisionText, value: .text("keep me"),
      snapshot: OverlaySnapshot(
        aiValue: "AI", itemText: item.text, sourceKey: "n:1"), now: now + 21)
    // An orphan anchored on a source the next run will not produce.
    let now = self.now
    try await fixture.history.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO analysis_overlays (id, meeting_id, item_id, target_kind, item_kind, field,
            user_value, item_text_snapshot, source_key, created_at, updated_at)
          VALUES (?, ?, ?, 'item', 'decision', 'status', 'open', 'gone', 'n:99', ?, ?)
          """,
        arguments: [UUID().uuidString, id.uuidString, item.id.uuidString, now + 22, now + 22])
    }

    let second = try await runningRun(in: id)
    try await store.adopt(
      runID: second.id, result: validated(), counts: ValidationCounts(), identity: identity,
      now: now + 40)

    let overlays = try await store.overlays(meetingID: id)
    let rematched = overlays.first { $0.field == .decisionText }
    let orphaned = overlays.first { $0.field == .status }
    XCTAssertEqual(rematched?.value, .text("keep me"))
    let newDecision = try await store.readModel(meetingID: id)!.items.first { $0.kind == .decision }!
    XCTAssertEqual(rematched?.itemID, newDecision.id)
    XCTAssertNil(rematched?.orphanedAt)
    XCTAssertNotNil(orphaned?.orphanedAt)
    XCTAssertNil(orphaned?.itemID)
  }

  // MARK: Schema checks

  func testCheckConstraintsRejectViolations() async throws {
    let id = try await meeting()
    try await fixture.history.database.write { db in
      // evidence_version must be 64 lowercase hex.
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO analysis_runs (id, meeting_id, state, "trigger", evidence_version,
              protocol_version, schema_version, created_at)
            VALUES (?, ?, 'pending', 'manual', 'short', 1, 1, 0)
            """, arguments: [UUID().uuidString, id.uuidString]))
      // failure_category outside the closed set.
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO analysis_runs (id, meeting_id, state, "trigger", evidence_version,
              protocol_version, schema_version, created_at, failure_category)
            VALUES (?, ?, 'failed', 'manual', ?, 1, 1, 0, 'nonsense')
            """, arguments: [UUID().uuidString, id.uuidString, String(repeating: "a", count: 64)]))
      // A non-action-item may not carry owner columns.
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text, owner_kind)
            VALUES (?, ?, ?, 'decision', 0, 'text', 'mentioned')
            """, arguments: [UUID().uuidString, UUID().uuidString, id.uuidString]))
      // owner_name only when mentioned.
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text,
              owner_kind, owner_name)
            VALUES (?, ?, ?, 'action_item', 0, 'text', 'participant', 'name')
            """, arguments: [UUID().uuidString, UUID().uuidString, id.uuidString]))
    }
  }
}

/// `XCTAssertThrowsError` for async calls.
func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
  _ handler: (Error) -> Void = { _ in }
) async {
  do {
    _ = try await expression()
    XCTFail("expected error \(message)", file: file, line: line)
  } catch {
    handler(error)
  }
}
