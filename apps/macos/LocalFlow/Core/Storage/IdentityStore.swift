import Foundation
import GRDB

/// Every identity table write goes through this actor, on the shared history
/// `DatabasePool` (Feature 010, data-model.md). Each operation is one transaction.
/// Adoption replaces only `automatic_match` rows; failure, interruption and preemption
/// delete only the run's own candidate rows; deletion of a known speaker leaves the
/// copied names behind and zero rows referencing it.
actor IdentityStore: IdentityStoring {
  enum Capacity: Sendable, Equatable { case knownSpeakers, rejectedCandidates, candidates }

  enum Error: Swift.Error, Equatable, Sendable {
    case missingRow, revisionMismatch, rejectedSource, runInProgress, localUserExists
    case invalidTransition(from: IdentificationRunState, to: IdentificationRunState)
    case invalidDraft(String)
    case capacity(Capacity)
    /// The history database ceiling (SQLITE_FULL).
    case persistenceCapacity
  }

  static let knownSpeakerCapacity = 1_000
  static let rejectedPerMeeting = 1_000
  static let candidatesPerRun = 64_000
  static let renameBatch = 500
  /// Shortest turn the selector can use: the minimum region plus both trims.
  static let eligibleTurnMs = VoiceRegionSelector.minDurationMs + 2 * VoiceRegionSelector.trimMs

  nonisolated let database: DatabasePool
  /// The model the app embeds with; profile state and compatibility derive from it.
  let identity: VoiceModelIdentity
  /// FR-037: confirmation and correction counters, never the names behind them.
  private let recorder: ResourceRecorder?

  init(database: DatabasePool, identity: VoiceModelIdentity, recorder: ResourceRecorder? = nil) {
    self.database = database
    self.identity = identity
    self.recorder = recorder
  }

  init(history: TranscriptionStore, identity: VoiceModelIdentity, recorder: ResourceRecorder? = nil)
  {
    self.database = history.database
    self.identity = identity
    self.recorder = recorder
  }

  private func count(_ metric: ResourceRecorder.Metric, _ value: Int) {
    recorder?.record(phase: .idle, metric: metric, itemCount: UInt32(clamping: max(0, value)))
  }

  // MARK: Known speakers (FR-042)

  func knownSpeakers() throws -> [KnownSpeakerRow] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT k.*, (SELECT count(*) FROM voice_samples v WHERE v.known_speaker_id=k.id AND v.active=1
            AND v.engine=? AND v.model_id=? AND v.model_revision=? AND v.dimension=?) AS active_samples
          FROM known_speakers k ORDER BY k.display_name, k.created_at, k.id
          """,
        arguments: [identity.engine, identity.modelID, identity.modelRevision, identity.dimension]
      ).compactMap(Self.knownSpeaker)
    }
  }

  func createKnownSpeaker(name: String, isLocalUser: Bool, now: Int64) throws -> KnownSpeakerRow {
    guard case .success(let validated) = SpeakerNames.validate(name), let display = validated else {
      throw Error.invalidDraft("name")
    }
    return try write { db in
      let existing = try Int.fetchOne(db, sql: "SELECT count(*) FROM known_speakers") ?? 0
      guard existing < Self.knownSpeakerCapacity else { throw Error.capacity(.knownSpeakers) }
      if isLocalUser,
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM known_speakers WHERE is_local_user=1)") == true
      {
        throw Error.localUserExists
      }
      let id = UUID()
      try db.execute(
        sql: """
          INSERT INTO known_speakers (id, display_name, is_local_user, recognition_enabled, created_at,
            updated_at, revision) VALUES (?,?,?,1,?,?,0)
          """, arguments: [id.uuidString, display, isLocalUser, now, now])
      return KnownSpeakerRow(
        id: id, name: display, activeSampleCount: 0, recognitionEnabled: true,
        state: .needsReenrollment, isLocalUser: isLocalUser, revision: 0, createdAt: now)
    }
  }

  /// One transaction: the profile plus the `confirmed` identity row of the root, so a
  /// failed extraction leaves "0 samples" and a linked name (US1 scenario 3).
  func enroll(
    meetingID: UUID, speakerID: UUID?, name: String, isLocalUser: Bool, origin: IdentityOrigin,
    now: Int64
  ) throws -> KnownSpeakerRow {
    guard case .success(let validated) = SpeakerNames.validate(name), let display = validated else {
      throw Error.invalidDraft("name")
    }
    let allowed: Set<IdentityOrigin> = [
      .userConfirmation, .manualProfileSelection, .newProfileCreated, .manualCorrection,
    ]
    guard speakerID == nil || allowed.contains(origin) else { throw Error.invalidDraft("origin") }
    return try write { db in
      let existing = try Int.fetchOne(db, sql: "SELECT count(*) FROM known_speakers") ?? 0
      guard existing < Self.knownSpeakerCapacity else { throw Error.capacity(.knownSpeakers) }
      if isLocalUser,
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM known_speakers WHERE is_local_user=1)") == true
      {
        throw Error.localUserExists
      }
      let id = UUID()
      try db.execute(
        sql: """
          INSERT INTO known_speakers (id, display_name, is_local_user, recognition_enabled, created_at,
            updated_at, revision) VALUES (?,?,?,1,?,?,0)
          """, arguments: [id.uuidString, display, isLocalUser, now, now])
      if let speakerID {
        try Self.upsertManual(
          meetingID: meetingID, speakerID: speakerID, scope: "self", state: .confirmed,
          origin: origin, knownSpeakerID: id, confirmedAt: now, correctedAt: nil, now: now, db: db)
        try Self.copyName(display, to: speakerID, meetingID: meetingID, now: now, db: db)
      }
      return KnownSpeakerRow(
        id: id, name: display, activeSampleCount: 0, recognitionEnabled: true,
        state: .needsReenrollment, isLocalUser: isLocalUser, revision: 0, createdAt: now)
    }
  }

  /// Research R9: the profile and, in the same transaction, `display_name` of every
  /// meeting speaker linked to it with state `confirmed` or `recognized`, 500 at a time.
  func rename(knownSpeakerID: UUID, to name: String, expectedRevision: Int64, now: Int64) throws {
    guard case .success(let validated) = SpeakerNames.validate(name), let display = validated else {
      throw Error.invalidDraft("name")
    }
    try write { db in
      try Self.bump(knownSpeakerID, expected: expectedRevision, now: now, db: db)
      try db.execute(
        sql: "UPDATE known_speakers SET display_name=? WHERE id=?",
        arguments: [display, knownSpeakerID.uuidString])
      var offset = 0
      while true {
        let batch = try String.fetchAll(
          db,
          sql: """
            SELECT meeting_speaker_id FROM identity_assignments
            WHERE known_speaker_id=? AND state IN ('confirmed','recognized')
            ORDER BY meeting_speaker_id LIMIT ? OFFSET ?
            """, arguments: [knownSpeakerID.uuidString, Self.renameBatch, offset])
        guard !batch.isEmpty else { break }
        let update = try db.cachedStatement(
          sql: "UPDATE meeting_speakers SET display_name=? WHERE id=?")
        for speaker in batch { try update.execute(arguments: [display, speaker]) }
        guard batch.count == Self.renameBatch else { break }
        offset += Self.renameBatch
      }
    }
  }

  func setRecognition(knownSpeakerID: UUID, enabled: Bool, expectedRevision: Int64, now: Int64)
    throws
  {
    try write { db in
      try Self.bump(knownSpeakerID, expected: expectedRevision, now: now, db: db)
      try db.execute(
        sql: "UPDATE known_speakers SET recognition_enabled=? WHERE id=?",
        arguments: [enabled, knownSpeakerID.uuidString])
    }
  }

  /// Research R9 (FR-030, FR-033): names stay as meeting metadata; every row that
  /// references the speaker goes; nothing in transcript, turn or audio tables is touched.
  func deleteKnownSpeaker(id: UUID, expectedRevision: Int64) throws {
    try write { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT display_name, revision FROM known_speakers WHERE id=?",
          arguments: [id.uuidString])
      else { throw Error.missingRow }
      guard (row["revision"] as Int64) == expectedRevision else { throw Error.revisionMismatch }
      let name: String = row["display_name"]
      // Idempotent: linked speakers already carry the name; a missing copy is filled.
      try db.execute(
        sql: """
          UPDATE meeting_speakers SET display_name=? WHERE display_name IS NULL AND id IN (
            SELECT meeting_speaker_id FROM identity_assignments
            WHERE known_speaker_id=? AND state IN ('confirmed','recognized'))
          """, arguments: [name, id.uuidString])
      for table in [
        "identity_assignments", "rejected_candidates", "match_candidates", "voice_samples",
      ] {
        try db.execute(
          sql: "DELETE FROM \(table) WHERE known_speaker_id=?", arguments: [id.uuidString])
      }
      try db.execute(
        sql:
          "UPDATE identity_assignments SET second_known_speaker_id=NULL WHERE second_known_speaker_id=?",
        arguments: [id.uuidString])
      try db.execute(sql: "DELETE FROM known_speakers WHERE id=?", arguments: [id.uuidString])
    }
  }

  // MARK: Samples (FR-005 to FR-008, FR-043)

  func samples(knownSpeakerID: UUID) throws -> [VoiceSampleRow] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT v.id, v.speech_ms, v.quality_label, v.created_at, v.source_meeting_id,
            m.title, m.started_at, m.created_at AS meeting_created
          FROM voice_samples v LEFT JOIN meetings m ON m.id=v.source_meeting_id
          WHERE v.known_speaker_id=? AND v.active=1 ORDER BY v.created_at DESC, v.id LIMIT 64
          """, arguments: [knownSpeakerID.uuidString]
      ).compactMap { row in
        guard let id = UUID(uuidString: row["id"]),
          let label = VoiceQualityLabel(rawValue: row["quality_label"])
        else { return nil }
        let created: Int64 = row["created_at"]
        let unavailable = (row["source_meeting_id"] as String?) == nil
        let meetingDate: Int64? =
          (row["started_at"] as Int64?) ?? (row["meeting_created"] as Int64?)
        return VoiceSampleRow(
          id: id, sourceTitle: unavailable ? nil : row["title"],
          sourceDate: unavailable ? created : (meetingDate ?? created),
          provenanceUnavailable: unavailable, speechMs: row["speech_ms"], qualityLabel: label,
          createdAt: created)
      }
    }
  }

  func removeSample(id: UUID, now: Int64) throws {
    try write { db in
      try db.execute(sql: "DELETE FROM voice_samples WHERE id=?", arguments: [id.uuidString])
      guard db.changesCount == 1 else { throw Error.missingRow }
    }
  }

  /// One row per region, then the cap and retirement (R5) for the model identity, all
  /// in one transaction. Refuses a source cluster the speaker was rejected for (FR-007).
  func addSamples(
    knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent, now: Int64
  ) throws -> Int {
    for draft in drafts {
      guard draft.identity.isValid, draft.vector.count == draft.identity.dimension,
        draft.vector.allSatisfy(\.isFinite), draft.speechMs > 0, draft.startMs >= 0,
        draft.endMs > draft.startMs, (0...1).contains(draft.qualityScore),
        (1...IdentificationPipelineVersion.maxBytes).contains(draft.pipelineVersion.utf8.count)
      else { throw Error.invalidDraft("sample") }
    }
    guard !drafts.isEmpty else { return 0 }
    return try write { db in
      guard
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM known_speakers WHERE id=?)",
          arguments: [knownSpeakerID.uuidString]) == true
      else { throw Error.missingRow }
      for source in Set(drafts.map(\.sourceSpeakerID)) {
        if try Bool.fetchOne(
          db,
          sql:
            "SELECT EXISTS(SELECT 1 FROM rejected_candidates WHERE meeting_speaker_id=? AND known_speaker_id=?)",
          arguments: [source.uuidString, knownSpeakerID.uuidString]) == true
        {
          throw Error.rejectedSource
        }
      }
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO voice_samples (id, known_speaker_id, engine, model_id, model_revision,
            model_manifest_hash, dimension, pipeline_version, vector, quality_label, quality_score,
            engine_quality, speech_ms, track, start_ms, end_ms, source_meeting_id, source_speaker_id,
            consent, active, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?)
          """)
      for draft in drafts {
        try insert.execute(arguments: [
          UUID().uuidString, knownSpeakerID.uuidString, draft.identity.engine,
          draft.identity.modelID, draft.identity.modelRevision, draft.identity.manifestHash,
          draft.identity.dimension, draft.pipelineVersion, VectorCodec.encode(draft.vector),
          draft.qualityLabel.rawValue, draft.qualityScore, draft.engineQuality, draft.speechMs,
          draft.track.rawValue, draft.startMs, draft.endMs, draft.sourceMeetingID.uuidString,
          draft.sourceSpeakerID.uuidString, consent.rawValue, now,
        ])
      }
      for model in Set(drafts.map(\.identity)) {
        try Self.applyCap(knownSpeakerID, model: model, now: now, db: db)
      }
      try db.execute(
        sql: "UPDATE known_speakers SET updated_at=?, revision=revision+1 WHERE id=?",
        arguments: [now, knownSpeakerID.uuidString])
      return drafts.count
    }
  }

  /// `retire_qd_v1` over the active rows of one model identity; retired rows beyond the
  /// retained count go, oldest first.
  private static func applyCap(
    _ knownSpeakerID: UUID, model: VoiceModelIdentity, now: Int64, db: Database
  ) throws {
    let filter =
      "known_speaker_id=? AND engine=? AND model_id=? AND model_revision=? AND dimension=?"
    let arguments: StatementArguments = [
      knownSpeakerID.uuidString, model.engine, model.modelID, model.modelRevision, model.dimension,
    ]
    let active = try Row.fetchAll(
      db, sql: "SELECT id, vector, quality_score FROM voice_samples WHERE \(filter) AND active=1",
      arguments: arguments
    ).compactMap { row -> SampleRetirementPolicy.Entry? in
      guard let id = UUID(uuidString: row["id"]),
        let vector = VectorCodec.decode(row["vector"], dimension: model.dimension)
      else { return nil }
      return .init(id: id, vector: vector, qualityScore: row["quality_score"])
    }
    let outcome = SampleRetirementPolicy.retire(active: active, incoming: [])
    let retire = try db.cachedStatement(
      sql: "UPDATE voice_samples SET active=0, retired_at=? WHERE id=?")
    for id in outcome.retire { try retire.execute(arguments: [now, id.uuidString]) }
    try db.execute(
      sql: """
        DELETE FROM voice_samples WHERE id IN (
          SELECT id FROM voice_samples WHERE \(filter) AND active=0
          ORDER BY retired_at DESC, id DESC LIMIT -1 OFFSET ?)
        """, arguments: arguments + [SampleRetirementPolicy.retainedRetired])
  }

  /// Recognition-enabled profiles (the local user included, as evidence) with at least
  /// one active sample compatible with `identity`.
  func profiles(compatibleWith identity: VoiceModelIdentity) throws -> [CandidateProfile] {
    try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT v.known_speaker_id, v.vector, k.is_local_user FROM voice_samples v
          JOIN known_speakers k ON k.id=v.known_speaker_id
          WHERE v.active=1 AND k.recognition_enabled=1 AND v.engine=? AND v.model_id=?
            AND v.model_revision=? AND v.dimension=?
          ORDER BY v.known_speaker_id, v.created_at, v.id
          LIMIT ?
          """,
        arguments: [
          identity.engine, identity.modelID, identity.modelRevision, identity.dimension,
          Self.knownSpeakerCapacity * SampleRetirementPolicy.cap,
        ])
      var profiles: [CandidateProfile] = []
      for row in rows {
        guard let id = UUID(uuidString: row["known_speaker_id"]),
          let vector = VectorCodec.decode(row["vector"], dimension: identity.dimension)
        else { continue }
        if let index = profiles.lastIndex(where: { $0.id == id }) {
          profiles[index] = CandidateProfile(
            id: id, samples: profiles[index].samples + [vector],
            isLocalUser: profiles[index].isLocalUser)
        } else {
          profiles.append(
            CandidateProfile(id: id, samples: [vector], isLocalUser: row["is_local_user"]))
        }
      }
      return profiles
    }
  }

  // MARK: Runs (FR-022 to FR-025)

  func identification(meetingID: UUID) throws -> MeetingIdentification? {
    try database.read { try Self.fetchIdentification(meetingID, db: $0) }
  }

  func run(id: UUID) throws -> IdentificationRun? {
    try database.read { try Self.fetchRun(id, db: $0) }
  }

  /// A `pending` run against the meeting's accepted diarization run.
  func admit(
    meetingID: UUID, trigger: IdentificationTrigger, identity: VoiceModelIdentity, policy: String,
    now: Int64
  ) throws -> IdentificationRun {
    guard identity.isValid, (1...128).contains(policy.utf8.count) else {
      throw Error.invalidDraft("identity")
    }
    let pipeline = IdentificationPipelineVersion.current
    return try write { db in
      guard try Self.fetchIdentification(meetingID, db: db) != nil else { throw Error.missingRow }
      guard let diarization = try SpeakerStore.acceptedRun(meetingID, db: db) else {
        throw Error.missingRow
      }
      guard
        try Bool.fetchOne(
          db,
          sql:
            "SELECT EXISTS(SELECT 1 FROM identification_runs WHERE meeting_id=? AND state IN ('pending','running'))",
          arguments: [meetingID.uuidString]) == false
      else { throw Error.runInProgress }
      let run = IdentificationRun(
        id: UUID(), meetingID: meetingID, diarizationRunID: diarization.id, state: .pending,
        trigger: trigger, identity: identity, pipelineVersion: pipeline, thresholdPolicy: policy,
        createdAt: now)
      try db.execute(
        sql: """
          INSERT INTO identification_runs (id, meeting_id, diarization_run_id, state, "trigger", engine,
            model_id, model_revision, model_manifest_hash, dimension, pipeline_version, threshold_policy,
            created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          run.id.uuidString, meetingID.uuidString, diarization.id.uuidString, run.state.rawValue,
          trigger.rawValue, identity.engine, identity.modelID, identity.modelRevision,
          identity.manifestHash, identity.dimension, pipeline, policy, now,
        ])
      try Self.touch(meetingID, now: now, db: db, set: "current_run_id=?", run.id.uuidString)
      return run
    }
  }

  func start(runID: UUID, now: Int64) throws -> IdentificationRun {
    try write { db in
      var run = try Self.transition(runID, to: .running, db: db)
      run.state = .running
      run.startedAt = now
      try db.execute(
        sql: "UPDATE identification_runs SET state='running', started_at=? WHERE id=?",
        arguments: [now, runID.uuidString])
      return run
    }
  }

  /// Region counts of a running run, for the run row and the status line.
  func recordRegions(runID: UUID, extracted: Int, rejected: Int) throws {
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: .running)
      }
      try db.execute(
        sql: "UPDATE identification_runs SET region_count=?, rejected_region_count=? WHERE id=?",
        arguments: [max(0, extracted), max(0, rejected), runID.uuidString])
    }
  }

  /// R13: at most 64,000 candidate rows per run, refused before anything is written.
  func appendCandidates(runID: UUID, rows: [MatchCandidateDraft]) throws {
    for row in rows {
      guard (-1...1).contains(row.score), row.score.isFinite, row.sampleCount >= 0,
        row.supportCount >= 0
      else { throw Error.invalidDraft("candidate") }
    }
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: .running)
      }
      guard run.candidateCount + rows.count <= Self.candidatesPerRun else {
        throw Error.capacity(.candidates)
      }
      let insert = try db.cachedStatement(
        sql: """
          INSERT OR REPLACE INTO match_candidates (run_id, meeting_speaker_id, known_speaker_id, score,
            tier, reasons, sample_count, support_count) VALUES (?,?,?,?,?,?,?,?)
          """)
      for row in rows {
        try insert.execute(arguments: [
          runID.uuidString, row.meetingSpeakerID.uuidString, row.knownSpeakerID.uuidString,
          Double(row.score), row.tier.rawValue, row.reasons.map(\.rawValue).joined(separator: ","),
          row.sampleCount, row.supportCount,
        ])
      }
      try db.execute(
        sql:
          "UPDATE identification_runs SET candidate_count=candidate_count+?, comparison_count=comparison_count+? WHERE id=?",
        arguments: [rows.count, rows.count, runID.uuidString])
    }
  }

  /// Adoption, all or nothing (R7): one `self` row per decided root unless a manual row
  /// exists, the previous run's automatic rows and candidates gone, pointers swapped.
  func complete(runID: UUID, decisions: [UUID: IdentityMatcher.Decision], now: Int64) throws
    -> IdentificationRun
  {
    try write { db in
      var run = try Self.transition(runID, to: .succeeded, db: db)
      let id = runID.uuidString
      let rejected = try Self.rejectedCandidates(run.meetingID, db: db)
      var preserved = 0
      for (speakerID, decision) in decisions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let manual = try String.fetchOne(
          db,
          sql:
            "SELECT origin FROM identity_assignments WHERE meeting_speaker_id=? AND scope='self'",
          arguments: [speakerID.uuidString]
        ).flatMap(IdentityOrigin.init(rawValue:))?.isManual
        if manual == true {
          preserved += 1
          continue
        }
        // FR-020: a rejected pair is never re-suggested, whatever the matcher said.
        var best = decision.state == .unknown ? nil : decision.best
        if let candidate = best, rejected[speakerID]?.contains(candidate.knownSpeakerID) == true {
          best = nil
        }
        let state = best == nil ? IdentityState.unknown : decision.state
        try db.execute(
          sql: """
            INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id,
              state, origin, run_id, score, engine, model_id, model_revision, threshold_policy,
              second_known_speaker_id, created_at, updated_at)
            VALUES (?,?,?,'self',?,?,'automatic_match',?,?,?,?,?,?,?,?,?)
            ON CONFLICT(meeting_speaker_id, scope) DO UPDATE SET known_speaker_id=excluded.known_speaker_id,
              state=excluded.state, origin=excluded.origin, run_id=excluded.run_id, score=excluded.score,
              engine=excluded.engine, model_id=excluded.model_id, model_revision=excluded.model_revision,
              threshold_policy=excluded.threshold_policy, second_known_speaker_id=excluded.second_known_speaker_id,
              confirmed_at=NULL, corrected_at=NULL, updated_at=excluded.updated_at
            """,
          arguments: [
            UUID().uuidString, run.meetingID.uuidString, speakerID.uuidString,
            best?.knownSpeakerID.uuidString, state.rawValue, id, best.map { Double($0.score) },
            best == nil ? nil : run.identity.engine, best == nil ? nil : run.identity.modelID,
            best == nil ? nil : run.identity.modelRevision, best == nil ? nil : run.thresholdPolicy,
            decision.second?.knownSpeakerID.uuidString, now, now,
          ])
        switch state {
        case .recognized:
          run.recognizedCount += 1
          // FR-040: a Recognized root shows the known speaker's name; a name the user
          // typed earlier is meeting metadata and stays.
          if let known = best?.knownSpeakerID,
            let name = try String.fetchOne(
              db, sql: "SELECT display_name FROM known_speakers WHERE id=?",
              arguments: [known.uuidString])
          {
            try Self.copyName(
              name, to: speakerID, meetingID: run.meetingID, now: now, onlyIfEmpty: true, db: db)
          }
        case .possible: run.suggestedCount += 1
        default: run.unknownCount += 1
        }
      }
      // Automatic rows of earlier runs for roots this run did not decide.
      try db.execute(
        sql: """
          DELETE FROM identity_assignments WHERE meeting_id=? AND scope='self'
            AND origin='automatic_match' AND (run_id IS NULL OR run_id<>?)
          """, arguments: [run.meetingID.uuidString, id])
      guard let meeting = try Self.fetchIdentification(run.meetingID, db: db) else {
        throw Error.missingRow
      }
      if let previous = meeting.acceptedRunID, previous != runID {
        try db.execute(
          sql: "UPDATE identification_runs SET state='superseded' WHERE id=? AND state='succeeded'",
          arguments: [previous.uuidString])
        try db.execute(
          sql: "DELETE FROM match_candidates WHERE run_id=?", arguments: [previous.uuidString])
      }
      run.state = .succeeded
      run.completedAt = now
      run.clusterCount = decisions.count
      run.preservedManualCount = preserved
      try db.execute(
        sql: """
          UPDATE identification_runs SET state='succeeded', completed_at=?, cluster_count=?,
            recognized_count=?, suggested_count=?, unknown_count=?, preserved_manual_count=? WHERE id=?
          """,
        arguments: [
          now, run.clusterCount, run.recognizedCount, run.suggestedCount, run.unknownCount,
          preserved, id,
        ])
      try Self.touch(
        run.meetingID, now: now, db: db,
        set: "accepted_run_id=?, current_run_id=NULLIF(current_run_id, ?)", id, id)
      return run
    }
  }

  func fail(runID: UUID, category: IdentificationFailureCategory, detail: String?, now: Int64)
    throws
  {
    try end(runID, as: .failed, category: category, detail: detail, now: now)
  }

  func interrupt(runID: UUID, now: Int64) throws {
    try end(runID, as: .interrupted, category: .interrupted, detail: nil, now: now)
  }

  /// Preempted by a speech workload: back to pending with no progress.
  func requeue(runID: UUID) throws {
    try write { db in
      _ = try Self.transition(runID, to: .pending, db: db)
      try db.execute(
        sql: "DELETE FROM match_candidates WHERE run_id=?", arguments: [runID.uuidString])
      try db.execute(
        sql: """
          UPDATE identification_runs SET state='pending', started_at=NULL,
            preemption_count=preemption_count+1, candidate_count=0, comparison_count=0,
            region_count=0, rejected_region_count=0 WHERE id=?
          """, arguments: [runID.uuidString])
    }
  }

  /// User Cancel or meeting deletion: the row and its candidates are removed.
  func cancel(runID: UUID) throws {
    try write { db in
      guard let run = try Self.fetchRun(runID, db: db) else { throw Error.missingRow }
      guard run.state == .pending || run.state == .running else {
        throw Error.invalidTransition(from: run.state, to: run.state)
      }
      try Self.touch(
        run.meetingID, now: Int64(Date().timeIntervalSince1970 * 1_000), db: db,
        set: "current_run_id=NULLIF(current_run_id, ?)", runID.uuidString)
      try db.execute(
        sql: "DELETE FROM identification_runs WHERE id=?", arguments: [runID.uuidString])
    }
  }

  func activeRuns(limit: Int) throws -> [IdentificationRun] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT id FROM identification_runs WHERE state IN ('pending','running')
          ORDER BY created_at, rowid LIMIT ?
          """, arguments: [max(0, limit)]
      ).compactMap { try UUID(uuidString: $0).flatMap { try Self.fetchRun($0, db: db) } }
    }
  }

  func latestRun(meetingID: UUID) throws -> IdentificationRun? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT id FROM identification_runs WHERE meeting_id=? AND state<>'superseded'
          ORDER BY created_at DESC, rowid DESC LIMIT 1
          """, arguments: [meetingID.uuidString]
      ).flatMap(UUID.init(uuidString:)).flatMap { try Self.fetchRun($0, db: db) }
    }
  }

  func meetingState(meetingID: UUID) throws -> MeetingIdentificationState {
    try database.read { db in
      guard let row = try Self.fetchIdentification(meetingID, db: db) else { return .notRequested }
      let current = try row.currentRunID.flatMap { try Self.fetchRun($0, db: db) }?.state
      let latest = try String.fetchOne(
        db,
        sql: """
          SELECT state FROM identification_runs WHERE meeting_id=? AND state<>'superseded'
          ORDER BY created_at DESC, rowid DESC LIMIT 1
          """, arguments: [meetingID.uuidString]
      ).flatMap(IdentificationRunState.init(rawValue:))
      return IdentificationRunLifecycle.meetingState(
        current: current, latest: latest, hasAccepted: row.acceptedRunID != nil)
    }
  }

  /// R10: meetings with an accepted diarization run and a remote display root whose
  /// effective identity is `unknown` or absent, newest first.
  func meetingsWithUnknownRemoteSpeakers(limit: Int) throws -> [UUID] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT m.id FROM meetings m
          JOIN meeting_diarization d ON d.meeting_id=m.id AND d.accepted_run_id IS NOT NULL
          WHERE EXISTS (
            SELECT 1 FROM meeting_speakers s WHERE s.run_id=d.accepted_run_id AND s.source='remote'
              AND s.speech_ms>0 AND s.merged_into IS NULL
              AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id
                AND a.scope='merged' AND a.known_speaker_id IS NOT NULL)
              AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id
                AND a.scope='self' AND a.state IN ('recognized','possible','confirmed','rejected_unknown')))
          ORDER BY m.created_at DESC, m.id DESC LIMIT ?
          """, arguments: [max(0, min(Self.pastSearchLimit, limit))]
      ).compactMap(UUID.init(uuidString:))
    }
  }
  static let pastSearchLimit = 500

  // MARK: Assignments (US1, US3, US4, US7)

  /// FR-020: the rejected known speakers per cluster of the meeting.
  func rejectedCandidates(meetingID: UUID) throws -> [UUID: Set<UUID>] {
    try database.read { try Self.rejectedCandidates(meetingID, db: $0) }
  }

  private static func rejectedCandidates(_ meetingID: UUID, db: Database) throws
    -> [UUID: Set<UUID>]
  {
    var result: [UUID: Set<UUID>] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT r.meeting_speaker_id, r.known_speaker_id FROM rejected_candidates r
        JOIN meeting_speakers s ON s.id=r.meeting_speaker_id WHERE s.meeting_id=?
        """, arguments: [meetingID.uuidString])
    {
      guard let speaker = UUID(uuidString: row["meeting_speaker_id"]),
        let known = UUID(uuidString: row["known_speaker_id"])
      else { continue }
      result[speaker, default: []].insert(known)
    }
    return result
  }

  func identities(meetingID: UUID) throws -> [UUID: SpeakerIdentity] {
    try database.read { try Self.identities(meetingID, db: $0) }
  }

  /// Per display root of the accepted diarization run, through `MergedIdentityRule`.
  static func identities(_ meetingID: UUID, db: Database) throws -> [UUID: SpeakerIdentity] {
    guard let run = try SpeakerStore.acceptedRun(meetingID, db: db) else { return [:] }
    let speakers = try Row.fetchAll(
      db,
      sql: """
        SELECT id, merged_into FROM meeting_speakers
        WHERE (run_id=? AND speech_ms>0) OR (run_id IS NULL AND meeting_id=?)
        """, arguments: [run.id.uuidString, meetingID.uuidString])
    var members: [UUID: [UUID]] = [:]
    var roots: [UUID] = []
    for speaker in speakers {
      guard let id = UUID(uuidString: speaker["id"]) else { continue }
      if let target = (speaker["merged_into"] as String?).flatMap(UUID.init(uuidString:)) {
        members[target, default: []].append(id)
      } else {
        roots.append(id)
      }
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT a.meeting_speaker_id, a.scope, a.state, a.origin, a.known_speaker_id,
          a.second_known_speaker_id, k.display_name AS known_name, s.display_name AS second_name
        FROM identity_assignments a
        LEFT JOIN known_speakers k ON k.id=a.known_speaker_id
        LEFT JOIN known_speakers s ON s.id=a.second_known_speaker_id
        WHERE a.meeting_id=?
        """, arguments: [meetingID.uuidString])
    var selfRows: [UUID: (MergedIdentityRule.IdentityRow, String?, IdentityCandidateRef?)] = [:]
    var mergedRows: [UUID: (MergedIdentityRule.IdentityRow, String?)] = [:]
    for row in rows {
      guard let speaker = UUID(uuidString: row["meeting_speaker_id"]),
        let state = IdentityState(rawValue: row["state"]),
        let origin = IdentityOrigin(rawValue: row["origin"])
      else { continue }
      let known = (row["known_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      let secondID = (row["second_known_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      let second = secondID.flatMap { id in
        (row["second_name"] as String?).map { IdentityCandidateRef(id: id, name: $0) }
      }
      let identity = MergedIdentityRule.IdentityRow(
        state: state, origin: origin, knownSpeakerID: known, secondKnownSpeakerID: secondID)
      if (row["scope"] as String) == "merged" {
        mergedRows[speaker] = (identity, row["known_name"])
      } else {
        selfRows[speaker] = (identity, row["known_name"], second)
      }
    }
    var result: [UUID: SpeakerIdentity] = [:]
    for root in roots {
      let own = selfRows[root]
      let effective = MergedIdentityRule.effective(
        root: own?.0, members: (members[root] ?? []).map { selfRows[$0]?.0 },
        resolution: mergedRows[root]?.0)
      var identity = SpeakerIdentity.unknown
      if let row = effective.row {
        identity.state = row.state
        identity.origin = row.origin
        identity.knownSpeakerID = row.knownSpeakerID
        if row.knownSpeakerID != nil {
          if mergedRows[root]?.0 == row {
            identity.knownSpeakerName = mergedRows[root]?.1
          } else if own?.0 == row {
            identity.knownSpeakerName = own?.1
          } else if let member = (members[root] ?? []).first(where: { selfRows[$0]?.0 == row }) {
            identity.knownSpeakerName = selfRows[member]?.1
          }
        }
        if row.state == .possible { identity.secondCandidate = own?.2 }
      }
      identity.needsChoice = effective.needsChoice
      identity.sampleOfferAvailable = try hasEligibleRegion(
        root: root, members: members[root] ?? [], runID: run.id, db: db)
      result[root] = identity
    }
    return result
  }

  /// The selector's turn rules in SQL: a non-overlapped turn long enough after trimming
  /// whose engine quality (when present) clears the floor.
  private static func hasEligibleRegion(root: UUID, members: [UUID], runID: UUID, db: Database)
    throws -> Bool
  {
    let ids = ([root] + members).map(\.uuidString)
    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
    var arguments: [any DatabaseValueConvertible] = [runID.uuidString]
    arguments += ids
    arguments += [Self.eligibleTurnMs, VoiceRegionSelector.minEngineQuality]
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM speaker_turns WHERE run_id=? AND speaker_id IN (\(placeholders))
          AND overlapped=0 AND end_ms-start_ms>=? AND (engine_quality IS NULL OR engine_quality>=?))
        """, arguments: StatementArguments(arguments)) ?? false
  }

  /// A manual link: `confirmed` with the given origin. A correction records the previous
  /// candidate as rejected. The known speaker's name is copied into `display_name`.
  func link(
    meetingID: UUID, speakerID: UUID, to knownSpeakerID: UUID, origin: IdentityOrigin, now: Int64
  )
    throws
  {
    let allowed: Set<IdentityOrigin> = [
      .userConfirmation, .manualProfileSelection, .newProfileCreated, .manualCorrection,
    ]
    guard allowed.contains(origin) else { throw Error.invalidDraft("origin") }
    try write { db in
      guard
        let name = try String.fetchOne(
          db, sql: "SELECT display_name FROM known_speakers WHERE id=?",
          arguments: [knownSpeakerID.uuidString])
      else { throw Error.missingRow }
      let previous = try Row.fetchOne(
        db,
        sql:
          "SELECT known_speaker_id, state FROM identity_assignments WHERE meeting_speaker_id=? AND scope='self'",
        arguments: [speakerID.uuidString])
      let previousKnown = (previous?["known_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      var corrected: Int64?
      if origin == .manualCorrection, let previousKnown, previousKnown != knownSpeakerID {
        try Self.insertRejection(
          meetingID: meetingID, speakerID: speakerID, candidate: previousKnown, now: now, db: db)
        corrected = now
      }
      try Self.upsertManual(
        meetingID: meetingID, speakerID: speakerID, scope: "self", state: .confirmed,
        origin: origin,
        knownSpeakerID: knownSpeakerID, confirmedAt: now, correctedAt: corrected, now: now, db: db)
      try Self.copyName(name, to: speakerID, meetingID: meetingID, now: now, db: db)
    }
    switch origin {
    case .userConfirmation: count(.identificationConfirmations, 1)
    case .manualCorrection: count(.identificationCorrections, 1)
    default: break
    }
  }

  /// Keep Unknown or a correction away from a candidate: the pair is remembered for
  /// this cluster (FR-020), and with `keepUnknown` the row becomes `rejected_unknown`.
  func reject(
    meetingID: UUID, speakerID: UUID, candidate knownSpeakerID: UUID, keepUnknown: Bool, now: Int64
  )
    throws
  {
    try write { db in
      try Self.insertRejection(
        meetingID: meetingID, speakerID: speakerID, candidate: knownSpeakerID, now: now, db: db)
      if keepUnknown {
        try Self.upsertManual(
          meetingID: meetingID, speakerID: speakerID, scope: "self", state: .rejectedUnknown,
          origin: .keptUnknown, knownSpeakerID: nil, confirmedAt: nil, correctedAt: nil, now: now,
          db: db)
      }
    }
    if keepUnknown { count(.identificationCorrections, 1) }
  }

  /// R11: the `merged` row on a display root with a conflict.
  func resolveMerged(meetingID: UUID, rootID: UUID, to resolution: MergedResolution, now: Int64)
    throws
  {
    try write { db in
      switch resolution {
      case .knownSpeaker(let known):
        guard
          let name = try String.fetchOne(
            db, sql: "SELECT display_name FROM known_speakers WHERE id=?",
            arguments: [known.uuidString])
        else { throw Error.missingRow }
        try Self.upsertManual(
          meetingID: meetingID, speakerID: rootID, scope: "merged", state: .confirmed,
          origin: .manualProfileSelection, knownSpeakerID: known, confirmedAt: now,
          correctedAt: nil,
          now: now, db: db)
        try Self.copyName(name, to: rootID, meetingID: meetingID, now: now, db: db)
      case .keepUnknown:
        try Self.upsertManual(
          meetingID: meetingID, speakerID: rootID, scope: "merged", state: .rejectedUnknown,
          origin: .keptUnknown, knownSpeakerID: nil, confirmedAt: nil, correctedAt: nil, now: now,
          db: db)
      }
    }
  }

  func clearMergedResolution(meetingID: UUID, rootID: UUID) throws {
    try write { db in try Self.clearMerged(rootID, db: db) }
  }

  /// Called inside the diarization store's adoption transaction (R7): a manual `self`
  /// row of an old cluster moves to the new cluster it safely maps to, with the
  /// cluster's rejected pairs; one that cannot be carried becomes a review notice
  /// unless its name already raised one. Automatic rows are never carried.
  static func carryManualIdentities(
    old: [UUID], mapping: [UUID: UUID], meetingID: UUID, runID: UUID, namedOld: Set<UUID>,
    now: Int64, db: Database
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT a.meeting_speaker_id, k.display_name FROM identity_assignments a
        LEFT JOIN known_speakers k ON k.id=a.known_speaker_id
        WHERE a.meeting_id=? AND a.scope='self' AND a.origin<>'automatic_match'
        """, arguments: [meetingID.uuidString])
    let oldSet = Set(old)
    for row in rows {
      guard let speaker = UUID(uuidString: row["meeting_speaker_id"]), oldSet.contains(speaker)
      else { continue }
      if let mapped = mapping[speaker] {
        try db.execute(
          sql: """
            UPDATE identity_assignments SET meeting_speaker_id=?, updated_at=?
            WHERE meeting_speaker_id=? AND scope='self' AND NOT EXISTS (
              SELECT 1 FROM identity_assignments WHERE meeting_speaker_id=? AND scope='self')
            """, arguments: [mapped.uuidString, now, speaker.uuidString, mapped.uuidString])
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO rejected_candidates (meeting_speaker_id, known_speaker_id, rejected_at)
            SELECT ?, known_speaker_id, rejected_at FROM rejected_candidates WHERE meeting_speaker_id=?
            """, arguments: [mapped.uuidString, speaker.uuidString])
      } else if !namedOld.contains(speaker) {
        let name: String? = row["display_name"]
        let label = String(
          String.UnicodeScalarView(
            (name ?? SpeakerPalette.unknown).unicodeScalars.prefix(SpeakerNames.maxLength)))
        try SpeakerStore.insertCorrection(
          db, meetingID: meetingID, runID: runID, kind: "rename", speakerID: speaker, new: label,
          review: true, now: now)
      }
    }
  }

  /// Called inside the diarization store's unmerge transaction.
  static func clearMerged(_ rootID: UUID, db: Database) throws {
    try db.execute(
      sql: "DELETE FROM identity_assignments WHERE meeting_speaker_id=? AND scope='merged'",
      arguments: [rootID.uuidString])
  }

  /// Back to `unknown / kept_unknown`; the name stays as meeting metadata.
  func unlink(meetingID: UUID, speakerID: UUID, now: Int64) throws {
    try write { db in
      try Self.upsertManual(
        meetingID: meetingID, speakerID: speakerID, scope: "self", state: .unknown,
        origin: .keptUnknown, knownSpeakerID: nil, confirmedAt: nil, correctedAt: nil, now: now,
        db: db)
    }
  }

  // MARK: Helpers

  private static func upsertManual(
    meetingID: UUID, speakerID: UUID, scope: String, state: IdentityState, origin: IdentityOrigin,
    knownSpeakerID: UUID?, confirmedAt: Int64?, correctedAt: Int64?, now: Int64, db: Database
  ) throws {
    guard
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM meeting_speakers WHERE id=? AND meeting_id=?)",
        arguments: [speakerID.uuidString, meetingID.uuidString]) == true
    else { throw Error.missingRow }
    try db.execute(
      sql: """
        INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id,
          state, origin, run_id, score, engine, model_id, model_revision, threshold_policy,
          second_known_speaker_id, confirmed_at, corrected_at, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,NULL,NULL,NULL,NULL,NULL,NULL,NULL,?,?,?,?)
        ON CONFLICT(meeting_speaker_id, scope) DO UPDATE SET known_speaker_id=excluded.known_speaker_id,
          state=excluded.state, origin=excluded.origin, run_id=NULL, score=NULL, engine=NULL,
          model_id=NULL, model_revision=NULL, threshold_policy=NULL, second_known_speaker_id=NULL,
          confirmed_at=excluded.confirmed_at, corrected_at=COALESCE(excluded.corrected_at, corrected_at),
          updated_at=excluded.updated_at
        """,
      arguments: [
        UUID().uuidString, meetingID.uuidString, speakerID.uuidString, scope,
        knownSpeakerID?.uuidString, state.rawValue, origin.rawValue, confirmedAt, correctedAt, now,
        now,
      ])
  }

  private static func insertRejection(
    meetingID: UUID, speakerID: UUID, candidate: UUID, now: Int64, db: Database
  ) throws {
    let existing =
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM rejected_candidates r JOIN meeting_speakers s ON s.id=r.meeting_speaker_id
          WHERE s.meeting_id=?
          """, arguments: [meetingID.uuidString]) ?? 0
    let present =
      try Bool.fetchOne(
        db,
        sql:
          "SELECT EXISTS(SELECT 1 FROM rejected_candidates WHERE meeting_speaker_id=? AND known_speaker_id=?)",
        arguments: [speakerID.uuidString, candidate.uuidString]) ?? false
    guard present || existing < rejectedPerMeeting else {
      throw Error.capacity(.rejectedCandidates)
    }
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO rejected_candidates (meeting_speaker_id, known_speaker_id, rejected_at)
        VALUES (?,?,?)
        """, arguments: [speakerID.uuidString, candidate.uuidString, now])
  }

  /// The existing name path: `display_name` plus one `rename` correction when it changes.
  private static func copyName(
    _ name: String, to speakerID: UUID, meetingID: UUID, now: Int64, onlyIfEmpty: Bool = false,
    db: Database
  )
    throws
  {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT display_name, run_id FROM meeting_speakers WHERE id=?",
        arguments: [speakerID.uuidString])
    else { throw Error.missingRow }
    let previous: String? = row["display_name"]
    guard previous != name else { return }
    if onlyIfEmpty, previous != nil { return }
    try db.execute(
      sql: "UPDATE meeting_speakers SET display_name=? WHERE id=?",
      arguments: [name, speakerID.uuidString])
    if let run = try SpeakerStore.acceptedRun(meetingID, db: db) {
      try SpeakerStore.reserveCorrections(1, meetingID: meetingID, db: db)
      try SpeakerStore.insertCorrection(
        db, meetingID: meetingID, runID: run.id, kind: "rename", speakerID: speakerID,
        previous: previous, new: name, now: now)
    }
  }

  private static func bump(_ id: UUID, expected: Int64, now: Int64, db: Database) throws {
    guard
      let revision = try Int64.fetchOne(
        db, sql: "SELECT revision FROM known_speakers WHERE id=?", arguments: [id.uuidString])
    else { throw Error.missingRow }
    guard revision == expected else { throw Error.revisionMismatch }
    try db.execute(
      sql: "UPDATE known_speakers SET revision=revision+1, updated_at=? WHERE id=?",
      arguments: [now, id.uuidString])
  }

  private func end(
    _ runID: UUID, as state: IdentificationRunState, category: IdentificationFailureCategory,
    detail: String?, now: Int64
  ) throws {
    let detail = detail.flatMap { $0.utf8.count <= 512 ? $0 : nil }
    try write { db in
      let run = try Self.transition(runID, to: state, db: db)
      try db.execute(
        sql: "DELETE FROM match_candidates WHERE run_id=?", arguments: [runID.uuidString])
      try db.execute(
        sql: """
          UPDATE identification_runs SET state=?, failure_category=?, failure_detail=?, completed_at=?
          WHERE id=?
          """, arguments: [state.rawValue, category.rawValue, detail, now, runID.uuidString])
      try Self.touch(
        run.meetingID, now: now, db: db, set: "current_run_id=NULLIF(current_run_id, ?)",
        runID.uuidString)
    }
  }

  private func write<T>(_ body: (Database) throws -> T) throws -> T {
    do {
      return try database.write(body)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
      throw Error.persistenceCapacity
    }
  }

  private static func transition(_ id: UUID, to state: IdentificationRunState, db: Database) throws
    -> IdentificationRun
  {
    guard let run = try fetchRun(id, db: db) else { throw Error.missingRow }
    do {
      try IdentificationRunLifecycle.transition(from: run.state, to: state)
    } catch { throw Error.invalidTransition(from: run.state, to: state) }
    return run
  }

  private static func touch(
    _ meetingID: UUID, now: Int64, db: Database, set assignment: String,
    _ values: any DatabaseValueConvertible...
  ) throws {
    try db.execute(
      sql: "UPDATE meeting_identification SET \(assignment), updated_at=? WHERE meeting_id=?",
      arguments: StatementArguments(
        values + [now as any DatabaseValueConvertible, meetingID.uuidString]))
    guard db.changesCount == 1 else { throw Error.missingRow }
  }

  static func fetchIdentification(_ meetingID: UUID, db: Database) throws -> MeetingIdentification?
  {
    try Row.fetchOne(
      db, sql: "SELECT * FROM meeting_identification WHERE meeting_id=?",
      arguments: [meetingID.uuidString]
    ).map { row in
      MeetingIdentification(
        meetingID: meetingID,
        acceptedRunID: (row["accepted_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        currentRunID: (row["current_run_id"] as String?).flatMap(UUID.init(uuidString:)),
        updatedAt: row["updated_at"])
    }
  }

  static func fetchRun(_ id: UUID, db: Database) throws -> IdentificationRun? {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM identification_runs WHERE id=?", arguments: [id.uuidString]),
      let meetingID = UUID(uuidString: row["meeting_id"]),
      let diarizationRunID = UUID(uuidString: row["diarization_run_id"]),
      let state = IdentificationRunState(rawValue: row["state"]),
      let trigger = IdentificationTrigger(rawValue: row["trigger"])
    else { return nil }
    var run = IdentificationRun(
      id: id, meetingID: meetingID, diarizationRunID: diarizationRunID, state: state,
      trigger: trigger,
      identity: VoiceModelIdentity(
        engine: row["engine"], modelID: row["model_id"], modelRevision: row["model_revision"],
        manifestHash: row["model_manifest_hash"], dimension: row["dimension"]),
      pipelineVersion: row["pipeline_version"], thresholdPolicy: row["threshold_policy"],
      createdAt: row["created_at"])
    run.startedAt = row["started_at"]
    run.completedAt = row["completed_at"]
    run.failureCategory = (row["failure_category"] as String?)
      .flatMap(IdentificationFailureCategory.init(rawValue:))
    run.failureDetail = row["failure_detail"]
    run.clusterCount = row["cluster_count"]
    run.candidateCount = row["candidate_count"]
    run.regionCount = row["region_count"]
    run.rejectedRegionCount = row["rejected_region_count"]
    run.comparisonCount = row["comparison_count"]
    run.recognizedCount = row["recognized_count"]
    run.suggestedCount = row["suggested_count"]
    run.unknownCount = row["unknown_count"]
    run.preservedManualCount = row["preserved_manual_count"]
    run.preemptionCount = row["preemption_count"]
    return run
  }

  private static func knownSpeaker(_ row: Row) -> KnownSpeakerRow? {
    guard let id = UUID(uuidString: row["id"]) else { return nil }
    let active: Int = row["active_samples"] ?? 0
    return KnownSpeakerRow(
      id: id, name: row["display_name"], activeSampleCount: active,
      recognitionEnabled: row["recognition_enabled"],
      state: active > 0 ? .active : .needsReenrollment, isLocalUser: row["is_local_user"],
      revision: row["revision"], createdAt: row["created_at"])
  }
}

/// Vectors are stored as little-endian Float32, `dimension × 4` bytes.
enum VectorCodec {
  static func encode(_ vector: [Float]) -> Data {
    var data = Data(capacity: vector.count * 4)
    for value in vector {
      var bits = value.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func decode(_ data: Data?, dimension: Int) -> [Float]? {
    guard let data, data.count == dimension * 4 else { return nil }
    var vector = [Float](repeating: 0, count: dimension)
    data.withUnsafeBytes { bytes in
      for index in 0..<dimension {
        let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
        vector[index] = Float(bitPattern: UInt32(littleEndian: bits))
      }
    }
    return vector
  }
}
