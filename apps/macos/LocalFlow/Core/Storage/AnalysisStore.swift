import Foundation
import GRDB
import OSLog

/// Every analysis-table write goes through this actor. It shares the history
/// `DatabaseQueue`, keeps run rows content-free, follows the `analysis_runs`
/// transition table, refuses writes for a run that is no longer `running` or
/// no longer `current_run_id`, and performs `adopt` as one transaction:
/// supersede the previous accepted run, replace its content, re-match
/// overlays through the injected `overlay_match_v1` function and prune run
/// rows. Logs counts and codes only — never summary, item or overlay text.
actor AnalysisStore: AnalysisStoring {
  enum Error: Swift.Error, Equatable, Sendable {
    /// A second `pending`/`running` run for the same meeting.
    case activeRunExists
    case missingRun
    case missingMeeting
    /// The transition table (data-model.md) does not allow the move.
    case invalidTransition
    /// The run left `running` or is no longer `current_run_id`.
    case lateWrite
    case damagedDatabase
  }

  /// The overlay re-match function injected into `adopt`
  /// (`OverlayMatcher.match` by default).
  typealias OverlayMatching = @Sendable ([AnalysisOverlay], [StoredItem]) -> (
    matched: [UUID: UUID], orphaned: Set<UUID>
  )

  static let runRowCap = 20
  static let overlayCap = 500
  static let sourceCapPerTarget = 10

  nonisolated let database: DatabaseQueue
  private let matchOverlays: OverlayMatching
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "analysis")

  init(database: DatabaseQueue, matchOverlays: @escaping OverlayMatching = OverlayMatcher.match) {
    self.database = database
    self.matchOverlays = matchOverlays
  }

  init(history: TranscriptionStore, matchOverlays: @escaping OverlayMatching = OverlayMatcher.match)
  {
    self.init(database: history.database, matchOverlays: matchOverlays)
  }

  // MARK: Pointer

  func analysis(meetingID: UUID) throws -> MeetingAnalysisPointer? {
    try database.read { db in try Self.fetchPointer(meetingID, db: db) }
  }

  // MARK: Run lifecycle

  /// Inserts one `pending` run and points `current_run_id` at it. The unique
  /// partial index makes a second active run per meeting impossible.
  @discardableResult
  func admit(
    meetingID: UUID, trigger: AnalysisTrigger, evidence: EvidenceVersion, passID: UUID,
    policy: AnalysisPolicy, now: Int64
  ) throws -> AnalysisRun {
    let run = AnalysisRun(
      id: UUID(), meetingID: meetingID, state: .pending, trigger: trigger,
      evidenceVersion: evidence.hex, transcriptPassID: passID,
      pipelineVersion: AnalysisPolicy.pipelineVersion,
      requestConfigJSON: String(
        decoding: policy.requestConfigJSON().utf8.prefix(policy.maxRequestConfigBytes),
        as: UTF8.self),
      createdAt: now)
    try database.write { db in
      do {
        try db.execute(
          sql: """
            INSERT INTO analysis_runs (id, meeting_id, state, "trigger", evidence_version,
              transcript_pass_id, protocol_version, schema_version, pipeline_version,
              request_config_json, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
          arguments: [
            run.id.uuidString, meetingID.uuidString, run.state.rawValue, trigger.rawValue,
            evidence.hex, passID.uuidString, run.protocolVersion, run.schemaVersion,
            run.pipelineVersion, run.requestConfigJSON, now,
          ])
      } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
        throw Error.activeRunExists
      }
      try Self.touchPointer(meetingID, now: now, db: db)
      try db.execute(
        sql: "UPDATE meeting_analysis SET current_run_id=? WHERE meeting_id=?",
        arguments: [run.id.uuidString, meetingID.uuidString])
    }
    return run
  }

  @discardableResult
  func start(runID: UUID, now: Int64) throws -> AnalysisRun {
    try transition(runID, to: .running, now: now) { db in
      try db.execute(
        sql: "UPDATE analysis_runs SET started_at=COALESCE(started_at, ?) WHERE id=?",
        arguments: [now, runID.uuidString])
    }
  }

  /// Per-request counters; refused once the run left `running`.
  func recordRequest(runID: UUID, inputBytes: Int, outputBytes: Int, retried: Bool, preempted: Bool)
    throws
  {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state == .running else { throw Error.lateWrite }
      try db.execute(
        sql: """
          UPDATE analysis_runs SET request_count=request_count+1, input_bytes=input_bytes+?,
            output_bytes=output_bytes+?, retry_count=retry_count+?, preemption_count=preemption_count+?
          WHERE id=?
          """,
        arguments: [
          max(0, inputBytes), max(0, outputBytes), retried ? 1 : 0, preempted ? 1 : 0,
          runID.uuidString,
        ])
    }
  }

  func fail(runID: UUID, category: AnalysisFailureCategory, detail: String?, now: Int64) throws {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state.canTransition(to: .failed) else { throw Error.invalidTransition }
      let bounded = detail.map { String(decoding: $0.utf8.prefix(512), as: UTF8.self) }
      try db.execute(
        sql: """
          UPDATE analysis_runs SET state='failed', completed_at=?, failure_category=?,
            failure_detail=?, duration_ms=MAX(0, ? - COALESCE(started_at, created_at)) WHERE id=?
          """,
        arguments: [now, category.rawValue, bounded, now, runID.uuidString])
    }
    logger.notice("Analysis run failed; category=\(category.rawValue, privacy: .public)")
  }

  func timeOut(runID: UUID, now: Int64) throws {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state.canTransition(to: .timedOut) else { throw Error.invalidTransition }
      try db.execute(
        sql: """
          UPDATE analysis_runs SET state='timed_out', completed_at=?, failure_category='timeout',
            duration_ms=MAX(0, ? - COALESCE(started_at, created_at)) WHERE id=?
          """,
        arguments: [now, now, runID.uuidString])
    }
  }

  func cancel(runID: UUID, now: Int64) throws {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state.canTransition(to: .cancelled) else { throw Error.invalidTransition }
      try db.execute(
        sql: """
          UPDATE analysis_runs SET state='cancelled', completed_at=?,
            duration_ms=MAX(0, ? - COALESCE(started_at, created_at)) WHERE id=?
          """,
        arguments: [now, now, runID.uuidString])
    }
  }

  /// Launch reconciliation only: a run the process left behind.
  func interrupt(runID: UUID, now: Int64) throws {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state.canTransition(to: .interrupted) else { throw Error.invalidTransition }
      try db.execute(
        sql: """
          UPDATE analysis_runs SET state='interrupted', completed_at=?, failure_category='interrupted',
            duration_ms=MAX(0, ? - COALESCE(started_at, created_at)) WHERE id=?
          """,
        arguments: [now, now, runID.uuidString])
    }
  }

  // MARK: Adoption

  /// One transaction per data-model.md "Retention and deletion". A response
  /// that arrives after the run left `running`, or after a newer run became
  /// `current_run_id`, writes nothing.
  @discardableResult
  func adopt(
    runID: UUID, result: ValidatedAnalysis, counts: ValidationCounts, identity: RunIdentity,
    now: Int64
  ) throws -> AnalysisRun {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state == .running else { throw Error.lateWrite }
      guard let pointer = try Self.fetchPointer(run.meetingID, db: db),
        pointer.currentRunID == runID
      else { throw Error.lateWrite }

      let existing = try Self.fetchOverlays(run.meetingID, db: db)
      if let previous = pointer.acceptedRunID {
        try db.execute(
          sql: "UPDATE analysis_runs SET state='superseded' WHERE id=? AND state='succeeded'",
          arguments: [previous.uuidString])
        for table in ["analysis_summaries", "analysis_topics", "analysis_items", "analysis_sources"]
        {
          try db.execute(
            sql: "DELETE FROM \(table) WHERE run_id=?", arguments: [previous.uuidString])
        }
      }

      try Self.insertContent(run: run, result: result, now: now, db: db)

      // Re-match overlays against the freshly inserted items (R13).
      let newItems = try Self.fetchItems(runID: run.id, db: db)
      let (matched, orphaned) = matchOverlays(existing, newItems)
      for (overlayID, itemID) in matched {
        try db.execute(
          sql: "UPDATE analysis_overlays SET item_id=?, orphaned_at=NULL, updated_at=? WHERE id=?",
          arguments: [itemID.uuidString, now, overlayID.uuidString])
      }
      for overlayID in orphaned {
        try db.execute(
          sql: "UPDATE analysis_overlays SET item_id=NULL, orphaned_at=COALESCE(orphaned_at, ?), updated_at=? WHERE id=?",
          arguments: [now, now, overlayID.uuidString])
      }

      try db.execute(
        sql: """
          UPDATE analysis_runs SET state='succeeded', completed_at=?, server_version=?,
            protocol_version=?, schema_version=?, backend_kind=?, backend_model=?,
            prompt_versions=?, pipeline_version=?, language_policy=?,
            item_count=?, dropped_literal_count=?, dropped_unsupported_count=?,
            identity_downgrade_count=?, unresolved_owner_count=?,
            duration_ms=MAX(0, ? - COALESCE(started_at, created_at))
          WHERE id=?
          """,
        arguments: [
          now, identity.serverVersion, identity.protocolVersion, identity.schemaVersion,
          identity.backendKind, identity.backendModel, identity.promptVersions,
          identity.pipelineVersion, result.language.rawValue, counts.itemCount,
          counts.droppedLiteralCount, counts.droppedUnsupportedCount,
          counts.identityDowngradeCount, counts.unresolvedOwnerCount, now, runID.uuidString,
        ])
      try db.execute(
        sql: """
          UPDATE meeting_analysis SET accepted_run_id=?, accepted_evidence_version=?,
            updated_at=?, revision=revision+1 WHERE meeting_id=?
          """,
        arguments: [runID.uuidString, run.evidenceVersion, now, run.meetingID.uuidString])
      try Self.pruneRuns(run.meetingID, keeping: runID, db: db)
      guard let updated = try Self.fetchRun(runID, db: db) else { throw Error.damagedDatabase }
      return updated
    }
  }

  // MARK: Run reads

  func activeRuns(limit: Int) throws -> [AnalysisRun] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM analysis_runs WHERE state IN ('pending','running')
          ORDER BY created_at, id LIMIT ?
          """, arguments: [max(1, limit)]
      ).compactMap(Self.run)
    }
  }

  func unfinishedRuns(limit: Int) throws -> [AnalysisRun] { try activeRuns(limit: limit) }

  func latestRun(meetingID: UUID) throws -> AnalysisRun? {
    try runs(meetingID: meetingID, limit: 1).first
  }

  func runs(meetingID: UUID, limit: Int) throws -> [AnalysisRun] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM analysis_runs WHERE meeting_id=? ORDER BY created_at DESC, id DESC LIMIT ?",
        arguments: [meetingID.uuidString, max(1, limit)]
      ).compactMap(Self.run)
    }
  }

  func markAutoRestarted(meetingID: UUID, now: Int64) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE meeting_analysis SET auto_restarted_at=?, updated_at=? WHERE meeting_id=?",
        arguments: [now, now, meetingID.uuidString])
    }
  }

  // MARK: Read model

  /// The accepted run's content plus the meeting's overlays. `nil` when no run
  /// was ever accepted.
  func readModel(meetingID: UUID) throws -> StoredAnalysis? {
    try database.read { db in
      guard let pointer = try Self.fetchPointer(meetingID, db: db),
        let accepted = pointer.acceptedRunID,
        let run = try Self.fetchRun(accepted, db: db)
      else { return nil }
      let summary = try Row.fetchOne(
        db, sql: "SELECT * FROM analysis_summaries WHERE run_id=?",
        arguments: [accepted.uuidString]
      ).map { row in
        StoredSummary(
          text: row["text"], language: run.languagePolicy ?? .en,
          wholeMeeting: (row["whole_meeting"] as Int) == 1,
          sources: (try? Self.fetchSources(runID: accepted, kind: "summary", target: accepted.uuidString, db: db)) ?? [])
      }
      let topics = try Row.fetchAll(
        db, sql: "SELECT * FROM analysis_topics WHERE run_id=? ORDER BY ordinal",
        arguments: [accepted.uuidString]
      ).compactMap { row -> StoredTopic? in
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let bullets =
          (try? JSONDecoder().decode([String].self, from: Data((row["bullets_json"] as String).utf8)))
          ?? []
        return StoredTopic(
          id: id, ordinal: row["ordinal"], title: row["title"], summary: row["summary"],
          bullets: bullets,
          sources: (try? Self.fetchSources(runID: accepted, kind: "topic", target: id.uuidString, db: db)) ?? [])
      }
      let items = try Self.fetchItems(runID: accepted, db: db)
      let overlays = try Self.fetchOverlays(meetingID, db: db)
      return StoredAnalysis(run: run, summary: summary, topics: topics, items: items, overlays: overlays)
    }
  }

  // MARK: Overlays

  /// Upserts on `(item_id, field)` for items and on the meeting's single
  /// summary overlay; refuses beyond `overlayCap` per meeting.
  func setOverlay(
    meetingID: UUID, target: OverlayTarget, field: OverlayField, value: OverlayValue,
    snapshot: OverlaySnapshot, now: Int64
  ) throws {
    let encoded = try Self.encodeOverlayValue(value, field: field)
    try database.write { db in
      let itemID: UUID?
      if case .item(let id) = target {
        itemID = id
      } else {
        itemID = nil
      }
      let itemKind = itemID.flatMap { id in
        (try? String.fetchOne(
          db, sql: "SELECT kind FROM analysis_items WHERE id=?", arguments: [id.uuidString]))
          .flatMap(AnalysisItemKind.init(rawValue:))
      }
      let existing: String? = try String.fetchOne(
        db,
        sql: itemID != nil
          ? "SELECT id FROM analysis_overlays WHERE item_id=? AND field=?"
          : "SELECT id FROM analysis_overlays WHERE meeting_id=? AND target_kind='summary' AND field=?",
        arguments: itemID != nil
          ? [itemID!.uuidString, field.rawValue] : [meetingID.uuidString, field.rawValue])
      if existing == nil {
        let count = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM analysis_overlays WHERE meeting_id=?",
          arguments: [meetingID.uuidString]) ?? 0
        guard count < Self.overlayCap else {
          throw AnalysisFailure(.persistenceCapacity, detail: "overlay_cap")
        }
      }
      let targetKind = itemID == nil ? "summary" : "item"
      if let existing {
        try db.execute(
          sql: """
            UPDATE analysis_overlays SET user_value=?, ai_value_snapshot=?, item_text_snapshot=?,
              source_key=?, updated_at=? WHERE id=?
            """,
          arguments: [
            encoded, snapshot.aiValue, snapshot.itemText, snapshot.sourceKey, now, existing,
          ])
      } else {
        try db.execute(
          sql: """
            INSERT INTO analysis_overlays (id, meeting_id, item_id, target_kind, item_kind, field,
              user_value, ai_value_snapshot, item_text_snapshot, source_key, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """,
          arguments: [
            UUID().uuidString, meetingID.uuidString, itemID?.uuidString, targetKind,
            itemKind?.rawValue, field.rawValue, encoded, snapshot.aiValue, snapshot.itemText,
            snapshot.sourceKey, now, now,
          ])
      }
    }
  }

  func removeOverlay(id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM analysis_overlays WHERE id=?", arguments: [id.uuidString])
    }
  }

  func removeAllOverlays(meetingID: UUID) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM analysis_overlays WHERE meeting_id=?", arguments: [meetingID.uuidString])
    }
  }

  func overlays(meetingID: UUID) throws -> [AnalysisOverlay] {
    try database.read { db in try Self.fetchOverlays(meetingID, db: db) }
  }

  // MARK: - Transaction helpers

  private func transition(
    _ runID: UUID, to state: AnalysisRunState, now: Int64, extra: (Database) throws -> Void
  ) throws -> AnalysisRun {
    try database.write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRun }
      guard run.state.canTransition(to: state) else { throw Error.invalidTransition }
      try db.execute(
        sql: "UPDATE analysis_runs SET state=? WHERE id=?",
        arguments: [state.rawValue, runID.uuidString])
      try extra(db)
      guard let updated = try Self.fetchRun(runID, db: db) else { throw Error.damagedDatabase }
      return updated
    }
  }

  private static func touchPointer(_ meetingID: UUID, now: Int64, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO meeting_analysis (meeting_id, updated_at, revision) VALUES (?, ?, 0)
        ON CONFLICT(meeting_id) DO UPDATE SET updated_at=excluded.updated_at, revision=revision+1
        """, arguments: [meetingID.uuidString, now])
  }

  /// Deletes the oldest non-accepted run rows until at most `runRowCap` remain.
  private static func pruneRuns(_ meetingID: UUID, keeping runID: UUID, db: Database) throws {
    let count = try Int.fetchOne(
      db, sql: "SELECT COUNT(*) FROM analysis_runs WHERE meeting_id=?",
      arguments: [meetingID.uuidString]) ?? 0
    let excess = count - runRowCap
    guard excess > 0 else { return }
    try db.execute(
      sql: """
        DELETE FROM analysis_runs WHERE id IN (
          SELECT r.id FROM analysis_runs r WHERE r.meeting_id=? AND r.state<>'succeeded'
          ORDER BY r.created_at ASC, r.id ASC LIMIT ?)
        """, arguments: [meetingID.uuidString, excess])
  }

  /// Inserts summary, topics, items and sources for a newly accepted run. The
  /// 10-per-target source cap is enforced before insert.
  private static func insertContent(run: AnalysisRun, result: ValidatedAnalysis, now: Int64, db: Database)
    throws
  {
    let meeting = run.meetingID.uuidString
    let runID = run.id.uuidString
    try db.execute(
      sql: """
        INSERT INTO analysis_summaries (run_id, meeting_id, text, language, whole_meeting)
        VALUES (?,?,?,?,?)
        """,
      arguments: [
        runID, meeting, result.summary.text, result.language.rawValue,
        result.summary.wholeMeeting ? 1 : 0,
      ])
    try insertSources(
      runID: runID, meetingID: meeting, kind: "summary", target: runID,
      sources: result.summary.sources, db: db)
    for (ordinal, topic) in result.topics.enumerated() {
      let id = UUID().uuidString
      let bullets = String(
        decoding: (try? JSONEncoder().encode(topic.bullets)) ?? Data("[]".utf8), as: UTF8.self)
      try db.execute(
        sql: """
          INSERT INTO analysis_topics (id, run_id, meeting_id, ordinal, title, summary, bullets_json)
          VALUES (?,?,?,?,?,?,?)
          """,
        arguments: [id, runID, meeting, ordinal, topic.title, topic.summary, bullets])
      try insertSources(
        runID: runID, meetingID: meeting, kind: "topic", target: id, sources: topic.sources, db: db)
    }
    for (kind, items) in itemGroups(of: result) {
      for (ordinal, item) in items.enumerated() {
        let id = UUID().uuidString
        switch item {
        case .plain(let value):
          try db.execute(
            sql: """
              INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text, evidence_class)
              VALUES (?,?,?,?,?,?,?)
              """,
            arguments: [
              id, runID, meeting, kind.rawValue, ordinal, value.text,
              value.evidenceClass?.rawValue,
            ])
          try insertSources(
            runID: runID, meetingID: meeting, kind: "item", target: id, sources: value.sources,
            db: db)
        case .action(let value):
          let owner = Self.ownerColumns(value.owner)
          try db.execute(
            sql: """
              INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text,
                owner_kind, owner_speaker_id, owner_known_speaker_id, owner_name, owner_certainty,
                ownership_state, due_state, due_date, due_original,
                due_source_segment_id, due_source_note_ordinal)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
              """,
            arguments: [
              id, runID, meeting, kind.rawValue, ordinal, value.text, owner.kind,
              owner.speakerID, owner.knownSpeakerID, owner.name, owner.certainty,
              value.ownershipState.rawValue, value.due.state.rawValue, value.due.date,
              value.due.original, owner.segmentSource(in: value.due),
              owner.noteOrdinal(in: value.due),
            ])
          try insertSources(
            runID: runID, meetingID: meeting, kind: "item", target: id, sources: value.sources,
            db: db)
        }
      }
    }
  }

  private enum InsertedItem {
    case plain(ValidatedItem)
    case action(ValidatedActionItem)
  }

  private static func itemGroups(of result: ValidatedAnalysis) -> [(AnalysisItemKind, [InsertedItem])]
  {
    [
      (.decision, result.decisions.map(InsertedItem.plain)),
      (.actionItem, result.actionItems.map(InsertedItem.action)),
      (.nextStep, result.nextSteps.map(InsertedItem.plain)),
      (.openQuestion, result.openQuestions.map(InsertedItem.plain)),
      (.risk, result.risks.map(InsertedItem.plain)),
    ]
  }

  private struct OwnerColumns {
    var kind: String
    var speakerID: String?
    var knownSpeakerID: String?
    var name: String?
    var certainty: String?
    func segmentSource(in due: ValidatedDue) -> String? {
      guard case .segment(let id) = due.source else { return nil }
      return id.uuidString
    }
    func noteOrdinal(in due: ValidatedDue) -> Int? {
      guard case .note(let ordinal, _) = due.source else { return nil }
      return ordinal
    }
  }

  private static func ownerColumns(_ owner: ValidatedOwner) -> OwnerColumns {
    switch owner {
    case .participant(let speakerID, let knownSpeakerID, let certainty):
      return OwnerColumns(
        kind: "participant", speakerID: speakerID.uuidString,
        knownSpeakerID: knownSpeakerID?.uuidString, name: nil, certainty: certainty.rawValue)
    case .mentioned(let name):
      return OwnerColumns(
        kind: "mentioned", speakerID: nil, knownSpeakerID: nil, name: name, certainty: nil)
    case .none:
      return OwnerColumns(
        kind: "none", speakerID: nil, knownSpeakerID: nil, name: nil, certainty: nil)
    }
  }

  private static func insertSources(
    runID: String, meetingID: String, kind: String, target: String, sources: [SourceRef],
    db: Database
  ) throws {
    for (ordinal, source) in sources.prefix(sourceCapPerTarget).enumerated() {
      let segmentID: String?
      let noteOrdinal: Int?
      let noteHash: String?
      switch source {
      case .segment(let id):
        segmentID = id.uuidString
        noteOrdinal = nil
        noteHash = nil
      case .note(let ordinal, let hash):
        segmentID = nil
        noteOrdinal = ordinal
        noteHash = hash
      }
      try db.execute(
        sql: """
          INSERT INTO analysis_sources (run_id, meeting_id, target_kind, target_id, ordinal,
            source_kind, segment_id, note_ordinal, note_hash)
          VALUES (?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          runID, meetingID, kind, target, ordinal,
          segmentID != nil ? "segment" : "note", segmentID, noteOrdinal, noteHash,
        ])
    }
  }

  // MARK: - Row mapping

  static func fetchPointer(_ meetingID: UUID, db: Database) throws -> MeetingAnalysisPointer? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM meeting_analysis WHERE meeting_id=?",
      arguments: [meetingID.uuidString]
    ).map { row in
      MeetingAnalysisPointer(
        meetingID: meetingID,
        acceptedRunID: (row["accepted_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        currentRunID: (row["current_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        acceptedEvidenceVersion: row["accepted_evidence_version"],
        autoRestartedAt: row["auto_restarted_at"])
    }
  }

  static func fetchRun(_ id: UUID, db: Database) throws -> AnalysisRun? {
    try Row.fetchOne(db, sql: "SELECT * FROM analysis_runs WHERE id=?", arguments: [id.uuidString])
      .flatMap(run)
  }

  static func fetchItems(runID: UUID, db: Database) throws -> [StoredItem] {
    try Row.fetchAll(
      db, sql: "SELECT * FROM analysis_items WHERE run_id=? ORDER BY kind, ordinal",
      arguments: [runID.uuidString]
    ).compactMap { row -> StoredItem? in
      guard let id = UUID(uuidString: row["id"]), let kind = AnalysisItemKind(rawValue: row["kind"])
      else { return nil }
      let owner = Self.decodeOwner(row)
      let due = Self.decodeDue(row)
      return StoredItem(
        id: id, kind: kind, ordinal: row["ordinal"], text: row["text"],
        evidenceClass: (row["evidence_class"] as String?).flatMap(EvidenceClass.init),
        topicID: (row["topic_id"] as String?).flatMap(UUID.init(uuidString:)),
        owner: owner.owner, ownershipState: owner.state, due: due,
        sources: (try? Self.fetchSources(runID: runID, kind: "item", target: id.uuidString, db: db))
          ?? [])
    }
  }

  static func fetchSources(runID: UUID, kind: String, target: String, db: Database) throws
    -> [SourceRef]
  {
    try Row.fetchAll(
      db,
      sql: """
        SELECT source_kind, segment_id, note_ordinal, note_hash FROM analysis_sources
        WHERE run_id=? AND target_kind=? AND target_id=? ORDER BY ordinal
        """, arguments: [runID.uuidString, kind, target]
    ).compactMap { row -> SourceRef? in
      if row["source_kind"] as String == "segment",
        let id = (row["segment_id"] as String?).flatMap(UUID.init(uuidString:))
      { return .segment(id) }
      if row["source_kind"] as String == "note", let ordinal = row["note_ordinal"] as Int? {
        return .note(ordinal: ordinal, hash: (row["note_hash"] as String?) ?? "")
      }
      return nil
    }
  }

  private static func decodeOwner(_ row: Row) -> (owner: ValidatedOwner?, state: OwnershipState?) {
    guard let kind = row["owner_kind"] as String? else { return (nil, nil) }
    let owner: ValidatedOwner?
    switch kind {
    case "participant":
      owner = (row["owner_speaker_id"] as String?).flatMap(UUID.init(uuidString:)).map { id in
        .participant(
          speakerID: id,
          knownSpeakerID: (row["owner_known_speaker_id"] as String?).flatMap(
            UUID.init(uuidString:)),
          certainty: ParticipantCertainty(rawValue: (row["owner_certainty"] as String?) ?? "")
            ?? .unknown)
      }
    case "mentioned": owner = (row["owner_name"] as String?).map { .mentioned(name: $0) }
    default: owner = .none
    }
    return (owner, (row["ownership_state"] as String?).flatMap(OwnershipState.init))
  }

  private static func decodeDue(_ row: Row) -> ValidatedDue? {
    guard let state = (row["due_state"] as String?).flatMap(DueState.init) else { return nil }
    let source: SourceRef?
    if let id = (row["due_source_segment_id"] as String?).flatMap(UUID.init(uuidString:)) {
      source = .segment(id)
    } else if let ordinal = row["due_source_note_ordinal"] as Int? {
      source = .note(ordinal: ordinal, hash: "")
    } else {
      source = nil
    }
    return ValidatedDue(
      state: state, date: row["due_date"], original: row["due_original"], source: source)
  }

  static func fetchOverlays(_ meetingID: UUID, db: Database) throws -> [AnalysisOverlay] {
    try Row.fetchAll(
      db, sql: "SELECT * FROM analysis_overlays WHERE meeting_id=? ORDER BY created_at, id",
      arguments: [meetingID.uuidString]
    ).compactMap(overlay)
  }

  static func overlay(_ row: Row) -> AnalysisOverlay? {
    guard let id = UUID(uuidString: row["id"]), let meetingID = UUID(uuidString: row["meeting_id"]),
      let field = OverlayField(rawValue: row["field"]),
      let value = decodeOverlayValue(row["user_value"], field: field)
    else { return nil }
    let itemID = (row["item_id"] as String?).flatMap(UUID.init(uuidString:))
    let targetKind: OverlayTarget =
      (row["target_kind"] as String?) == "summary" ? .summary : .item(itemID)
    return AnalysisOverlay(
      id: id, meetingID: meetingID, itemID: itemID, targetKind: targetKind,
      itemKind: (row["item_kind"] as String?).flatMap(AnalysisItemKind.init),
      field: field, value: value,
      snapshot: OverlaySnapshot(
        aiValue: row["ai_value_snapshot"], itemText: row["item_text_snapshot"],
        sourceKey: row["source_key"]),
      createdAt: row["created_at"], updatedAt: row["updated_at"], orphanedAt: row["orphaned_at"])
  }

  static func encodeOverlayValue(_ value: OverlayValue, field: OverlayField) throws -> String {
    func quoted(_ text: String) throws -> String {
      guard let data = try? JSONEncoder().encode(text),
        let encoded = String(data: data, encoding: .utf8)
      else { throw Error.damagedDatabase }
      return encoded
    }
    switch value {
    case .text(let text): return text
    case .status(let status): return status.rawValue
    case .dueDate(let date): return date.map { "{\"date\":\"\($0)\"}" } ?? "{\"date\":null}"
    case .owner(let owner):
      switch owner {
      case .participant(let id):
        return "{\"kind\":\"participant\",\"speaker_id\":\"\(id.uuidString)\"}"
      case .mentioned(let name):
        return "{\"kind\":\"mentioned\",\"name\":\(try quoted(name))}"
      case .none: return "{\"kind\":\"none\"}"
      }
    }
  }

  static func decodeOverlayValue(_ raw: String, field: OverlayField) -> OverlayValue? {
    switch field {
    case .status:
      return AnalysisItemStatus(rawValue: raw).map(OverlayValue.status)
    case .dueDate:
      guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
      else { return nil }
      return .dueDate(object["date"] as? String)
    case .owner:
      guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
        let kind = object["kind"] as? String
      else { return nil }
      switch kind {
      case "participant":
        return (object["speaker_id"] as? String).flatMap(UUID.init(uuidString:)).map {
          .owner(.participant($0))
        }
      case "mentioned":
        return (object["name"] as? String).map { .owner(.mentioned($0)) }
      case "none": return .owner(.none)
      default: return nil
      }
    default: return .text(raw)
    }
  }

  static func run(_ row: Row) -> AnalysisRun? {
    guard let id = UUID(uuidString: row["id"]), let meetingID = UUID(uuidString: row["meeting_id"]),
      let state = AnalysisRunState(rawValue: row["state"]),
      let trigger = AnalysisTrigger(rawValue: row["trigger"])
    else { return nil }
    return AnalysisRun(
      id: id, meetingID: meetingID, state: state, trigger: trigger,
      evidenceVersion: row["evidence_version"],
      transcriptPassID: (row["transcript_pass_id"] as String?).flatMap(UUID.init(uuidString:)),
      serverVersion: row["server_version"], protocolVersion: row["protocol_version"],
      schemaVersion: row["schema_version"], backendKind: row["backend_kind"],
      backendModel: row["backend_model"], promptVersions: row["prompt_versions"],
      pipelineVersion: row["pipeline_version"],
      languagePolicy: (row["language_policy"] as String?).flatMap(AnalysisLanguage.init),
      requestConfigJSON: row["request_config_json"], createdAt: row["created_at"],
      startedAt: row["started_at"], completedAt: row["completed_at"],
      failureCategory: (row["failure_category"] as String?).flatMap(
        AnalysisFailureCategory.init),
      failureDetail: row["failure_detail"], chunkCount: row["chunk_count"],
      requestCount: row["request_count"], retryCount: row["retry_count"],
      preemptionCount: row["preemption_count"], inputBytes: row["input_bytes"],
      outputBytes: row["output_bytes"], itemCount: row["item_count"],
      droppedLiteralCount: row["dropped_literal_count"],
      droppedUnsupportedCount: row["dropped_unsupported_count"],
      identityDowngradeCount: row["identity_downgrade_count"],
      unresolvedOwnerCount: row["unresolved_owner_count"], durationMs: row["duration_ms"])
  }
}
