import Foundation
import GRDB

/// Every diarization table write goes through this actor, on the shared history
/// `DatabaseQueue`. Each operation is one transaction except a window batch, which
/// commits its turns 500 at a time. Failure, interruption and preemption delete only
/// the run's own rows; the accepted run changes only inside `complete`.
actor SpeakerStore: SpeakerStoring {
  enum Error: Swift.Error, Equatable, Sendable {
    case missingRow, staleRevision, runInProgress
    case invalidTransition(from: DiarizationRunState, to: DiarizationRunState)
    /// 100,000 turns per run, or the history database ceiling (`persistence_capacity`).
    case capacityExceeded
    case invalidDraft(String)
    /// 10,000 corrections per meeting; the save is refused and nothing is written.
    case correctionCapacity
  }

  static let correctionsPerMeeting = 10_000

  /// Turns are clipped to one window, so no turn is longer than a window. Overlap
  /// lookups use it as the lower bound of their `(run_id, start_ms)` range scan.
  static let maxTurnMs = Int64(
    DiarizationConstants.windowSamples / (DiarizationConstants.sampleRate / 1_000))

  nonisolated let database: DatabaseQueue
  /// FR-037: correction counters, never the names or rows behind them.
  private let recorder: ResourceRecorder?
  init(database: DatabaseQueue, recorder: ResourceRecorder? = nil) {
    self.database = database
    self.recorder = recorder
  }
  init(history: TranscriptionStore, recorder: ResourceRecorder? = nil) {
    self.database = history.database
    self.recorder = recorder
  }

  private func count(_ metric: ResourceRecorder.Metric, _ value: Int) {
    recorder?.record(phase: .idle, metric: metric, itemCount: UInt32(clamping: max(0, value)))
  }

  // MARK: Reads

  func diarization(meetingID: UUID) throws -> MeetingDiarization? {
    try database.read { try Self.fetchDiarization(meetingID, db: $0) }
  }

  func run(id: UUID) throws -> DiarizationRun? {
    try database.read { try Self.fetchRun(id, db: $0) }
  }

  func meetingState(meetingID: UUID) throws -> MeetingDiarizationState {
    try database.read { db in
      guard let row = try Self.fetchDiarization(meetingID, db: db) else { return .notRequested }
      let current = try row.currentRunID.flatMap { try Self.fetchRun($0, db: db) }?.state
      let latest = try String.fetchOne(
        db,
        sql: """
          SELECT state FROM diarization_runs WHERE meeting_id=? AND state<>'superseded'
          ORDER BY created_at DESC, rowid DESC LIMIT 1
          """, arguments: [meetingID.uuidString]
      ).flatMap(DiarizationRunState.init(rawValue:))
      return DiarizationRunLifecycle.meetingState(
        current: current, latest: latest, hasAccepted: row.acceptedRunID != nil)
    }
  }

  func latestRun(meetingID: UUID) throws -> DiarizationRun? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT id FROM diarization_runs WHERE meeting_id=? AND state<>'superseded'
          ORDER BY created_at DESC, rowid DESC LIMIT 1
          """, arguments: [meetingID.uuidString]
      ).flatMap(UUID.init(uuidString:)).flatMap { try Self.fetchRun($0, db: db) }
    }
  }

  func activeRuns(limit: Int) throws -> [DiarizationRun] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT id FROM diarization_runs WHERE state IN ('pending','running')
          ORDER BY created_at, rowid LIMIT ?
          """, arguments: [max(0, limit)]
      ).compactMap { try UUID(uuidString: $0).flatMap { try Self.fetchRun($0, db: db) } }
    }
  }

  /// Turns of one run overlapping `[range)`, in `(start_ms, id)` order, one page at a time.
  func turns(runID: UUID, overlapping range: Range<Int64>, after cursor: TurnCursor?, limit: Int)
    throws -> [SpeakerTurn]
  {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM speaker_turns
          WHERE run_id=? AND start_ms>=? AND start_ms<? AND end_ms>? AND (start_ms, id) > (?, ?)
          ORDER BY start_ms, id LIMIT ?
          """,
        arguments: [
          runID.uuidString, range.lowerBound - Self.maxTurnMs, range.upperBound,
          range.lowerBound, cursor?.startMs ?? Int64.min, cursor?.id ?? Int64.min,
          max(1, min(1_000, limit)),
        ]
      ).map(Self.turn)
    }
  }

  // MARK: Run operations

  func admit(
    meetingID: UUID, transcriptPassID: UUID, trigger: DiarizationTrigger,
    identity: DiarizationIdentity, expectedRevision: Int64?, now: Int64
  ) throws -> DiarizationRun {
    guard identity.manifestHash.utf8.count == 64,
      identity.manifestHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (1...DiarizationPipelineVersion.maxBytes).contains(identity.pipelineVersion.utf8.count)
    else { throw Error.invalidDraft("identity") }
    return try write { db in
      guard let row = try Self.fetchDiarization(meetingID, db: db) else { throw Error.missingRow }
      if let expectedRevision, row.revision != expectedRevision { throw Error.staleRevision }
      guard
        try Bool.fetchOne(
          db,
          sql:
            "SELECT EXISTS(SELECT 1 FROM diarization_runs WHERE meeting_id=? AND state IN ('pending','running'))",
          arguments: [meetingID.uuidString]) == false
      else { throw Error.runInProgress }
      let run = DiarizationRun(
        id: UUID(), meetingID: meetingID, transcriptPassID: transcriptPassID, state: .pending,
        trigger: trigger, inRoom: row.inRoom, identity: identity, createdAt: now)
      try db.execute(
        sql: """
          INSERT INTO diarization_runs (id, meeting_id, transcript_pass_id, state, "trigger", in_room,
            engine, model_id, model_revision, model_manifest_hash, pipeline_version, created_at)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          run.id.uuidString, meetingID.uuidString, transcriptPassID.uuidString,
          run.state.rawValue, trigger.rawValue, row.inRoom, identity.engine, identity.modelID,
          identity.modelRevision, identity.manifestHash, identity.pipelineVersion, now,
        ])
      try Self.touch(meetingID, now: now, db: db, set: "current_run_id=?", run.id.uuidString)
      return run
    }
  }

  func start(runID: UUID, now: Int64) throws -> DiarizationRun {
    try write { db in
      var run = try Self.transition(runID, to: .running, db: db)
      run.state = .running
      run.startedAt = now
      try db.execute(
        sql: "UPDATE diarization_runs SET state='running', started_at=? WHERE id=?",
        arguments: [now, runID.uuidString])
      return run
    }
  }

  /// One window: its new run clusters, then its turns in batches of at most 500.
  func appendWindow(runID: UUID, speakers: [SpeakerDraft], turns: [TurnDraft], audioMs: Int64)
    throws
  {
    guard audioMs >= 0, turns.count <= DiarizationWindowResult.maxTurns else {
      throw Error.invalidDraft("window")
    }
    for turn in turns where turn.startMs < 0 || turn.endMs <= turn.startMs {
      throw Error.invalidDraft("turn")
    }
    for speaker in speakers where speaker.clusterKey < 0 { throw Error.invalidDraft("speaker") }
    let batches = stride(from: 0, to: turns.count, by: DiarizationConstants.writeBatch).map {
      turns[$0..<min($0 + DiarizationConstants.writeBatch, turns.count)]
    }
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: .running)
      }
      guard run.turnCount + turns.count <= DiarizationConstants.turnsPerRun else {
        throw Error.capacityExceeded
      }
      // A turn may name only a cluster of this run.
      let owned = Set(
        try String.fetchAll(
          db, sql: "SELECT id FROM meeting_speakers WHERE run_id=?", arguments: [runID.uuidString])
      ).union(speakers.map(\.id.uuidString))
      for turn in turns {
        if let speaker = turn.speakerID, !owned.contains(speaker.uuidString) {
          throw Error.invalidDraft("turn speaker")
        }
      }
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, track, origin,
            reconciliation) VALUES (?,?,?,?,?,?,'engine',?)
          """)
      for speaker in speakers {
        try insert.execute(arguments: [
          speaker.id.uuidString, run.meetingID.uuidString, runID.uuidString, speaker.clusterKey,
          speaker.track == .microphone ? "local" : "remote", speaker.track.rawValue,
          speaker.reconciliation.rawValue,
        ])
      }
      try db.execute(
        sql: """
          UPDATE diarization_runs SET window_count=window_count+1, audio_ms=audio_ms+?,
            uncertain_reconciliations=uncertain_reconciliations+?, overflow_turns=overflow_turns+?
          WHERE id=?
          """,
        arguments: [
          audioMs, speakers.filter { $0.reconciliation == .uncertain }.count,
          turns.filter { $0.speakerID == nil }.count, runID.uuidString,
        ])
    }
    for batch in batches {
      try write { db in
        let insert = try db.cachedStatement(
          sql: """
            INSERT INTO speaker_turns (run_id, speaker_id, track, start_ms, end_ms, engine_quality)
            VALUES (?,?,?,?,?,?)
            """)
        for turn in batch {
          try insert.execute(arguments: [
            runID.uuidString, turn.speakerID?.uuidString, turn.track.rawValue, turn.startMs,
            turn.endMs, turn.quality.map { Double($0) },
          ])
        }
        try db.execute(
          sql: "UPDATE diarization_runs SET turn_count=turn_count+? WHERE id=?",
          arguments: [batch.count, runID.uuidString])
      }
    }
  }

  /// `MinorClusterFold` decisions, in one write. Targets must be other engine speakers
  /// of the same run; a turn keeps its track and times.
  func fold(runID: UUID, speakers: [UUID: UUID?]) throws {
    guard !speakers.isEmpty else { return }
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: .running)
      }
      let owned = Set(
        try String.fetchAll(
          db, sql: "SELECT id FROM meeting_speakers WHERE run_id=?", arguments: [runID.uuidString]))
      for (source, target) in speakers {
        guard owned.contains(source.uuidString), source != target,
          target.map({ owned.contains($0.uuidString) && speakers[$0] == nil }) ?? true
        else { throw Error.invalidDraft("fold") }
      }
      for (source, target) in speakers.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        try db.execute(
          sql: "UPDATE speaker_turns SET speaker_id=? WHERE run_id=? AND speaker_id=?",
          arguments: [target?.uuidString, runID.uuidString, source.uuidString])
        try db.execute(
          sql: "DELETE FROM meeting_speakers WHERE id=? AND run_id=?",
          arguments: [source.uuidString, runID.uuidString])
      }
    }
  }

  /// Adoption, all or nothing (FR-030): assignments, speaker statistics, colors and
  /// ordinals, overlap flags, supersession of the previous result and the pointers.
  func complete(runID: UUID, assignments: [AssignmentDraft], now: Int64) throws -> DiarizationRun {
    for assignment in assignments {
      guard (assignment.kind == .speaker) == (assignment.speakerID != nil),
        (0...1).contains(assignment.topCoverage), (0...1).contains(assignment.secondCoverage)
      else { throw Error.invalidDraft("assignment") }
    }
    return try write { db in
      var run = try Self.transition(runID, to: .succeeded, db: db)
      let id = runID.uuidString
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO speaker_assignments (run_id, segment_id, auto_kind, auto_speaker_id,
            top_speaker_id, second_speaker_id, top_coverage, second_coverage) VALUES (?,?,?,?,?,?,?,?)
          """)
      for assignment in assignments {
        try insert.execute(arguments: [
          id, assignment.segmentID.uuidString, assignment.kind.rawValue,
          assignment.speakerID?.uuidString, assignment.topSpeakerID?.uuidString,
          assignment.secondSpeakerID?.uuidString, assignment.topCoverage,
          assignment.secondCoverage,
        ])
      }
      try db.execute(
        sql: """
          UPDATE meeting_speakers SET
            first_ms=COALESCE((SELECT MIN(start_ms) FROM speaker_turns WHERE speaker_id=meeting_speakers.id),0),
            speech_ms=COALESCE((SELECT SUM(end_ms-start_ms) FROM speaker_turns WHERE speaker_id=meeting_speakers.id),0),
            engine_quality=(SELECT AVG(engine_quality) FROM speaker_turns WHERE speaker_id=meeting_speakers.id)
          WHERE run_id=?
          """, arguments: [id])
      // FR-017 colors by first-turn order, ties by key; "Speaker N" / "Local N" ordinals
      // by first appearance within each source.
      let speakers = try Row.fetchAll(
        db,
        sql: """
          SELECT s.id, s.source FROM meeting_speakers s
          WHERE s.run_id=? AND EXISTS(SELECT 1 FROM speaker_turns t WHERE t.speaker_id=s.id)
          ORDER BY s.first_ms, s.cluster_key
          """, arguments: [id])
      var ordinals: [String: Int] = [:]
      let label = try db.cachedStatement(
        sql: "UPDATE meeting_speakers SET color_index=?, label_ordinal=? WHERE id=?")
      for (index, speaker) in speakers.enumerated() {
        let source: String = speaker["source"]
        let ordinal = (ordinals[source] ?? 0) + 1
        ordinals[source] = ordinal
        try label.execute(arguments: [index % 8, ordinal, speaker["id"] as String])
      }
      try db.execute(
        sql: """
          UPDATE speaker_turns SET overlapped=EXISTS(
            SELECT 1 FROM speaker_turns o WHERE o.run_id=speaker_turns.run_id AND o.id<>speaker_turns.id
              AND o.start_ms>=speaker_turns.start_ms-? AND o.start_ms<speaker_turns.end_ms
              AND o.end_ms>speaker_turns.start_ms)
          WHERE run_id=?
          """, arguments: [Self.maxTurnMs, id])
      run.inferredSpeakerCount = speakers.count
      run.overlapTurnCount =
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM speaker_turns WHERE run_id=? AND overlapped=1",
          arguments: [id]) ?? 0
      run.unknownCount = assignments.filter { $0.kind == .unknown }.count
      run.ambiguousCount = assignments.filter { $0.kind == .ambiguous }.count
      run.state = .succeeded
      run.completedAt = now
      guard let meeting = try Self.fetchDiarization(run.meetingID, db: db) else {
        throw Error.missingRow
      }
      if let previous = meeting.acceptedRunID {
        // R7: names and corrections follow the clusters they safely map to, before the
        // superseded run's evidence goes.
        try Self.carryOver(from: previous, to: run, db: db, now: now)
        try db.execute(
          sql: "UPDATE diarization_runs SET state='superseded' WHERE id=?",
          arguments: [previous.uuidString])
        try Self.deleteEvidence(previous, speakers: false, db: db)
      }
      try db.execute(
        sql: """
          UPDATE diarization_runs SET state='succeeded', completed_at=?, inferred_speaker_count=?,
            overlap_turn_count=?, unknown_count=?, ambiguous_count=? WHERE id=?
          """,
        arguments: [
          now, run.inferredSpeakerCount, run.overlapTurnCount, run.unknownCount,
          run.ambiguousCount, id,
        ])
      try Self.touch(
        run.meetingID, now: now, db: db,
        set: "accepted_run_id=?, current_run_id=NULLIF(current_run_id, ?)", id, id)
      return run
    }
  }

  func fail(runID: UUID, category: DiarizationFailureCategory, detail: String?, now: Int64)
    throws
  {
    try end(runID, as: .failed, category: category, detail: detail, now: now)
  }

  func interrupt(runID: UUID, now: Int64) throws {
    try end(runID, as: .interrupted, category: .interrupted, detail: nil, now: now)
  }

  /// Preempted by speech recognition: back to pending at no progress. Embeddings are
  /// never persisted, so the run restarts from its first window.
  func requeue(runID: UUID) throws {
    try write { db in
      _ = try Self.transition(runID, to: .pending, db: db)
      try Self.deleteEvidence(runID, speakers: true, db: db)
      try db.execute(
        sql: """
          UPDATE diarization_runs SET state='pending', started_at=NULL, preemption_count=preemption_count+1,
            window_count=0, audio_ms=0, turn_count=0, uncertain_reconciliations=0, overflow_turns=0
          WHERE id=?
          """, arguments: [runID.uuidString])
    }
  }

  /// User Cancel: the run row and everything it owns are removed.
  func cancel(runID: UUID) throws {
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .pending || run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: run.state)
      }
      try Self.touch(
        run.meetingID, now: Int64(Date().timeIntervalSince1970 * 1_000), db: db,
        set: "current_run_id=NULLIF(current_run_id, ?)", runID.uuidString)
      try db.execute(sql: "DELETE FROM diarization_runs WHERE id=?", arguments: [runID.uuidString])
    }
  }

  /// FR-009: the toggle only records the intent; the coordinator admits the rerun.
  func setInRoom(meetingID: UUID, inRoom: Bool, now: Int64) throws {
    try write { db in
      try Self.touch(meetingID, now: now, db: db, set: "in_room=?", inRoom)
    }
  }

  // MARK: Naming (US3) and quotes (US4)

  /// The accepted run's display roots in color order, each with its quotes.
  func speakerSummaries(meetingID: UUID) throws -> [SpeakerSummary] {
    try database.read { db in
      guard let run = try Self.acceptedRun(meetingID, db: db) else { return [] }
      // Engine clusters with speech plus manual speakers (run_id NULL), in color order.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, source, label_ordinal, color_index, display_name, speech_ms, merged_into
          FROM meeting_speakers
          WHERE (run_id=? AND speech_ms>0) OR (run_id IS NULL AND meeting_id=?)
          ORDER BY color_index, run_id IS NULL, first_ms, cluster_key LIMIT 512
          """, arguments: [run.id.uuidString, meetingID.uuidString])
      var summaries: [SpeakerSummary] = []
      var members: [UUID: [MergedSpeaker]] = [:]
      for row in rows {
        guard let id = UUID(uuidString: row["id"]),
          let source = SpeakerSource(rawValue: row["source"])
        else { continue }
        if let target = (row["merged_into"] as String?).flatMap(UUID.init(uuidString:)) {
          members[target, default: []].append(
            .init(id: id, source: source, labelOrdinal: row["label_ordinal"], inRoom: run.inRoom))
          continue
        }
        summaries.append(
          SpeakerSummary(
            id: id, source: source, labelOrdinal: row["label_ordinal"],
            colorIndex: row["color_index"], displayName: row["display_name"],
            inRoom: run.inRoom, speechMs: row["speech_ms"]))
      }
      let candidates = try Self.quoteCandidates(run.id, db: db)
      // Feature 010: the effective identity per root, from the same read.
      let identities = try IdentityStore.identities(meetingID, db: db)
      for index in summaries.indices {
        let id = summaries[index].id
        summaries[index].quotes = QuoteSelector.select(candidates[id] ?? []).map(\.text)
        summaries[index].includes = (members[id] ?? []).sorted {
          ($0.source.rawValue, $0.labelOrdinal) < ($1.source.rawValue, $1.labelOrdinal)
        }
        summaries[index].identity = identities[id]
      }
      return summaries
    }
  }

  /// Save names (FR-022): every changed name and one `rename` correction per change,
  /// in one transaction. A nil or blank name restores the anonymous label.
  func saveNames(meetingID: UUID, names: [UUID: String?], now: Int64) throws {
    var normalized: [UUID: String?] = [:]
    for (id, name) in names {
      guard case .success(let value) = SpeakerNames.validate(name ?? "") else {
        throw Error.invalidDraft("name")
      }
      normalized[id] = value
    }
    let renamed: Int = try write { db in
      guard let run = try Self.acceptedRun(meetingID, db: db) else { throw Error.missingRow }
      var changes: [(UUID, String?, String?)] = []
      for (id, name) in normalized.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let previous = try Self.speaker(id, of: run, db: db)["display_name"] as String?
        if previous != name { changes.append((id, previous, name)) }
      }
      guard !changes.isEmpty else { return 0 }
      try Self.reserveCorrections(changes.count, meetingID: meetingID, db: db)
      for (id, previous, name) in changes {
        try db.execute(
          sql: "UPDATE meeting_speakers SET display_name=? WHERE id=?",
          arguments: [name, id.uuidString])
        try Self.insertCorrection(
          db, meetingID: meetingID, runID: run.id, kind: "rename", speakerID: id,
          previous: previous, new: name, now: now)
      }
      return changes.count
    }
    if renamed > 0 { count(.speakerRenameCount, renamed) }
  }

  // MARK: Merge and segment corrections (US5)

  /// FR-025: `speakerID` and everything merged into it display under `targetID`'s
  /// root, so a chain never exceeds depth 1. One `merge` correction per moved speaker.
  func merge(meetingID: UUID, speakerID: UUID, into targetID: UUID, now: Int64) throws {
    let merged: Int = try write { db in
      guard let run = try Self.acceptedRun(meetingID, db: db) else { throw Error.missingRow }
      let source = try Self.speaker(speakerID, of: run, db: db)
      let target = try Self.speaker(targetID, of: run, db: db)
      let root = (target["merged_into"] as String?) ?? targetID.uuidString
      guard root != speakerID.uuidString else { throw Error.invalidDraft("merge") }
      var moved = [speakerID.uuidString]
      moved += try String.fetchAll(
        db, sql: "SELECT id FROM meeting_speakers WHERE merged_into=? ORDER BY rowid",
        arguments: [speakerID.uuidString])
      // Already under that root, and nothing to move: not a change.
      if (source["merged_into"] as String?) == root, moved.count == 1 { return 0 }
      try Self.reserveCorrections(moved.count, meetingID: meetingID, db: db)
      for id in moved {
        try db.execute(
          sql: "UPDATE meeting_speakers SET merged_into=? WHERE id=?", arguments: [root, id])
        try Self.insertCorrection(
          db, meetingID: meetingID, runID: run.id, kind: "merge",
          speakerID: UUID(uuidString: id), targetID: UUID(uuidString: root), now: now)
      }
      return moved.count
    }
    if merged > 0 { count(.speakerMergeCount, merged) }
  }

  /// FR-025: clears the merge and marks its correction undone. The name and color were
  /// never changed, so nothing is restored.
  func unmerge(meetingID: UUID, speakerID: UUID, now: Int64) throws {
    try write { db in
      guard let run = try Self.acceptedRun(meetingID, db: db) else { throw Error.missingRow }
      let row = try Self.speaker(speakerID, of: run, db: db)
      guard let target = (row["merged_into"] as String?).flatMap(UUID.init(uuidString:)) else {
        throw Error.invalidDraft("unmerge")
      }
      try Self.reserveCorrections(1, meetingID: meetingID, db: db)
      try db.execute(
        sql: "UPDATE meeting_speakers SET merged_into=NULL WHERE id=?",
        arguments: [speakerID.uuidString])
      // Feature 010 (R11): the root's merged resolution goes; both `self` rows apply again.
      try IdentityStore.clearMerged(target, db: db)
      try db.execute(
        sql: """
          UPDATE speaker_corrections SET undone_at=? WHERE id=(
            SELECT id FROM speaker_corrections WHERE meeting_id=? AND kind='merge' AND speaker_id=?
              AND undone_at IS NULL ORDER BY created_at DESC, rowid DESC LIMIT 1)
          """, arguments: [now, meetingID.uuidString, speakerID.uuidString])
      try Self.insertCorrection(
        db, meetingID: meetingID, runID: run.id, kind: "unmerge", speakerID: speakerID,
        targetID: target, now: now)
    }
    count(.speakerUnmergeCount, 1)
  }

  /// FR-026: sets the row's `manual_*` columns (the automatic assignment stays) and
  /// inserts a `segment` correction. A new speaker gets a manual `meeting_speakers`
  /// row with the next remote ordinal and color.
  @discardableResult
  func correctSegment(
    meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection, now: Int64
  )
    throws -> UUID?
  {
    let speaker: UUID? = try write { db in
      guard let run = try Self.acceptedRun(meetingID, db: db) else { throw Error.missingRow }
      guard
        let assignment = try Row.fetchOne(
          db,
          sql: """
            SELECT a.auto_kind, a.auto_speaker_id, a.manual_kind, a.manual_speaker_id, s.start_ms
            FROM speaker_assignments a JOIN transcript_segments s ON s.id=a.segment_id
            WHERE a.run_id=? AND a.segment_id=?
            """, arguments: [run.id.uuidString, segmentID.uuidString])
      else { throw Error.missingRow }
      try Self.reserveCorrections(1, meetingID: meetingID, db: db)
      let speaker: UUID?
      switch correction {
      case .speaker(let id):
        _ = try Self.speaker(id, of: run, db: db)
        speaker = id
      case .unknown:
        speaker = nil
      case .newSpeaker:
        let id = UUID()
        // Next remote ordinal and color after the run's clusters and earlier manual rows.
        let next = try Row.fetchOne(
          db,
          sql: """
            SELECT COALESCE(MAX(CASE WHEN source='remote' THEN label_ordinal END),0)+1 AS ordinal,
              COUNT(*) AS colors, SUM(run_id IS NULL) AS manual
            FROM meeting_speakers WHERE run_id=? OR (run_id IS NULL AND meeting_id=?)
            """, arguments: [run.id.uuidString, meetingID.uuidString])
        let ordinal: Int = next?["ordinal"] ?? 1
        let colors: Int = next?["colors"] ?? 0
        let manual: Int = next?["manual"] ?? 0
        try db.execute(
          sql: """
            INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, track, origin,
              label_ordinal, color_index, first_ms)
            VALUES (?,?,NULL,?,'remote',NULL,'manual',?,?,?)
            """,
          arguments: [
            id.uuidString, meetingID.uuidString, manual, ordinal, colors % 8,
            assignment["start_ms"] as Int64,
          ])
        speaker = id
      }
      // The correction records what the row showed before it: the effective label.
      let manualKind: String? = assignment["manual_kind"]
      let previousKind: String = manualKind ?? assignment["auto_kind"]
      let previousSpeaker: String? =
        manualKind == nil ? assignment["auto_speaker_id"] : assignment["manual_speaker_id"]
      try db.execute(
        sql: """
          UPDATE speaker_assignments SET manual_kind=?, manual_speaker_id=?, manual_at=?
          WHERE run_id=? AND segment_id=?
          """,
        arguments: [
          speaker == nil ? "unknown" : "speaker", speaker?.uuidString, now, run.id.uuidString,
          segmentID.uuidString,
        ])
      try Self.insertCorrection(
        db, meetingID: meetingID, runID: run.id, kind: "segment",
        speakerID: previousSpeaker.flatMap(UUID.init(uuidString:)), targetID: speaker,
        segmentID: segmentID, previous: previousKind == "speaker" ? nil : previousKind,
        new: speaker == nil ? "unknown" : nil, now: now)
      return speaker
    }
    count(.speakerSegmentCorrectionCount, 1)
    return speaker
  }

  // MARK: Carry-over (R7)

  private struct CarriedSpeaker {
    let id: UUID
    let track: MeetingTrackKind?
    let source: SpeakerSource
    let ordinal: Int
    let name: String?
    let mergedInto: UUID?
    let speechMs: Int64
    /// The name, or the anonymous label, for a review notice; cut to the column's 80.
    func label(inRoom: Bool) -> String {
      let text = SpeakerPalette.text(source: source, ordinal: ordinal, name: name, inRoom: inRoom)
      return String(String.UnicodeScalarView(text.unicodeScalars.prefix(SpeakerNames.maxLength)))
    }
  }

  private static func carriedSpeakers(runID: UUID?, meetingID: UUID, db: Database) throws
    -> [CarriedSpeaker]
  {
    try Row.fetchAll(
      db,
      sql: """
        SELECT id, track, source, label_ordinal, display_name, merged_into, speech_ms
        FROM meeting_speakers
        WHERE CASE WHEN ? IS NULL THEN run_id IS NULL AND meeting_id=? ELSE run_id=? END
        ORDER BY id
        """, arguments: [runID?.uuidString, meetingID.uuidString, runID?.uuidString]
    ).compactMap { row in
      guard let id = UUID(uuidString: row["id"]),
        let source = SpeakerSource(rawValue: row["source"])
      else { return nil }
      return CarriedSpeaker(
        id: id, track: (row["track"] as String?).flatMap(MeetingTrackKind.init(rawValue:)),
        source: source, ordinal: row["label_ordinal"], name: row["display_name"],
        mergedInto: (row["merged_into"] as String?).flatMap(UUID.init(uuidString:)),
        speechMs: row["speech_ms"])
    }
  }

  /// Old speaker → new speaker from a streamed sweep of both runs' turns in pages of
  /// 1,000, then the R7 effects. What does not map becomes a `needs_review` row.
  private static func carryOver(
    from previousID: UUID, to run: DiarizationRun, db: Database, now: Int64
  ) throws {
    guard let previous = try fetchRun(previousID, db: db) else { throw Error.missingRow }
    let old = try carriedSpeakers(runID: previousID, meetingID: run.meetingID, db: db)
    let new = try carriedSpeakers(runID: run.id, meetingID: run.meetingID, db: db)
    let manualRows = try carriedSpeakers(runID: nil, meetingID: run.meetingID, db: db)
    let manual = Set(manualRows.map(\.id))
    var sweep = CorrectionCarryOver.OverlapSweep()
    var cursor: TurnCursor?
    while true {
      let page = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM speaker_turns WHERE run_id=? AND speaker_id IS NOT NULL
            AND (start_ms, id) > (?, ?) ORDER BY start_ms, id LIMIT ?
          """,
        arguments: [
          previousID.uuidString, cursor?.startMs ?? Int64.min, cursor?.id ?? Int64.min,
          CorrectionCarryOver.page,
        ]
      ).map(turn)
      guard let first = page.first, let last = page.last else { break }
      let span = first.startMs..<max(page.map(\.endMs).max() ?? first.endMs, first.startMs + 1)
      var newCursor: TurnCursor?
      while true {
        let batch = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM speaker_turns
            WHERE run_id=? AND speaker_id IS NOT NULL AND start_ms>=? AND start_ms<? AND end_ms>?
              AND (start_ms, id) > (?, ?)
            ORDER BY start_ms, id LIMIT ?
            """,
          arguments: [
            run.id.uuidString, span.lowerBound - maxTurnMs, span.upperBound, span.lowerBound,
            newCursor?.startMs ?? Int64.min, newCursor?.id ?? Int64.min, CorrectionCarryOver.page,
          ]
        ).map(turn)
        sweep.add(old: page.compactMap(carried), new: batch.compactMap(carried))
        guard batch.count == CorrectionCarryOver.page, let tail = batch.last else { break }
        newCursor = TurnCursor(startMs: tail.startMs, id: tail.id)
      }
      guard page.count == CorrectionCarryOver.page else { break }
      cursor = TurnCursor(startMs: last.startMs, id: last.id)
    }
    let mapping = CorrectionCarryOver.map(
      old: old.compactMap { speaker in
        speaker.track.map { .init(id: speaker.id, track: $0, speechMs: speaker.speechMs) }
      },
      new: new.compactMap { speaker in speaker.track.map { .init(id: speaker.id, track: $0) } },
      sweep: sweep)
    // Manual speakers survive as themselves; engine speakers through the mapping.
    func target(_ id: UUID) -> UUID? { manual.contains(id) ? id : mapping[id] }
    let inRoom = previous.inRoom
    // Names.
    for speaker in old where speaker.name != nil {
      if let mapped = mapping[speaker.id] {
        try db.execute(
          sql: "UPDATE meeting_speakers SET display_name=? WHERE id=? AND display_name IS NULL",
          arguments: [speaker.name, mapped.uuidString])
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "rename", speakerID: mapped,
          new: speaker.name, now: now)
      } else {
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "rename", speakerID: speaker.id,
          new: speaker.name, review: true, now: now)
      }
    }
    // Merges: both members must map, to different new clusters. A manual speaker maps
    // to itself, so its merge follows its engine partner's mapping.
    let byID = Dictionary(uniqueKeysWithValues: (old + manualRows).map { ($0.id, $0) })
    for speaker in old + manualRows {
      guard let root = speaker.mergedInto else { continue }
      // Two manual rows stay merged as they are.
      if manual.contains(speaker.id), manual.contains(root) { continue }
      let rootLabel = byID[root]?.label(inRoom: inRoom) ?? ""
      if let member = target(speaker.id), let into = target(root), member != into {
        try db.execute(
          sql: "UPDATE meeting_speakers SET merged_into=? WHERE id=?",
          arguments: [into.uuidString, member.uuidString])
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "merge", speakerID: member,
          targetID: into, now: now)
      } else {
        if manual.contains(speaker.id) {
          // Its old root is gone with the superseded run; the row stands on its own.
          try db.execute(
            sql: "UPDATE meeting_speakers SET merged_into=NULL WHERE id=?",
            arguments: [speaker.id.uuidString])
        }
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "merge", speakerID: speaker.id,
          targetID: root, previous: rootLabel, new: speaker.label(inRoom: inRoom), review: true,
          now: now)
      }
    }
    // Feature 010 (R7): manual identity rows and rejected pairs follow the same map;
    // automatic rows go with the superseded clusters and the next run recomputes them.
    try IdentityStore.carryManualIdentities(
      old: old.map(\.id), mapping: mapping, meetingID: run.meetingID, runID: run.id,
      namedOld: Set(old.filter { $0.name != nil }.map(\.id)), now: now, db: db)
    // Segment corrections: same pass, and a target that is Unknown, manual or mapped.
    let corrections = try Row.fetchAll(
      db,
      sql: """
        SELECT segment_id, manual_kind, manual_speaker_id FROM speaker_assignments
        WHERE run_id=? AND manual_kind IS NOT NULL ORDER BY segment_id
        """, arguments: [previousID.uuidString])
    for correction in corrections {
      guard let segment = UUID(uuidString: correction["segment_id"]) else { continue }
      let kind: String = correction["manual_kind"]
      let speaker = (correction["manual_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      let into = speaker.flatMap(target)
      let samePass = previous.transcriptPassID == run.transcriptPassID
      if samePass, kind == "unknown" || into != nil {
        try db.execute(
          sql: """
            UPDATE speaker_assignments SET manual_kind=?, manual_speaker_id=?, manual_at=?
            WHERE run_id=? AND segment_id=?
            """, arguments: [kind, into?.uuidString, now, run.id.uuidString, segment.uuidString])
        guard db.changesCount == 1 else { continue }
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "segment", speakerID: nil,
          targetID: into, segmentID: segment, new: into == nil ? "unknown" : nil, now: now)
      } else {
        let label = speaker.flatMap { byID[$0]?.label(inRoom: inRoom) } ?? SpeakerPalette.unknown
        try insertCorrection(
          db, meetingID: run.meetingID, runID: run.id, kind: "segment", speakerID: speaker,
          segmentID: segment, new: label, review: true, now: now)
      }
    }
  }

  private static func carried(_ turn: SpeakerTurn) -> CorrectionCarryOver.Turn? {
    turn.speakerID.map {
      .init(speaker: $0, track: turn.track, startMs: turn.startMs, endMs: turn.endMs)
    }
  }

  /// R7: "Couldn't carry over" entries, oldest first, until dismissed.
  func reviewNotices(meetingID: UUID) throws -> [ReviewNotice] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, new_value FROM speaker_corrections
          WHERE meeting_id=? AND needs_review=1 ORDER BY created_at, rowid LIMIT 256
          """, arguments: [meetingID.uuidString]
      ).compactMap { row in
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return ReviewNotice(id: id, name: row["new_value"] ?? "")
      }
    }
  }

  func dismissReview(id: UUID) throws {
    try write { db in
      try db.execute(
        sql: "UPDATE speaker_corrections SET needs_review=0 WHERE id=?", arguments: [id.uuidString]
      )
    }
  }

  /// A speaker of the accepted run, or a manual speaker of the meeting.
  private static func speaker(_ id: UUID, of run: DiarizationRun, db: Database) throws -> Row {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM meeting_speakers
          WHERE id=? AND (run_id=? OR (run_id IS NULL AND meeting_id=?))
          """, arguments: [id.uuidString, run.id.uuidString, run.meetingID.uuidString])
    else { throw Error.missingRow }
    return row
  }

  /// The 10,000-correction ceiling: refused before anything is written.
  static func reserveCorrections(_ count: Int, meetingID: UUID, db: Database) throws {
    let existing =
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM speaker_corrections WHERE meeting_id=?",
        arguments: [meetingID.uuidString]) ?? 0
    guard existing + count <= correctionsPerMeeting else { throw Error.correctionCapacity }
  }

  static func insertCorrection(
    _ db: Database, meetingID: UUID, runID: UUID, kind: String, speakerID: UUID?,
    targetID: UUID? = nil, segmentID: UUID? = nil, previous: String? = nil, new: String? = nil,
    review: Bool = false, now: Int64
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, speaker_id, target_speaker_id,
          segment_id, previous_value, new_value, needs_review, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        UUID().uuidString, meetingID.uuidString, runID.uuidString, kind, speakerID?.uuidString,
        targetID?.uuidString, segmentID?.uuidString, previous, new, review, now,
      ])
  }

  /// FR-028: distinct stored names starting with `prefix`, most recently used first.
  /// Plain text only; nothing is matched or applied.
  func nameSuggestions(prefix: String, limit: Int) throws -> [String] {
    let pattern =
      prefix.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_") + "%"
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.display_name FROM meeting_speakers s
          LEFT JOIN speaker_corrections c ON c.speaker_id=s.id AND c.kind='rename'
          WHERE s.display_name LIKE ? ESCAPE '\\'
          GROUP BY s.display_name ORDER BY MAX(COALESCE(c.created_at, 0)) DESC, s.display_name
          LIMIT ?
          """, arguments: [pattern, max(0, min(8, limit))])
    }
  }

  /// Research R9: up to 10 of the longest segments per third of the meeting whose
  /// effective label is the display root, ties by ordinal. Thirds split the final pass
  /// from 0 to its last segment end.
  private static func quoteCandidates(_ runID: UUID, db: Database) throws
    -> [UUID: [QuoteSelector.Candidate]]
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH effective AS (
          SELECT t.ordinal, t.start_ms, t.normalized_text AS text,
            COALESCE(e.merged_into, e.id) AS root
          FROM speaker_assignments a
          JOIN transcript_segments t ON t.id=a.segment_id
          JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL
            THEN a.manual_speaker_id ELSE a.auto_speaker_id END
          WHERE a.run_id=? AND COALESCE(a.manual_kind, a.auto_kind)='speaker'
        ), span AS (
          SELECT MAX(1, MAX(t.end_ms)) AS total FROM transcript_segments t
          JOIN diarization_runs r ON r.id=? AND t.pass_id=r.transcript_pass_id
        ), ranked AS (
          SELECT root, ordinal, text, MIN(2, start_ms * 3 / span.total) AS third
          FROM effective, span
        ), numbered AS (
          SELECT *, ROW_NUMBER() OVER (
            PARTITION BY root, third ORDER BY length(text) DESC, ordinal) AS rank
          FROM ranked
        )
        SELECT root, ordinal, third, text FROM numbered WHERE rank<=10
        ORDER BY root, third, rank
        """, arguments: [runID.uuidString, runID.uuidString])
    var candidates: [UUID: [QuoteSelector.Candidate]] = [:]
    for row in rows {
      guard let root = UUID(uuidString: row["root"]) else { continue }
      candidates[root, default: []].append(
        .init(ordinal: row["ordinal"], third: row["third"], text: row["text"]))
    }
    return candidates
  }

  static func acceptedRun(_ meetingID: UUID, db: Database) throws -> DiarizationRun? {
    try fetchDiarization(meetingID, db: db)?.acceptedRunID.flatMap { try fetchRun($0, db: db) }
  }

  // MARK: Helpers

  private func end(
    _ runID: UUID, as state: DiarizationRunState, category: DiarizationFailureCategory,
    detail: String?, now: Int64
  ) throws {
    // Content-free by contract; an over-long detail is dropped, never truncated mid-scalar.
    let detail = detail.flatMap { $0.utf8.count <= 512 ? $0 : nil }
    try write { db in
      let run = try Self.transition(runID, to: state, db: db)
      try Self.deleteEvidence(runID, speakers: true, db: db)
      try db.execute(
        sql: """
          UPDATE diarization_runs SET state=?, failure_category=?, failure_detail=?, completed_at=?
          WHERE id=?
          """,
        arguments: [state.rawValue, category.rawValue, detail, now, runID.uuidString])
      try Self.touch(
        run.meetingID, now: now, db: db, set: "current_run_id=NULLIF(current_run_id, ?)",
        runID.uuidString)
    }
  }

  /// SQLITE_FULL at the history ceiling is a capacity refusal, not a generic failure.
  private func write<T>(_ body: (Database) throws -> T) throws -> T {
    do {
      return try database.write(body)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
      throw Error.capacityExceeded
    }
  }

  private static func transition(_ id: UUID, to state: DiarizationRunState, db: Database) throws
    -> DiarizationRun
  {
    guard let run = try fetchRun(id, db: db) else { throw Error.missingRow }
    do {
      try DiarizationRunLifecycle.transition(from: run.state, to: state)
    } catch { throw Error.invalidTransition(from: run.state, to: state) }
    return run
  }

  /// Assignments before turns before speakers: assignments point at speakers.
  private static func deleteEvidence(_ runID: UUID, speakers: Bool, db: Database) throws {
    let id = runID.uuidString
    try db.execute(sql: "DELETE FROM speaker_assignments WHERE run_id=?", arguments: [id])
    try db.execute(sql: "DELETE FROM speaker_turns WHERE run_id=?", arguments: [id])
    if speakers {
      try db.execute(sql: "DELETE FROM meeting_speakers WHERE run_id=?", arguments: [id])
    }
  }

  private static func touch(
    _ meetingID: UUID, now: Int64, db: Database, set assignment: String,
    _ values: any DatabaseValueConvertible...
  ) throws {
    try db.execute(
      sql:
        "UPDATE meeting_diarization SET \(assignment), updated_at=?, revision=revision+1 WHERE meeting_id=?",
      arguments: StatementArguments(
        values + [now as any DatabaseValueConvertible, meetingID.uuidString]))
    guard db.changesCount == 1 else { throw Error.missingRow }
  }

  static func fetchDiarization(_ meetingID: UUID, db: Database) throws -> MeetingDiarization? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM meeting_diarization WHERE meeting_id=?",
      arguments: [meetingID.uuidString]
    ).map { row in
      MeetingDiarization(
        meetingID: meetingID,
        acceptedRunID: (row["accepted_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        currentRunID: (row["current_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        inRoom: row["in_room"], updatedAt: row["updated_at"], revision: row["revision"])
    }
  }

  static func fetchRun(_ id: UUID, db: Database) throws -> DiarizationRun? {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM diarization_runs WHERE id=?", arguments: [id.uuidString]),
      let meetingID = UUID(uuidString: row["meeting_id"]),
      let passID = UUID(uuidString: row["transcript_pass_id"]),
      let state = DiarizationRunState(rawValue: row["state"]),
      let trigger = DiarizationTrigger(rawValue: row["trigger"])
    else { return nil }
    var run = DiarizationRun(
      id: id, meetingID: meetingID, transcriptPassID: passID, state: state, trigger: trigger,
      inRoom: row["in_room"],
      identity: .init(
        engine: row["engine"], modelID: row["model_id"], modelRevision: row["model_revision"],
        manifestHash: row["model_manifest_hash"], pipelineVersion: row["pipeline_version"]),
      createdAt: row["created_at"])
    run.startedAt = row["started_at"]
    run.completedAt = row["completed_at"]
    run.failureCategory = (row["failure_category"] as String?)
      .flatMap(DiarizationFailureCategory.init(rawValue:))
    run.failureDetail = row["failure_detail"]
    run.inferredSpeakerCount = row["inferred_speaker_count"]
    run.audioMs = row["audio_ms"]
    run.windowCount = row["window_count"]
    run.turnCount = row["turn_count"]
    run.overlapTurnCount = row["overlap_turn_count"]
    run.unknownCount = row["unknown_count"]
    run.ambiguousCount = row["ambiguous_count"]
    run.uncertainReconciliations = row["uncertain_reconciliations"]
    run.overflowTurns = row["overflow_turns"]
    run.preemptionCount = row["preemption_count"]
    return run
  }

  static func turn(_ row: Row) -> SpeakerTurn {
    SpeakerTurn(
      id: row["id"], runID: UUID(uuidString: row["run_id"]) ?? UUID(),
      speakerID: (row["speaker_id"] as String?).flatMap(UUID.init(uuidString:)),
      track: MeetingTrackKind(rawValue: row["track"]) ?? .system,
      startMs: row["start_ms"], endMs: row["end_ms"], engineQuality: row["engine_quality"],
      overlapped: row["overlapped"])
  }
}
