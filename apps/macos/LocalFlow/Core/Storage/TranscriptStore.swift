import Foundation
import GRDB

actor TranscriptStore: TranscriptStoring {
  enum Capacity: Sendable, Equatable { case meetingSegments, meetingBytes, globalBytes }
  enum Error: Swift.Error, Sendable, Equatable {
    case invalidTransition(from: TranscriptState, to: TranscriptState)
    case staleRevision, missingRow, passMismatch, damagedDatabase
    case capacityExceeded(Capacity)
    case invalidSegment(String)
  }
  nonisolated let database: DatabasePool
  init(database: DatabasePool) { self.database = database }
  init(history: TranscriptionStore) { self.database = history.database }
  func transcription(meetingID: UUID) throws -> MeetingTranscription? {
    if let row = try database.read({ try Self.fetch(meetingID, db: $0) }) { return row }
    // A meeting recorded before `transcripts-v6` has no row: the first read
    // inserts `not_requested` for terminal legacy meetings. Active meetings get
    // their row in the preparing transaction, including transcription-off starts.
    return try database.write { db in
      if let row = try Self.fetch(meetingID, db: db) { return row }
      guard
        let updatedAt = try Int64.fetchOne(
          db,
          sql:
            "SELECT updated_at FROM meetings WHERE id=? AND state IN ('completed','interrupted','failed')",
          arguments: [meetingID.uuidString])
      else { return nil }
      try db.execute(
        sql:
          "INSERT INTO meeting_transcriptions(meeting_id,state,live_requested,updated_at) VALUES(?,'not_requested',0,?)",
        arguments: [meetingID.uuidString, updatedAt])
      return try Self.fetch(meetingID, db: db)
    }
  }
  @discardableResult
  func transition(
    meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]
  ) throws -> MeetingTranscription {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      try TranscriptLifecycle.transition(from: row.state, to: to)
      row.state = to
      if to != .live { row.liveState = nil }
      if to != .failed && to != .interrupted {
        row.failureCategory = nil
        row.failureDetail = nil
      }
      for effect in effects {
        switch effect {
        case .setIdentity(let engine, let model, let pipeline, let planner, let vocabulary):
          row.engine = engine
          row.modelID = model.id
          row.modelRevision = model.revision
          row.modelManifestHash = model.manifestHash
          row.pipelineVersion = pipeline
          row.plannerVersion = planner
          row.vocabularyRevision = vocabulary.revision
          row.vocabularyHash = vocabulary.hash
        case .setDescriptor(let descriptor): row.analysisDescriptor = descriptor
        case .setPass(let id, let kind):
          // A new pass starts from zero; only a resumed pass keeps its progress.
          if row.passID != id {
            row.progressSequence = nil
            row.progressSample = nil
          }
          row.passID = id
          row.passKind = kind
        case .setFailure(let category, let detail):
          row.failureCategory = category
          row.failureDetail = detail
        case .clearFailure:
          row.failureCategory = nil
          row.failureDetail = nil
        case .setProgress(let progress):
          row.progressSequence = progress.sequence
          row.progressSample = progress.sample
        case .incrementModelReloads: row.modelReloadCount += 1
        case .setTimestamps(
          let started, let live, let finalizing, let finalized, let recorded, let revision):
          if let revision, revision != row.revision { throw Error.staleRevision }
          if let started { row.startedAt = started }
          if let live { row.liveStartedAt = live }
          if let finalizing { row.finalizationStartedAt = finalizing }
          if let finalized { row.finalizedAt = finalized }
          if let recorded { row.recordedMsAtPass = recorded }
        }
      }
      try Self.save(&row, now: now, db: db)
      return row
    }
  }
  func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) throws {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      guard liveState == nil || row.state == .live else {
        throw Error.invalidTransition(from: row.state, to: .live)
      }
      row.liveState = liveState
      try Self.save(&row, now: now, db: db)
    }
  }
  func updateLiveMetadata(
    meetingID: UUID, descriptor: AnalysisStreamDescriptor,
    incrementModelReloads: Bool, now: Int64
  ) throws -> MeetingTranscription {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      guard row.state == .live else { throw Error.invalidTransition(from: row.state, to: .live) }
      row.analysisDescriptor = descriptor
      if incrementModelReloads { row.modelReloadCount += 1 }
      try Self.save(&row, now: now, db: db)
      return row
    }
  }
  func appendSegments(
    meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft],
    progress: FinalizationProgress?, now: Int64
  ) throws -> Int {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      guard row.passID == passID, row.state == .live || row.state == .finalizing else {
        throw Error.passMismatch
      }
      guard drafts.count <= 50 else { throw Error.invalidSegment("batch_count") }
      for d in drafts {
        guard
          max(d.rawText.utf8.count, d.assembledText.utf8.count, d.normalizedText.utf8.count)
            <= 4096, d.pipelineVersion.utf8.count <= 256
        else { throw Error.invalidSegment("text_bytes") }
      }
      for d in drafts {
        guard d.startMs >= 0, d.endMs > d.startMs, d.endMs <= d.coveredMs, d.stretchSequence >= 1,
          d.windowIndex >= 0
        else { throw Error.invalidSegment("timing") }
      }
      let next =
        try Int.fetchOne(
          db,
          sql:
            "SELECT COALESCE(MAX(ordinal)+1,0) FROM transcript_segments WHERE meeting_id=? AND pass_id=?",
          arguments: [meetingID.uuidString, passID.uuidString]) ?? 0
      var previousStart =
        try Int64.fetchOne(
          db,
          sql:
            "SELECT start_ms FROM transcript_segments WHERE meeting_id=? AND pass_id=? ORDER BY ordinal DESC LIMIT 1",
          arguments: [meetingID.uuidString, passID.uuidString]) ?? 0
      var previousSequence =
        try Int.fetchOne(
          db,
          sql:
            "SELECT stretch_sequence FROM transcript_segments WHERE meeting_id=? AND pass_id=? ORDER BY ordinal DESC LIMIT 1",
          arguments: [meetingID.uuidString, passID.uuidString]) ?? 1
      for (index, d) in drafts.enumerated() {
        guard d.ordinal == next + index, d.startMs >= previousStart,
          d.stretchSequence >= previousSequence
        else { throw Error.invalidSegment("ordinal") }
        guard d.finality == (row.passKind == .live ? .provisional : .final) else {
          throw Error.passMismatch
        }
        previousStart = d.startMs
        previousSequence = d.stretchSequence
      }
      let bytes = Int64(drafts.reduce(0) { $0 + $1.textBytes })
      guard row.segmentCount + drafts.count <= 20_000 else {
        throw Error.capacityExceeded(.meetingSegments)
      }
      guard row.textBytes + bytes <= 16 * 1024 * 1024 else {
        throw Error.capacityExceeded(.meetingBytes)
      }
      let used = try Self.usage(db: db)
      guard used.textBytes + bytes <= 48 * 1024 * 1024 else {
        throw Error.capacityExceeded(.globalBytes)
      }
      for d in drafts {
        try db.execute(
          sql: """
            INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
          arguments: [
            UUID().uuidString, meetingID.uuidString, passID.uuidString, d.finality.rawValue,
            d.ordinal, d.stretchSequence, d.startMs, d.endMs, d.windowIndex, d.timingBasis.rawValue,
            d.rawText, d.assembledText, d.normalizedText, d.engine, d.modelID, d.modelRevision,
            d.pipelineVersion, d.analysisTracks.rawValue, now,
          ])
      }
      row.segmentCount += drafts.count
      row.textBytes += bytes
      if let progress {
        row.progressSequence = progress.sequence
        row.progressSample = progress.sample
      }
      try Self.save(&row, now: now, db: db)
      try db.execute(
        sql:
          "UPDATE transcript_usage SET text_bytes=text_bytes+?,segment_rows=segment_rows+? WHERE id=1",
        arguments: [bytes, drafts.count])
      return drafts.count
    }
  }
  func appendGap(_ gap: LiveGap) throws {
    try database.write { db in
      guard var row = try Self.fetch(gap.meetingID, db: db) else { throw Error.missingRow }
      guard row.passID == gap.passID, row.passKind == .live, row.state == .live else {
        throw Error.passMismatch
      }
      guard gap.startMs >= 0, gap.endMs > gap.startMs else {
        throw Error.invalidSegment("gap_timing")
      }
      let count =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transcript_live_gaps WHERE meeting_id=?",
          arguments: [gap.meetingID.uuidString]) ?? 0
      let adjacent = try String.fetchOne(
        db,
        sql:
          "SELECT id FROM transcript_live_gaps WHERE meeting_id=? AND pass_id=? AND stretch_sequence=? AND reason=? AND end_ms=? ORDER BY rowid DESC LIMIT 1",
        arguments: [
          gap.meetingID.uuidString, gap.passID.uuidString, gap.stretchSequence,
          gap.reason.rawValue, gap.startMs,
        ])
      if let adjacent {
        try db.execute(
          sql: "UPDATE transcript_live_gaps SET end_ms=? WHERE id=?",
          arguments: [gap.endMs, adjacent])
      } else if count >= 10_000 {
        try db.execute(
          sql:
            "UPDATE transcript_live_gaps SET end_ms=MAX(end_ms,?) WHERE id=(SELECT id FROM transcript_live_gaps WHERE meeting_id=? ORDER BY end_ms DESC,rowid DESC LIMIT 1)",
          arguments: [gap.endMs, gap.meetingID.uuidString])
      } else {
        try db.execute(
          sql:
            "INSERT INTO transcript_live_gaps(id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,covered_by_final,created_at) VALUES(?,?,?,?,?,?,?,?,?)",
          arguments: [
            gap.id.uuidString, gap.meetingID.uuidString, gap.passID.uuidString, gap.stretchSequence,
            gap.startMs, gap.endMs, gap.reason.rawValue, gap.coveredByFinal, gap.createdAt,
          ])
      }
      try Self.save(&row, now: gap.createdAt, db: db)
    }
  }
  func completeFinalPass(
    meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64,
    now: Int64
  ) throws -> MeetingTranscription {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      guard row.passID == passID, row.passKind == .final else { throw Error.passMismatch }
      try TranscriptLifecycle.transition(from: row.state, to: .final)
      let maximumEnd =
        try Int64.fetchOne(
          db,
          sql:
            "SELECT MAX(end_ms) FROM transcript_segments WHERE meeting_id=? AND pass_id=?",
          arguments: [meetingID.uuidString, passID.uuidString]) ?? 0
      guard coveredMs >= maximumEnd else { throw Error.invalidSegment("covered_ms") }
      row.replacedProvisionalCount =
        try Int.fetchOne(
          db,
          sql:
            "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id=? AND finality='provisional'",
          arguments: [meetingID.uuidString]) ?? 0
      // Provisional rows and any earlier final pass give way to the completing pass.
      try db.execute(
        sql: "DELETE FROM transcript_segments WHERE meeting_id=? AND pass_id<>?",
        arguments: [meetingID.uuidString, passID.uuidString])
      try db.execute(
        sql:
          "UPDATE transcript_live_gaps SET covered_by_final=1 WHERE meeting_id=? AND end_ms<=?",
        arguments: [meetingID.uuidString, coveredMs])
      try db.execute(
        sql: "DELETE FROM transcript_live_gaps WHERE meeting_id=?",
        arguments: [meetingID.uuidString])
      try Self.recount(&row, db: db)
      row.state = .final
      row.liveState = nil
      row.coveredMs = coveredMs
      row.analysisDescriptor = descriptor
      row.finalizedAt = now
      try Self.save(&row, now: now, db: db)
      return row
    }
  }
  func restartFinalPass(
    meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]
  ) throws -> MeetingTranscription {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      guard row.state == .finalizing else {
        throw Error.invalidTransition(from: row.state, to: .finalizing)
      }
      try db.execute(
        sql: "DELETE FROM transcript_segments WHERE meeting_id=? AND finality='final'",
        arguments: [meetingID.uuidString])
      try Self.recount(&row, db: db)
      row.passID = passID
      row.passKind = .final
      row.progressSequence = nil
      row.progressSample = nil
      row.failureCategory = nil
      row.failureDetail = nil
      for effect in effects {
        switch effect {
        case .setIdentity(let engine, let model, let pipeline, let planner, let vocabulary):
          row.engine = engine
          row.modelID = model.id
          row.modelRevision = model.revision
          row.modelManifestHash = model.manifestHash
          row.pipelineVersion = pipeline
          row.plannerVersion = planner
          row.vocabularyRevision = vocabulary.revision
          row.vocabularyHash = vocabulary.hash
        case .setDescriptor(let descriptor): row.analysisDescriptor = descriptor
        case .setTimestamps(let started, _, let finalizing, _, let recorded, let revision):
          if let revision, revision != row.revision { throw Error.staleRevision }
          if let started { row.startedAt = started }
          if let finalizing { row.finalizationStartedAt = finalizing }
          if let recorded { row.recordedMsAtPass = recorded }
        default: throw Error.invalidSegment("restart_effect")
        }
      }
      try Self.save(&row, now: now, db: db)
      return row
    }
  }
  func passSegmentCount(meetingID: UUID, passID: UUID) throws -> Int {
    try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id=? AND pass_id=?",
        arguments: [meetingID.uuidString, passID.uuidString]) ?? 0
    }
  }
  func discardPass(meetingID: UUID, passID: UUID) throws {
    try database.write { db in
      guard var row = try Self.fetch(meetingID, db: db) else { throw Error.missingRow }
      try db.execute(
        sql: "DELETE FROM transcript_segments WHERE meeting_id=? AND pass_id=?",
        arguments: [meetingID.uuidString, passID.uuidString])
      try Self.recount(&row, db: db)
      try Self.save(&row, now: Int64(Date().timeIntervalSince1970 * 1000), db: db)
    }
  }
  func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int) throws
    -> [TranscriptSegment]
  {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM transcript_segments WHERE meeting_id=? AND finality=? AND ordinal>? ORDER BY ordinal LIMIT ?",
        arguments: [
          meetingID.uuidString, finality.rawValue, ordinal ?? -1, max(0, min(200, limit)),
        ]
      ).map(Self.segment)
    }
  }
  /// The final ordinal of one segment id, for View-source jumps; one index read.
  func ordinal(meetingID: UUID, segmentID: UUID) async throws -> Int? {
    try await database.read { db in
      try Int.fetchOne(
        db,
        sql:
          "SELECT ordinal FROM transcript_segments WHERE meeting_id=? AND id=? AND finality='final'",
        arguments: [meetingID.uuidString, segmentID.uuidString])
    }
  }
  /// One page with each row's effective label (`manual ?? auto`, mapped to the display
  /// root) from the accepted run. Labels apply only to final rows of the pass the run
  /// aligned against, and only while that pass is the transcript's current pass.
  // `async` so concrete calls pick these over the protocol's no-label defaults.
  func labeledPage(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [LabeledSegment]
  {
    try await database.read { db in
      // Feature 010: the effective identity per display root, from the same read.
      let identities = try IdentityStore.identities(meetingID, db: db)
      return try Row.fetchAll(
        db,
        sql: """
          SELECT s.*, r.id AS label_run, r.in_room AS label_in_room, COALESCE(a.manual_kind, a.auto_kind) AS label_kind,
            a.manual_kind IS NOT NULL AS label_edited,
            p.id AS label_root, p.source AS label_source, p.label_ordinal AS label_ordinal,
            p.color_index AS label_color, p.display_name AS label_name
          FROM transcript_segments s
          LEFT JOIN meeting_diarization d ON d.meeting_id=s.meeting_id
          LEFT JOIN diarization_runs r ON r.id=d.accepted_run_id AND s.finality='final'
            AND r.transcript_pass_id=s.pass_id
            AND r.transcript_pass_id=(SELECT pass_id FROM meeting_transcriptions WHERE meeting_id=s.meeting_id)
          LEFT JOIN speaker_assignments a ON a.run_id=r.id AND a.segment_id=s.id
          LEFT JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL
            THEN a.manual_speaker_id ELSE a.auto_speaker_id END
          LEFT JOIN meeting_speakers p ON p.id=COALESCE(e.merged_into, e.id)
          WHERE s.meeting_id=? AND s.finality=? AND s.ordinal>? ORDER BY s.ordinal LIMIT ?
          """,
        arguments: [
          meetingID.uuidString, finality.rawValue, ordinal ?? -1, max(0, min(200, limit)),
        ]
      ).map { row in
        LabeledSegment(
          segment: try Self.segment(row), label: Self.label(row, identities: identities),
          runID: (row["label_run"] as String?).flatMap(UUID.init(uuidString:)))
      }
    }
  }

  func acceptedSpeakers(meetingID: UUID) async throws -> AcceptedSpeakers? {
    try await database.read { db in
      guard
        let accepted = try Row.fetchOne(
          db,
          sql: """
            SELECT r.id, r.in_room FROM meeting_diarization d
            JOIN diarization_runs r ON r.id=d.accepted_run_id
            JOIN meeting_transcriptions t ON t.meeting_id=d.meeting_id AND t.pass_id=r.transcript_pass_id
            WHERE d.meeting_id=?
            """, arguments: [meetingID.uuidString]),
        let runID = UUID(uuidString: accepted["id"])
      else { return nil }
      let inRoom: Bool = accepted["in_room"]
      // The run's clusters plus the meeting's manual "new speaker" rows (run_id NULL).
      let speakers = try Row.fetchAll(
        db,
        sql: """
          SELECT id, source, label_ordinal, color_index, display_name, merged_into
          FROM meeting_speakers WHERE run_id=? OR (run_id IS NULL AND meeting_id=?)
          ORDER BY color_index, run_id IS NULL, label_ordinal LIMIT 512
          """, arguments: [runID.uuidString, meetingID.uuidString]
      ).compactMap { row -> MeetingSpeaker? in
        guard let id = UUID(uuidString: row["id"]),
          let source = SpeakerSource(rawValue: row["source"])
        else { return nil }
        return MeetingSpeaker(
          id: id, source: source, labelOrdinal: row["label_ordinal"],
          colorIndex: row["color_index"], displayName: row["display_name"],
          mergedInto: (row["merged_into"] as String?).flatMap(UUID.init(uuidString:)),
          inRoom: inRoom)
      }
      let count =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(DISTINCT COALESCE(e.merged_into, e.id)) FROM speaker_assignments a
            JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL
              THEN a.manual_speaker_id ELSE a.auto_speaker_id END
            WHERE a.run_id=? AND COALESCE(a.manual_kind, a.auto_kind)='speaker'
            """, arguments: [runID.uuidString]) ?? 0
      return AcceptedSpeakers(runID: runID, speakers: speakers, count: count)
    }
  }

  private static func label(_ row: Row, identities: [UUID: SpeakerIdentity] = [:])
    -> SegmentLabel?
  {
    let edited: Bool = row["label_edited"] ?? false
    switch row["label_kind"] as String? {
    case "unknown":
      return SegmentLabel(
        kind: .unknown, text: SpeakerPalette.unknown, colorIndex: nil, edited: edited)
    case "ambiguous":
      return SegmentLabel(kind: .overlapping, text: SpeakerPalette.overlapping, colorIndex: nil)
    case "speaker":
      guard let root = (row["label_root"] as String?).flatMap(UUID.init(uuidString:)),
        let source = (row["label_source"] as String?).flatMap(SpeakerSource.init(rawValue:)),
        let ordinal = row["label_ordinal"] as Int?
      else { return nil }
      var text = SpeakerPalette.text(
        source: source, ordinal: ordinal, name: row["label_name"],
        inRoom: row["label_in_room"] ?? false)
      // FR-040: "Name" for confirmed and recognized (the name is already the display
      // name), "Name?" for a Possible match, the 007 label otherwise. "You" stays.
      var identity: SegmentIdentity? = source == .remote ? .unknown : nil
      if source == .remote, let effective = identities[root] {
        switch effective.state {
        case .confirmed, .recognized:
          identity = effective.knownSpeakerID == nil ? .unknown : .named
        case .possible:
          if let name = effective.knownSpeakerName, let known = effective.knownSpeakerID {
            identity = .suggested(name: name, knownSpeakerID: known)
            text = "\(name)?"
          }
        case .rejectedUnknown, .unknown: identity = .unknown
        }
      }
      return SegmentLabel(
        kind: .speaker(root: root), text: text, colorIndex: row["label_color"], edited: edited,
        identity: identity)
    default: return nil
    }
  }

  func gaps(meetingID: UUID) throws -> [LiveGap] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM transcript_live_gaps WHERE meeting_id=? ORDER BY start_ms LIMIT 10000",
        arguments: [meetingID.uuidString]
      ).map { r in
        guard let id = UUID(uuidString: r["id"]), let pass = UUID(uuidString: r["pass_id"]),
          let reason = LiveGapReason(rawValue: r["reason"])
        else { throw Error.damagedDatabase }
        return LiveGap(
          id: id, meetingID: meetingID, passID: pass, stretchSequence: r["stretch_sequence"],
          startMs: r["start_ms"], endMs: r["end_ms"], reason: reason,
          coveredByFinal: r["covered_by_final"], createdAt: r["created_at"])
      }
    }
  }
  func activeRows(limit: Int) throws -> [MeetingTranscription] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM meeting_transcriptions WHERE state IN ('pending','live','finalizing') ORDER BY updated_at LIMIT ?",
        arguments: [max(0, min(100, limit))]
      ).map(Self.decode)
    }
  }
  func recover(row expected: MeetingTranscription, to: TranscriptState, outcome: RecoveryOutcome)
    throws
  {
    try database.write { db in
      guard var row = try Self.fetch(expected.meetingID, db: db) else { throw Error.missingRow }
      guard row.revision == expected.revision, row.state == expected.state,
        outcome.meetingID == expected.meetingID
      else { throw Error.staleRevision }
      try TranscriptLifecycle.transition(from: row.state, to: to)
      row.failureDetail = "found=\(row.state.rawValue)"
      row.failureCategory = .finalizationInterrupted
      row.state = to
      row.liveState = nil
      try Self.save(&row, now: outcome.ranAt, db: db)
      try Self.insertOutcome(outcome, db: db)
    }
  }
  func recordOutcome(_ outcome: RecoveryOutcome) throws {
    try database.write { db in
      guard var row = try Self.fetch(outcome.meetingID, db: db) else { throw Error.missingRow }
      try Self.insertOutcome(outcome, db: db)
      try Self.save(&row, now: outcome.ranAt, db: db)
    }
  }
  private static func insertOutcome(_ outcome: RecoveryOutcome, db: Database) throws {
    let summary =
      outcome.summary.hasPrefix("transcript:") ? outcome.summary : "transcript:" + outcome.summary
    guard summary.utf8.count <= 512 else { throw Error.invalidSegment("outcome_bytes") }
    try db.execute(
      sql:
        "INSERT INTO meeting_recovery_outcomes(id,meeting_id,ran_at,found_state,found_stage,segments_recovered,segments_unrecoverable,segments_missing,pause_closed,bytes_truncated,summary) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
      arguments: [
        outcome.id.uuidString, outcome.meetingID.uuidString, outcome.ranAt,
        outcome.foundState.rawValue, outcome.foundStage?.rawValue, outcome.segmentsRecovered,
        outcome.segmentsUnrecoverable, outcome.segmentsMissing, outcome.pauseClosed,
        outcome.bytesTruncated, summary,
      ])
  }
  func usage() throws -> TranscriptUsage { try database.read { try Self.usage(db: $0) } }
  private static func usage(db: Database) throws -> TranscriptUsage {
    guard let r = try Row.fetchOne(db, sql: "SELECT * FROM transcript_usage WHERE id=1") else {
      throw Error.damagedDatabase
    }
    return .init(
      textBytes: r["text_bytes"], segmentRows: r["segment_rows"], schemaVersion: r["schema_version"]
    )
  }
  private static func recount(_ row: inout MeetingTranscription, db: Database) throws {
    let count =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id=?",
        arguments: [row.meetingID.uuidString]) ?? 0
    let bytes =
      try Int64.fetchOne(
        db,
        sql:
          "SELECT COALESCE(SUM(length(CAST(raw_text AS BLOB))+length(CAST(assembled_text AS BLOB))+length(CAST(normalized_text AS BLOB))),0) FROM transcript_segments WHERE meeting_id=?",
        arguments: [row.meetingID.uuidString]) ?? 0
    try db.execute(
      sql:
        "UPDATE transcript_usage SET text_bytes=text_bytes+?,segment_rows=segment_rows+? WHERE id=1",
      arguments: [bytes - row.textBytes, count - row.segmentCount])
    row.segmentCount = count
    row.textBytes = bytes
  }
  private static func fetch(_ id: UUID, db: Database) throws -> MeetingTranscription? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM meeting_transcriptions WHERE meeting_id=?", arguments: [id.uuidString]
    ).map(decode)
  }
  private static func save(_ row: inout MeetingTranscription, now: Int64, db: Database) throws {
    row.updatedAt = now
    row.revision += 1
    let descriptor: String?
    if let value = row.analysisDescriptor {
      let data = try JSONEncoder().encode(value)
      guard data.count <= 16384 else { throw Error.invalidSegment("descriptor_bytes") }
      descriptor = String(decoding: data, as: UTF8.self)
    } else {
      descriptor = nil
    }
    try db.execute(
      sql:
        "UPDATE meeting_transcriptions SET state=?,live_requested=?,live_state=?,pass_id=?,pass_kind=?,engine=?,model_id=?,model_revision=?,model_manifest_hash=?,pipeline_version=?,planner_version=?,vocabulary_revision=?,vocabulary_hash=?,analysis_descriptor_json=?,started_at=?,live_started_at=?,finalization_started_at=?,finalized_at=?,progress_sequence=?,progress_sample=?,covered_ms=?,recorded_ms_at_pass=?,replaced_provisional_count=?,model_reload_count=?,failure_category=?,failure_detail=?,segment_count=?,text_bytes=?,updated_at=?,revision=? WHERE meeting_id=?",
      arguments: [
        row.state.rawValue,
        row.liveRequested,
        row.liveState?.rawValue,
        row.passID?.uuidString,
        row.passKind?.rawValue,
        row.engine,
        row.modelID,
        row.modelRevision,
        row.modelManifestHash,
        row.pipelineVersion,
        row.plannerVersion,
        row.vocabularyRevision,
        row.vocabularyHash,
        descriptor,
        row.startedAt,
        row.liveStartedAt,
        row.finalizationStartedAt,
        row.finalizedAt,
        row.progressSequence,
        row.progressSample,
        row.coveredMs,
        row.recordedMsAtPass,
        row.replacedProvisionalCount,
        row.modelReloadCount,
        row.failureCategory?.rawValue,
        row.failureDetail,
        row.segmentCount,
        row.textBytes,
        row.updatedAt,
        row.revision, row.meetingID.uuidString,
      ])
  }
  private static func decode(_ r: Row) throws -> MeetingTranscription {
    guard let id = UUID(uuidString: r["meeting_id"]),
      let state = TranscriptState(rawValue: r["state"])
    else { throw Error.damagedDatabase }
    var value = MeetingTranscription(
      meetingID: id, state: state, liveRequested: r["live_requested"], updatedAt: r["updated_at"])
    value.liveState = (r["live_state"] as String?).flatMap(LiveState.init(rawValue:))
    value.passID = (r["pass_id"] as String?).flatMap(UUID.init(uuidString:))
    value.passKind = (r["pass_kind"] as String?).flatMap(TranscriptPassKind.init(rawValue:))
    value.engine = r["engine"]
    value.modelID = r["model_id"]
    value.modelRevision = r["model_revision"]
    value.modelManifestHash = r["model_manifest_hash"]
    value.pipelineVersion = r["pipeline_version"]
    value.plannerVersion = r["planner_version"]
    value.vocabularyRevision = r["vocabulary_revision"]
    value.vocabularyHash = r["vocabulary_hash"]
    value.analysisDescriptor = try (r["analysis_descriptor_json"] as String?).map {
      try JSONDecoder().decode(AnalysisStreamDescriptor.self, from: Data($0.utf8))
    }
    value.startedAt = r["started_at"]
    value.liveStartedAt = r["live_started_at"]
    value.finalizationStartedAt = r["finalization_started_at"]
    value.finalizedAt = r["finalized_at"]
    value.progressSequence = r["progress_sequence"]
    value.progressSample = r["progress_sample"]
    value.coveredMs = r["covered_ms"]
    value.recordedMsAtPass = r["recorded_ms_at_pass"]
    value.replacedProvisionalCount = r["replaced_provisional_count"]
    value.modelReloadCount = r["model_reload_count"]
    value.failureCategory = (r["failure_category"] as String?).flatMap(
      TranscriptFailureCategory.init(rawValue:))
    value.failureDetail = r["failure_detail"]
    value.segmentCount = r["segment_count"]
    value.textBytes = r["text_bytes"]
    value.revision = r["revision"]
    return value
  }
  private static func segment(_ r: Row) throws -> TranscriptSegment {
    guard let id = UUID(uuidString: r["id"]), let meeting = UUID(uuidString: r["meeting_id"]),
      let pass = UUID(uuidString: r["pass_id"]),
      let finality = SegmentFinality(rawValue: r["finality"]),
      let timing = TimingBasis(rawValue: r["timing_basis"]),
      let tracks = AnalysisTracks(rawValue: r["analysis_tracks"])
    else { throw Error.damagedDatabase }
    let draft = TranscriptSegmentDraft(
      finality: finality, ordinal: r["ordinal"], stretchSequence: r["stretch_sequence"],
      startMs: r["start_ms"], endMs: r["end_ms"], coveredMs: r["end_ms"],
      windowIndex: r["window_index"], timingBasis: timing, rawText: r["raw_text"],
      assembledText: r["assembled_text"], normalizedText: r["normalized_text"], engine: r["engine"],
      modelID: r["model_id"], modelRevision: r["model_revision"],
      pipelineVersion: r["pipeline_version"], analysisTracks: tracks)
    return TranscriptSegment(
      id: id, meetingID: meeting, passID: pass, draft: draft, createdAt: r["created_at"])
  }
}
