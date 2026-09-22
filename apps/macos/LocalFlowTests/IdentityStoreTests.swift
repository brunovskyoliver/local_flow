import GRDB
import XCTest

@testable import LocalFlow

/// `identities-v8` and `IdentityStore`: schema, known speakers, samples, runs,
/// assignments, corrections, deletion and restart persistence (T015, T019, T053, T067,
/// T071, T081).
final class IdentityStoreTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!
  private var store: IdentityStore!
  private let identity = IdentificationTestSupport.identity

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
    store = IdentityStore(database: fixture.history.database, identity: identity)
  }
  override func tearDown() { fixture.cleanup() }

  private var database: DatabaseQueue { fixture.history.database }

  /// A meeting with an accepted diarization run: the local cluster plus `remote` remote
  /// clusters. Returns the meeting id and the cluster ids (local first).
  private func meeting(remote: Int = 1) async throws -> (id: UUID, clusters: [UUID]) {
    let created = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    var turns: [[(Int64, Int64)]] = []
    for index in 0..<remote {
      let start = Int64(6_000 + index * 12_000)
      turns.append([(start, start + 8_000)])
    }
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID,
      remote: turns, stretchLengths: [Int64(20_000 + remote * 12_000)])
    return (created.meetingID, result.clusters)
  }

  private func known(_ name: String, local: Bool = false) async throws -> KnownSpeakerRow {
    try await store.createKnownSpeaker(name: name, isLocalUser: local, now: 100)
  }

  private func draft(
    _ axis: Int, meeting: UUID, speaker: UUID, quality: Double = 0.8, startMs: Int64 = 0,
    identity: VoiceModelIdentity? = nil
  ) -> VoiceSampleDraft {
    IdentificationTestSupport.draft(
      vector: VoiceVectors.unit(axis: axis), meetingID: meeting, speakerID: speaker,
      startMs: startMs, endMs: startMs + 8_000, quality: quality,
      identity: identity ?? self.identity)
  }

  private func count(_ sql: String, _ arguments: StatementArguments = []) async throws -> Int {
    try await database.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
  }

  private func decision(_ candidate: UUID, state: IdentityState, score: Float = 0.9)
    -> IdentityMatcher.Decision
  {
    let best = IdentityMatcher.Candidate(
      knownSpeakerID: candidate, score: score,
      tier: state == .recognized ? .recognized : .possible, reasons: [], sampleCount: 3,
      supportCount: 3)
    return IdentityMatcher.Decision(
      state: state, best: state == .unknown ? nil : best, second: nil, candidates: [best])
  }

  private func runFor(_ meetingID: UUID, trigger: IdentificationTrigger = .manual) async throws
    -> IdentificationRun
  {
    try await store.admit(
      meetingID: meetingID, trigger: trigger, identity: identity,
      policy: IdentificationThresholds.policyVersion(for: identity), now: 50)
  }

  // MARK: Schema (T015)

  func testMigrationOnAFeature007DatabaseAddsIdentityTablesAndOneRowPerMeeting() throws {
    let directory = try makeMeetingTestRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try DatabaseQueue(path: directory.appendingPathComponent("h.sqlite").path)
    try HistoryMigrations.migrator().migrate(database, upTo: "speakers-v7")
    let ids = [UUID(), UUID()]
    try database.write { db in
      for (index, id) in ids.enumerated() {
        try db.execute(
          sql: "INSERT INTO meetings(id,state,created_at,updated_at) VALUES(?,?,?,?)",
          arguments: [id.uuidString, "completed", 1, 5 + index])
      }
    }
    let before = try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') ORDER BY name"
      ).map { "\($0["name"] as String)=\($0["sql"] as String? ?? "")" }
    }
    try HistoryMigrations.migrator().migrate(database, upTo: "identities-v8")
    try database.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM meeting_identification ORDER BY updated_at")
      XCTAssertEqual(rows.map { $0["meeting_id"] as String }, ids.map(\.uuidString))
      XCTAssertTrue(rows.allSatisfy { ($0["accepted_run_id"] as String?) == nil })
      let after = try Row.fetchAll(
        db, sql: "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') ORDER BY name"
      ).map { "\($0["name"] as String)=\($0["sql"] as String? ?? "")" }
      // Every 001–007 table and index is byte-identical; only new objects were added.
      XCTAssertEqual(Set(before).subtracting(after), [], "No earlier table or index changed")
      let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
      for name in [
        "known_speakers", "voice_samples", "meeting_identification", "identification_runs",
        "identity_assignments", "match_candidates", "rejected_candidates",
      ] {
        XCTAssertTrue(tables.contains(name), name)
      }
      let vector = try db.columns(in: "voice_samples").first { $0.name == "vector" }
      XCTAssertEqual(vector?.type.uppercased(), "BLOB")
    }
  }

  // MARK: Known speakers (T015)

  func testCreateRenameSetRecognitionAndDeleteWithRevisionChecks() async throws {
    let tomas = try await known("Tomáš Novák")
    XCTAssertEqual(tomas.revision, 0)
    XCTAssertEqual(tomas.state, .needsReenrollment)
    do {
      try await store.rename(knownSpeakerID: tomas.id, to: "Tomáš", expectedRevision: 3, now: 101)
      XCTFail("Stale revision accepted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .revisionMismatch) }
    try await store.rename(knownSpeakerID: tomas.id, to: "Tomáš", expectedRevision: 0, now: 101)
    var rows = try await store.knownSpeakers()
    XCTAssertEqual(rows.map(\.name), ["Tomáš"])
    XCTAssertEqual(rows.first?.revision, 1)
    try await store.setRecognition(
      knownSpeakerID: tomas.id, enabled: false, expectedRevision: 1, now: 102)
    rows = try await store.knownSpeakers()
    XCTAssertEqual(rows.first?.recognitionEnabled, false)
    XCTAssertEqual(rows.first?.revision, 2)
    do {
      try await store.deleteKnownSpeaker(id: tomas.id, expectedRevision: 1)
      XCTFail("Stale revision accepted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .revisionMismatch) }
    try await store.deleteKnownSpeaker(id: tomas.id, expectedRevision: 2)
    rows = try await store.knownSpeakers()
    XCTAssertEqual(rows, [])
    do {
      _ = try await store.createKnownSpeaker(name: "  ", isLocalUser: false, now: 1)
      XCTFail("A blank name was accepted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .invalidDraft("name")) }
  }

  func testOnlyOneLocalUserProfileAndAThousandKnownSpeakers() async throws {
    _ = try await known("Me", local: true)
    do {
      _ = try await known("Me again", local: true)
      XCTFail("A second local profile was created")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .localUserExists) }
    // The partial unique index refuses what the store would not attempt.
    try await database.write { db in
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO known_speakers (id, display_name, is_local_user, created_at, updated_at)
            VALUES (?, 'X', 1, 1, 1)
            """, arguments: [UUID().uuidString]))
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO known_speakers (id, display_name, is_local_user, created_at, updated_at)
          VALUES (?, ?, 0, 1, 1)
          """)
      for index in 0..<(IdentityStore.knownSpeakerCapacity - 1) {
        try insert.execute(arguments: [UUID().uuidString, "Speaker \(index)"])
      }
    }
    do {
      _ = try await known("One too many")
      XCTFail("Capacity exceeded")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .capacity(.knownSpeakers)) }
  }

  // MARK: Samples (T015)

  func testAddSamplesStoresOneRowPerRegionWithItsMetadata() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let stored = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        draft(1, meeting: meetingID, speaker: clusters[1]),
        draft(2, meeting: meetingID, speaker: clusters[1], startMs: 20_000),
      ], consent: .remember, now: 200)
    XCTAssertEqual(stored, 2)
    let rows = try await database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM voice_samples WHERE known_speaker_id=? ORDER BY start_ms",
        arguments: [tomas.id.uuidString])
    }
    XCTAssertEqual(rows.count, 2)
    let first = rows[0]
    XCTAssertEqual(first["engine"] as String, identity.engine)
    XCTAssertEqual(first["model_revision"] as String, identity.modelRevision)
    XCTAssertEqual(first["model_manifest_hash"] as String, identity.manifestHash)
    XCTAssertEqual(first["dimension"] as Int, 256)
    XCTAssertEqual(first["pipeline_version"] as String, IdentificationPipelineVersion.current)
    XCTAssertEqual((first["vector"] as Data).count, 1_024)
    XCTAssertEqual(first["quality_label"] as String, "good")
    XCTAssertEqual(first["quality_score"] as Double, 0.8)
    XCTAssertEqual(first["speech_ms"] as Int64, 8_000)
    XCTAssertEqual(first["track"] as String, "system")
    XCTAssertEqual(first["start_ms"] as Int64, 0)
    XCTAssertEqual(first["end_ms"] as Int64, 8_000)
    XCTAssertEqual(first["source_meeting_id"] as String, meetingID.uuidString)
    XCTAssertEqual(first["source_speaker_id"] as String, clusters[1].uuidString)
    XCTAssertEqual(first["consent"] as String, "remember")
    XCTAssertEqual(first["active"] as Int, 1)
    XCTAssertEqual(first["created_at"] as Int64, 200)
    XCTAssertEqual(
      VectorCodec.decode(first["vector"] as Data, dimension: 256), VoiceVectors.unit(axis: 1))
    let list = try await store.samples(knownSpeakerID: tomas.id)
    XCTAssertEqual(list.count, 2)
    XCTAssertEqual(list.map(\.speechMs), [8_000, 8_000])
    XCTAssertEqual(list.map(\.qualityLabel), [.good, .good])
    XCTAssertFalse(list[0].provenanceUnavailable)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.first?.activeSampleCount, 2)
    XCTAssertEqual(known.first?.state, .active)
    // The vector length CHECK holds at the schema.
    let firstID: String = first["id"]
    try await database.write { db in
      XCTAssertThrowsError(
        try db.execute(
          sql: "UPDATE voice_samples SET vector=? WHERE id=?",
          arguments: [Data(repeating: 0, count: 1_020), firstID]))
    }
    do {
      _ = try await store.addSamples(
        knownSpeakerID: tomas.id,
        drafts: [
          IdentificationTestSupport.draft(
            vector: [1, 0], meetingID: meetingID, speakerID: clusters[1])
        ], consent: .remember, now: 201)
      XCTFail("A vector of the wrong length was accepted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .invalidDraft("sample")) }
  }

  func testTheCapRetiresInOneTransactionAndKeepsAtMostTenRetiredRows() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let cluster = clusters[1]
    for batch in 0..<5 {
      _ = try await store.addSamples(
        knownSpeakerID: tomas.id,
        drafts: (0..<5).map {
          draft(
            batch * 5 + $0, meeting: meetingID, speaker: cluster, quality: 0.5,
            startMs: Int64(batch * 5 + $0) * 9_000)
        }, consent: .remember, now: Int64(300 + batch))
      let active = try await count(
        "SELECT count(*) FROM voice_samples WHERE known_speaker_id=? AND active=1",
        [tomas.id.uuidString])
      XCTAssertLessThanOrEqual(active, SampleRetirementPolicy.cap)
      let retired = try await count(
        "SELECT count(*) FROM voice_samples WHERE known_speaker_id=? AND active=0",
        [tomas.id.uuidString])
      XCTAssertLessThanOrEqual(retired, SampleRetirementPolicy.retainedRetired)
    }
    let total = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(total, 20)
    let consistent = try await count(
      "SELECT count(*) FROM voice_samples WHERE (retired_at IS NOT NULL) <> (active = 0)")
    XCTAssertEqual(consistent, 0)
    let listed = try await store.samples(knownSpeakerID: tomas.id)
    XCTAssertEqual(listed.count, 10, "Retired samples are not listed")
    let profiles = try await store.profiles(compatibleWith: identity)
    XCTAssertEqual(profiles.first?.samples.count, 10, "Retired samples are not compared")
  }

  func testAddSamplesRefusesARejectedSourceCluster() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[1], candidate: tomas.id, keepUnknown: true,
      now: 300)
    do {
      _ = try await store.addSamples(
        knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
        consent: .alsoRemember, now: 301)
      XCTFail("A rejected source was accepted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .rejectedSource) }
    let rows = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(rows, 0)
  }

  func testProfilesExcludeDisabledIncompatibleAndEmptyProfiles() async throws {
    let (meetingID, clusters) = try await meeting()
    let active = try await known("Active")
    let disabled = try await known("Disabled")
    let old = try await known("Old model")
    _ = try await known("Empty")
    let local = try await known("Me", local: true)
    for (speaker, axis) in [(active, 1), (disabled, 2), (local, 3)] {
      _ = try await store.addSamples(
        knownSpeakerID: speaker.id, drafts: [draft(axis, meeting: meetingID, speaker: clusters[1])],
        consent: .remember, now: 400)
    }
    let previous = VoiceModelIdentity(
      engine: identity.engine, modelID: identity.modelID,
      modelRevision: String(repeating: "0", count: 40), manifestHash: identity.manifestHash,
      dimension: 256)
    _ = try await store.addSamples(
      knownSpeakerID: old.id,
      drafts: [draft(4, meeting: meetingID, speaker: clusters[1], identity: previous)],
      consent: .remember, now: 401)
    try await store.setRecognition(
      knownSpeakerID: disabled.id, enabled: false, expectedRevision: 1, now: 402)
    let profiles = try await store.profiles(compatibleWith: identity)
    XCTAssertEqual(Set(profiles.map(\.id)), [active.id, local.id])
    XCTAssertEqual(profiles.first { $0.id == local.id }?.isLocalUser, true)
    let rows = try await store.knownSpeakers()
    XCTAssertEqual(rows.first { $0.id == old.id }?.state, .needsReenrollment)
    XCTAssertEqual(rows.first { $0.id == old.id }?.activeSampleCount, 0)
    XCTAssertEqual(rows.first { $0.id == active.id }?.state, .active)
  }

  // MARK: Runs (T015)

  func testAdmissionNeedsAnAcceptedDiarizationRunAndOneActiveRunPerMeeting() async throws {
    let bare = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    do {
      _ = try await runFor(bare.meetingID)
      XCTFail("Admitted without an accepted diarization run")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .missingRow) }
    let (meetingID, _) = try await meeting()
    let run = try await runFor(meetingID)
    XCTAssertEqual(run.state, .pending)
    XCTAssertEqual(run.thresholdPolicy, "tiers_v1@wespeaker_resnet34lm_256/11111111")
    XCTAssertEqual(run.pipelineVersion, "embed_offline1spk_dw_v1+regions_v1")
    do {
      _ = try await runFor(meetingID)
      XCTFail("Second active run admitted")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .runInProgress) }
    try await database.write { db in
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO identification_runs (id, meeting_id, diarization_run_id, state, "trigger", engine,
              model_id, model_revision, model_manifest_hash, dimension, pipeline_version, threshold_policy,
              created_at) VALUES (?,?,?,'pending','manual','e','m','r',?,256,'p','t',1)
            """,
          arguments: [
            UUID().uuidString, meetingID.uuidString, run.diarizationRunID.uuidString,
            String(repeating: "b", count: 64),
          ]))
    }
    let state = try await store.meetingState(meetingID: meetingID)
    XCTAssertEqual(state, .pending)
    let identification = try await store.identification(meetingID: meetingID)
    XCTAssertEqual(identification?.currentRunID, run.id)
  }

  func testRunTransitionsFollowTheTable() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let run = try await runFor(meetingID)
    do {
      _ = try await store.complete(runID: run.id, decisions: [:], now: 60)
    }
    // pending → succeeded is the zero-candidate short circuit.
    var fetched = try await store.run(id: run.id)
    XCTAssertEqual(fetched?.state, .succeeded)
    let second = try await runFor(meetingID, trigger: .retry)
    _ = try await store.start(runID: second.id, now: 61)
    do {
      _ = try await store.start(runID: second.id, now: 62)
      XCTFail("running → running")
    } catch {
      XCTAssertEqual(
        error as? IdentityStore.Error, .invalidTransition(from: .running, to: .running))
    }
    try await store.appendCandidates(
      runID: second.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.4, tier: .below,
          reasons: [.belowMedium], sampleCount: 1, supportCount: 0)
      ])
    try await store.requeue(runID: second.id)
    fetched = try await store.run(id: second.id)
    XCTAssertEqual(fetched?.state, .pending)
    XCTAssertEqual(fetched?.preemptionCount, 1)
    XCTAssertNil(fetched?.startedAt)
    let candidates = try await count("SELECT count(*) FROM match_candidates")
    XCTAssertEqual(candidates, 0, "A preempted run drops its candidates")
    _ = try await store.start(runID: second.id, now: 63)
    try await store.interrupt(runID: second.id, now: 64)
    fetched = try await store.run(id: second.id)
    XCTAssertEqual(fetched?.state, .interrupted)
    XCTAssertEqual(fetched?.failureCategory, .interrupted)
    let state = try await store.meetingState(meetingID: meetingID)
    XCTAssertEqual(state, .interrupted)
    let third = try await runFor(meetingID, trigger: .retry)
    _ = try await store.start(runID: third.id, now: 65)
    try await store.fail(runID: third.id, category: .runtimeFailure, detail: "region", now: 66)
    fetched = try await store.run(id: third.id)
    XCTAssertEqual(fetched?.state, .failed)
    XCTAssertEqual(fetched?.failureCategory, .runtimeFailure)
    XCTAssertEqual(fetched?.failureDetail, "region")
    let latest = try await store.latestRun(meetingID: meetingID)
    XCTAssertEqual(latest?.id, third.id)
    let fourth = try await runFor(meetingID, trigger: .retry)
    try await store.cancel(runID: fourth.id)
    let gone = try await store.run(id: fourth.id)
    XCTAssertNil(gone)
    do {
      try await store.cancel(runID: third.id)
      XCTFail("A failed run cannot be cancelled")
    } catch {
      XCTAssertEqual(error as? IdentityStore.Error, .invalidTransition(from: .failed, to: .failed))
    }
    let active = try await store.activeRuns(limit: 10)
    XCTAssertEqual(active, [])
    let stateAfter = try await store.meetingState(meetingID: meetingID)
    XCTAssertEqual(stateAfter, .failed)
  }

  func testCompleteAdoptsAtomicallySupersedesAndPrunesThePreviousRun() async throws {
    let (meetingID, clusters) = try await meeting(remote: 2)
    let tomas = try await known("Tomáš")
    let lukas = try await known("Lukáš")
    let first = try await runFor(meetingID)
    _ = try await store.start(runID: first.id, now: 61)
    try await store.appendCandidates(
      runID: first.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.9, tier: .recognized,
          reasons: [], sampleCount: 3, supportCount: 3)
      ])
    let completed = try await store.complete(
      runID: first.id,
      decisions: [
        clusters[1]: decision(tomas.id, state: .recognized),
        clusters[2]: decision(lukas.id, state: .unknown),
      ], now: 62)
    XCTAssertEqual(completed.state, .succeeded)
    XCTAssertEqual(completed.recognizedCount, 1)
    XCTAssertEqual(completed.unknownCount, 1)
    XCTAssertEqual(completed.clusterCount, 2)
    var identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .recognized)
    XCTAssertEqual(identities[clusters[1]]?.origin, .automaticMatch)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerName, "Tomáš")
    XCTAssertEqual(identities[clusters[2]]?.state, .unknown)
    XCTAssertNil(identities[clusters[0]]?.knownSpeakerID, "The local root has no assignment")
    let row = try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM identity_assignments WHERE meeting_speaker_id=?",
        arguments: [clusters[1].uuidString])
    }
    XCTAssertEqual(row?["score"] as Double? ?? 0, 0.9, accuracy: 1e-6, "FR-019: score recorded")
    XCTAssertEqual(row?["threshold_policy"] as String?, first.thresholdPolicy)
    XCTAssertEqual(row?["engine"] as String?, identity.engine)
    XCTAssertEqual(row?["run_id"] as String?, first.id.uuidString)

    let second = try await runFor(meetingID, trigger: .manual)
    _ = try await store.start(runID: second.id, now: 70)
    try await store.appendCandidates(
      runID: second.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[2], knownSpeakerID: lukas.id, score: 0.6, tier: .possible,
          reasons: [], sampleCount: 3, supportCount: 3)
      ])
    _ = try await store.complete(
      runID: second.id,
      decisions: [
        clusters[1]: decision(tomas.id, state: .unknown),
        clusters[2]: decision(lukas.id, state: .possible, score: 0.6),
      ], now: 71)
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .unknown)
    XCTAssertEqual(identities[clusters[2]]?.state, .possible)
    XCTAssertEqual(identities[clusters[2]]?.knownSpeakerName, "Lukáš")
    let previous = try await store.run(id: first.id)
    XCTAssertEqual(previous?.state, .superseded)
    let firstCandidates = try await count(
      "SELECT count(*) FROM match_candidates WHERE run_id=?", [first.id.uuidString])
    XCTAssertEqual(firstCandidates, 0, "The superseded run's candidates are pruned")
    let secondCandidates = try await count(
      "SELECT count(*) FROM match_candidates WHERE run_id=?", [second.id.uuidString])
    XCTAssertEqual(secondCandidates, 1)
    let identification = try await store.identification(meetingID: meetingID)
    XCTAssertEqual(identification?.acceptedRunID, second.id)
    XCTAssertNil(identification?.currentRunID)
    let assignments = try await count("SELECT count(*) FROM identity_assignments")
    XCTAssertEqual(assignments, 2, "One row per decided root, replaced in place")
  }

  func testAFailedOrInterruptedRunDeletesOnlyItsCandidatesAndLeavesAssignmentsIdentical()
    async throws
  {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let first = try await runFor(meetingID)
    _ = try await store.start(runID: first.id, now: 61)
    try await store.appendCandidates(
      runID: first.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.9, tier: .recognized,
          reasons: [], sampleCount: 3, supportCount: 3)
      ])
    _ = try await store.complete(
      runID: first.id, decisions: [clusters[1]: decision(tomas.id, state: .recognized)], now: 62)
    let before = try IdentificationTestSupport.digest(
      database, tables: ["identity_assignments", "match_candidates"])
    for outcome in ["fail", "interrupt"] {
      let run = try await runFor(meetingID, trigger: .retry)
      _ = try await store.start(runID: run.id, now: 70)
      try await store.appendCandidates(
        runID: run.id,
        rows: [
          .init(
            meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.2, tier: .below,
            reasons: [.belowMedium], sampleCount: 3, supportCount: 0)
        ])
      if outcome == "fail" {
        try await store.fail(runID: run.id, category: .audioMissing, detail: nil, now: 71)
      } else {
        try await store.interrupt(runID: run.id, now: 71)
      }
      let after = try IdentificationTestSupport.digest(
        database, tables: ["identity_assignments", "match_candidates"])
      XCTAssertEqual(after, before, outcome)
      let identification = try await store.identification(meetingID: meetingID)
      XCTAssertEqual(identification?.acceptedRunID, first.id)
    }
  }

  func testMoreThanSixtyFourThousandCandidatesIsRefusedBeforeWriting() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let run = try await runFor(meetingID)
    _ = try await store.start(runID: run.id, now: 61)
    try await database.write { db in
      try db.execute(
        sql: "UPDATE identification_runs SET candidate_count=? WHERE id=?",
        arguments: [IdentityStore.candidatesPerRun, run.id.uuidString])
    }
    do {
      try await store.appendCandidates(
        runID: run.id,
        rows: [
          .init(
            meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.9,
            tier: .recognized, reasons: [], sampleCount: 3, supportCount: 3)
        ])
      XCTFail("Capacity exceeded")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .capacity(.candidates)) }
    let rows = try await count("SELECT count(*) FROM match_candidates")
    XCTAssertEqual(rows, 0)
  }

  func testRowsSurviveARestart() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
      consent: .remember, now: 200)
    let run = try await runFor(meetingID)
    _ = try await store.start(runID: run.id, now: 61)
    _ = try await store.complete(
      runID: run.id, decisions: [clusters[1]: decision(tomas.id, state: .recognized)], now: 62)
    let reopened = try TranscriptionStore(
      path: fixture.directory.appendingPathComponent("history.sqlite").path)
    let second = IdentityStore(history: reopened, identity: identity)
    let known = try await second.knownSpeakers()
    XCTAssertEqual(known.map(\.name), ["Tomáš"])
    XCTAssertEqual(known.first?.activeSampleCount, 1)
    let identities = try await second.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .recognized)
    let fetched = try await second.run(id: run.id)
    XCTAssertEqual(fetched?.state, .succeeded)
    let state = try await second.meetingState(meetingID: meetingID)
    XCTAssertEqual(state, .succeeded)
  }

  // MARK: Assignments (T019)

  func testLinkCopiesTheNameThroughTheNamePathAndSetsConfirmed() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš Novák")
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .newProfileCreated,
      now: 300)
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .confirmed)
    XCTAssertEqual(identities[clusters[1]]?.origin, .newProfileCreated)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerID, tomas.id)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerName, "Tomáš Novák")
    XCTAssertEqual(identities[clusters[1]]?.sampleOfferAvailable, true)
    let summaries = try await speakers.speakerSummaries(meetingID: meetingID)
    XCTAssertEqual(summaries.first { $0.id == clusters[1] }?.displayName, "Tomáš Novák")
    let corrections = try await count(
      "SELECT count(*) FROM speaker_corrections WHERE kind='rename' AND new_value='Tomáš Novák'")
    XCTAssertEqual(corrections, 1, "The existing name path records the rename")
    let row = try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT confirmed_at, score FROM identity_assignments WHERE meeting_speaker_id=?",
        arguments: [clusters[1].uuidString])
    }
    XCTAssertEqual(row?["confirmed_at"] as Int64?, 300)
    XCTAssertNil(row?["score"] as Double?)
    do {
      try await store.link(
        meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .automaticMatch,
        now: 301)
      XCTFail("A manual link cannot claim an automatic origin")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .invalidDraft("origin")) }
  }

  func testTheSchemaAllowsExactlyTheStateOriginPairsOfTheSpec() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let allowed: [(IdentityState, IdentityOrigin, Bool)] = [
      (.recognized, .automaticMatch, true), (.possible, .automaticMatch, true),
      (.confirmed, .userConfirmation, true), (.confirmed, .manualProfileSelection, true),
      (.confirmed, .newProfileCreated, true), (.confirmed, .manualCorrection, true),
      (.rejectedUnknown, .keptUnknown, false), (.unknown, .automaticMatch, false),
      (.unknown, .keptUnknown, false),
    ]
    let forbidden: [(IdentityState, IdentityOrigin, Bool)] = [
      (.recognized, .userConfirmation, true), (.possible, .keptUnknown, true),
      (.confirmed, .automaticMatch, true), (.confirmed, .keptUnknown, true),
      (.rejectedUnknown, .automaticMatch, false), (.rejectedUnknown, .userConfirmation, false),
      (.recognized, .automaticMatch, false), (.unknown, .automaticMatch, true),
      (.rejectedUnknown, .keptUnknown, true),
    ]
    func insert(_ state: IdentityState, _ origin: IdentityOrigin, _ known: Bool) throws {
      try database.write { db in
        try db.execute(sql: "DELETE FROM identity_assignments")
        let automatic = state == .recognized || state == .possible
        try db.execute(
          sql: """
            INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id,
              state, origin, run_id, score, engine, model_id, model_revision, threshold_policy,
              confirmed_at, created_at, updated_at)
            VALUES (?,?,?,'self',?,?,?,NULL,?,?,?,?,?,?,1,1)
            """,
          arguments: [
            UUID().uuidString, meetingID.uuidString, clusters[1].uuidString,
            known ? tomas.id.uuidString : nil, state.rawValue, origin.rawValue,
            automatic ? 0.5 : nil, automatic ? "e" : nil, automatic ? "m" : nil,
            automatic ? "r" : nil, automatic ? "t" : nil, state == .confirmed ? 1 : nil,
          ])
      }
    }
    for (state, origin, known) in allowed {
      if state == .recognized || state == .possible {
        // Automatic rows also need a run id; exercise them through the store instead.
        continue
      }
      XCTAssertNoThrow(try insert(state, origin, known), "\(state) \(origin)")
    }
    for (state, origin, known) in forbidden {
      XCTAssertThrowsError(try insert(state, origin, known), "\(state) \(origin)")
    }
  }

  func testRejectRecordsThePairAndKeepUnknownWritesRejectedUnknown() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[1], candidate: tomas.id, keepUnknown: false,
      now: 300)
    var identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state ?? .unknown, .unknown)
    let pairs = try await count("SELECT count(*) FROM rejected_candidates")
    XCTAssertEqual(pairs, 1)
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[1], candidate: tomas.id, keepUnknown: true,
      now: 301)
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .rejectedUnknown)
    XCTAssertEqual(identities[clusters[1]]?.origin, .keptUnknown)
    XCTAssertNil(identities[clusters[1]]?.knownSpeakerID)
    let stillOne = try await count("SELECT count(*) FROM rejected_candidates")
    XCTAssertEqual(stillOne, 1, "The pair is recorded once")
  }

  func testMoreThanAThousandRejectedPairsPerMeetingIsRefused() async throws {
    let (meetingID, clusters) = try await meeting(remote: 2)
    // 499 speakers rejected for both remote clusters: 998 pairs.
    try await database.write { db in
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO known_speakers (id, display_name, created_at, updated_at) VALUES (?,?,1,1)
          """)
      let reject = try db.cachedStatement(
        sql: "INSERT INTO rejected_candidates VALUES (?,?,1)")
      for index in 0..<499 {
        let id = UUID().uuidString
        try insert.execute(arguments: [id, "K\(index)"])
        try reject.execute(arguments: [clusters[1].uuidString, id])
        try reject.execute(arguments: [clusters[2].uuidString, id])
      }
    }
    // Pairs 999 and 1,000 fit; the next is refused.
    let last = try await known("Last")
    for cluster in [clusters[1], clusters[2]] {
      try await store.reject(
        meetingID: meetingID, speakerID: cluster, candidate: last.id, keepUnknown: false, now: 299)
    }
    let extra = try await known("One more")
    do {
      try await store.reject(
        meetingID: meetingID, speakerID: clusters[1], candidate: extra.id, keepUnknown: true,
        now: 300)
      XCTFail("Capacity exceeded")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .capacity(.rejectedCandidates)) }
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertNotEqual(identities[clusters[1]]?.state, .rejectedUnknown, "Nothing was written")
    let pairs = try await count("SELECT count(*) FROM rejected_candidates")
    XCTAssertEqual(pairs, IdentityStore.rejectedPerMeeting)
  }

  func testMergedResolutionAndUnmergeThroughTheMergedIdentityRule() async throws {
    let (meetingID, clusters) = try await meeting(remote: 2)
    let tomas = try await known("Tomáš")
    let lukas = try await known("Lukáš")
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .manualProfileSelection,
      now: 300)
    try await store.link(
      meetingID: meetingID, speakerID: clusters[2], to: lukas.id, origin: .manualProfileSelection,
      now: 301)
    try await speakers.merge(
      meetingID: meetingID, speakerID: clusters[2], into: clusters[1], now: 302)
    var identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.needsChoice, true)
    XCTAssertEqual(identities[clusters[1]]?.state, .unknown)
    XCTAssertEqual(identities[clusters[1]]?.origin, .keptUnknown)
    XCTAssertNil(identities[clusters[2]], "A merged member is not a display root")
    try await store.resolveMerged(
      meetingID: meetingID, rootID: clusters[1], to: .knownSpeaker(lukas.id), now: 303)
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.needsChoice, false)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerID, lukas.id)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerName, "Lukáš")
    XCTAssertEqual(identities[clusters[1]]?.origin, .manualProfileSelection)
    let selfRows = try await database.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT meeting_speaker_id, known_speaker_id FROM identity_assignments WHERE scope='self' ORDER BY created_at"
      ).map { ($0["meeting_speaker_id"] as String, $0["known_speaker_id"] as String) }
    }
    XCTAssertEqual(
      selfRows.map(\.1), [tomas.id.uuidString, lukas.id.uuidString],
      "self rows are never modified by merge or resolution")
    // Undo the merge: the merged row goes with it and both self rows apply again.
    try await speakers.unmerge(meetingID: meetingID, speakerID: clusters[2], now: 304)
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerID, tomas.id)
    XCTAssertEqual(identities[clusters[2]]?.knownSpeakerID, lukas.id)
    let merged = try await count("SELECT count(*) FROM identity_assignments WHERE scope='merged'")
    XCTAssertEqual(merged, 0)
    // Keep Unknown as a resolution.
    try await speakers.merge(
      meetingID: meetingID, speakerID: clusters[2], into: clusters[1], now: 305)
    try await store.resolveMerged(
      meetingID: meetingID, rootID: clusters[1], to: .keepUnknown, now: 306)
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .rejectedUnknown)
    XCTAssertEqual(identities[clusters[1]]?.needsChoice, false)
    try await store.clearMergedResolution(meetingID: meetingID, rootID: clusters[1])
    identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.needsChoice, true)
  }

  func testUnlinkReturnsToUnknownKeptUnknown() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .userConfirmation,
      now: 300)
    try await store.unlink(meetingID: meetingID, speakerID: clusters[1], now: 301)
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.state, .unknown)
    XCTAssertEqual(identities[clusters[1]]?.origin, .keptUnknown)
    XCTAssertNil(identities[clusters[1]]?.knownSpeakerID)
    let summaries = try await speakers.speakerSummaries(meetingID: meetingID)
    XCTAssertEqual(summaries.first { $0.id == clusters[1] }?.displayName, "Tomáš", "The name stays")
  }

  // MARK: Corrections (T053)

  func testConfirmationAndCorrectionRecordWhatWasRejectedAndSurviveReruns() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    let lukas = try await known("Lukáš")
    let first = try await runFor(meetingID)
    _ = try await store.start(runID: first.id, now: 61)
    _ = try await store.complete(
      runID: first.id, decisions: [clusters[1]: decision(tomas.id, state: .possible, score: 0.6)],
      now: 62)
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .userConfirmation, now: 70
    )
    var row = try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM identity_assignments WHERE meeting_speaker_id=?",
        arguments: [clusters[1].uuidString])
    }
    XCTAssertEqual(row?["state"] as String?, "confirmed")
    XCTAssertEqual(row?["origin"] as String?, "user_confirmation")
    XCTAssertEqual(row?["confirmed_at"] as Int64?, 70)
    XCTAssertNil(row?["corrected_at"] as Int64?)
    // Correct to Lukáš: Tomáš is recorded as rejected for this cluster.
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: lukas.id, origin: .manualCorrection, now: 71
    )
    row = try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM identity_assignments WHERE meeting_speaker_id=?",
        arguments: [clusters[1].uuidString])
    }
    XCTAssertEqual(row?["origin"] as String?, "manual_correction")
    XCTAssertEqual(row?["corrected_at"] as Int64?, 71)
    XCTAssertEqual(row?["known_speaker_id"] as String?, lukas.id.uuidString)
    let rejected = try await database.read { db in
      try String.fetchAll(
        db, sql: "SELECT known_speaker_id FROM rejected_candidates WHERE meeting_speaker_id=?",
        arguments: [clusters[1].uuidString])
    }
    XCTAssertEqual(rejected, [tomas.id.uuidString])
    do {
      _ = try await store.addSamples(
        knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
        consent: .alsoRemember, now: 72)
      XCTFail("FR-007: no sample for the rejected speaker")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .rejectedSource) }
    let stored = try await store.addSamples(
      knownSpeakerID: lukas.id, drafts: [draft(2, meeting: meetingID, speaker: clusters[1])],
      consent: .alsoRemember, now: 73)
    XCTAssertEqual(stored, 1)
    // A rerun keeps the manual row and would never re-suggest the rejected pair.
    let second = try await runFor(meetingID, trigger: .manual)
    _ = try await store.start(runID: second.id, now: 80)
    let completed = try await store.complete(
      runID: second.id, decisions: [clusters[1]: decision(tomas.id, state: .recognized)], now: 81)
    XCTAssertEqual(completed.preservedManualCount, 1)
    XCTAssertEqual(completed.recognizedCount, 0)
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerID, lukas.id)
    XCTAssertEqual(identities[clusters[1]]?.origin, .manualCorrection)
    let pairs = try await store.rejectedCandidates(meetingID: meetingID)
    XCTAssertEqual(pairs, [clusters[1]: [tomas.id]])
    // An automatic decision naming a rejected pair is downgraded to Unknown at adoption.
    try await store.unlink(meetingID: meetingID, speakerID: clusters[1], now: 82)
    try await database.write { db in
      try db.execute(sql: "DELETE FROM identity_assignments")
    }
    let third = try await runFor(meetingID, trigger: .manual)
    _ = try await store.start(runID: third.id, now: 90)
    _ = try await store.complete(
      runID: third.id, decisions: [clusters[1]: decision(tomas.id, state: .possible, score: 0.6)],
      now: 91)
    let after = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(after[clusters[1]]?.state, .unknown)
    XCTAssertNil(after[clusters[1]]?.knownSpeakerID)
  }

  // MARK: Picking (T067)

  func testManualProfileSelectionLinksWithoutAProfileOrSampleAndDuplicateNamesAreAllowed()
    async throws
  {
    let (meetingID, clusters) = try await meeting()
    let lukas = try await known("Lukáš Kocman")
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: lukas.id, origin: .manualProfileSelection,
      now: 300)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.count, 1)
    let samples = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(samples, 0)
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.origin, .manualProfileSelection)
    XCTAssertEqual(identities[clusters[1]]?.state, .confirmed)
    let summaries = try await speakers.speakerSummaries(meetingID: meetingID)
    XCTAssertEqual(summaries.first { $0.id == clusters[1] }?.displayName, "Lukáš Kocman")
    // "Someone new" with the same name after the explicit choice.
    let second = try await self.known("Lukáš Kocman")
    XCTAssertNotEqual(second.id, lukas.id)
    let all = try await store.knownSpeakers()
    XCTAssertEqual(all.map(\.name), ["Lukáš Kocman", "Lukáš Kocman"])
  }

  // MARK: Deletion matrix (T071)

  func testDeletingAKnownSpeakerLeavesZeroReferencesCopiedNamesAndUnchangedTranscripts()
    async throws
  {
    let (meetingID, clusters) = try await meeting(remote: 2)
    let tomas = try await known("Tomáš")
    let lukas = try await known("Lukáš")
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
      consent: .remember, now: 200)
    let run = try await runFor(meetingID)
    _ = try await store.start(runID: run.id, now: 61)
    try await store.appendCandidates(
      runID: run.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.9, tier: .recognized,
          reasons: [], sampleCount: 1, supportCount: 1),
        .init(
          meetingSpeakerID: clusters[2], knownSpeakerID: tomas.id, score: 0.6, tier: .possible,
          reasons: [], sampleCount: 1, supportCount: 1),
      ])
    _ = try await store.complete(
      runID: run.id,
      decisions: [
        clusters[1]: decision(tomas.id, state: .recognized),
        clusters[2]: decision(tomas.id, state: .possible, score: 0.6),
      ], now: 62)
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[2], candidate: lukas.id, keepUnknown: false,
      now: 63)
    // The recognized row carries the name as meeting metadata already.
    try await speakers.saveNames(meetingID: meetingID, names: [clusters[1]: "Tomáš"], now: 64)
    let preserved = IdentificationTestSupport.preservedTables
    let before = try IdentificationTestSupport.digest(database, tables: preserved)
    let textBefore = try await count("SELECT sum(length(normalized_text)) FROM transcript_segments")
    let revision = try await store.knownSpeakers().first { $0.id == tomas.id }!.revision
    try await store.deleteKnownSpeaker(id: tomas.id, expectedRevision: revision)
    for table in [
      "voice_samples", "identity_assignments", "match_candidates", "rejected_candidates",
    ] {
      let rows = try await count(
        "SELECT count(*) FROM \(table) WHERE known_speaker_id=?", [tomas.id.uuidString])
      XCTAssertEqual(rows, 0, table)
    }
    let after = try IdentificationTestSupport.digest(database, tables: preserved)
    XCTAssertEqual(after, before, "SC-012: transcript, turns and audio rows are untouched")
    let textAfter = try await count("SELECT sum(length(normalized_text)) FROM transcript_segments")
    XCTAssertEqual(textAfter, textBefore)
    let summaries = try await speakers.speakerSummaries(meetingID: meetingID)
    XCTAssertEqual(summaries.first { $0.id == clusters[1] }?.displayName, "Tomáš")
    XCTAssertNil(
      summaries.first { $0.id == clusters[2] }?.displayName, "A Possible row had no name")
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertNil(identities[clusters[1]]?.knownSpeakerID, "Unlinked, as if typed and Not now")
    XCTAssertEqual(identities[clusters[1]]?.state ?? .unknown, .unknown)
    let others = try await count("SELECT count(*) FROM rejected_candidates")
    XCTAssertEqual(others, 1, "Other speakers' rows stay")
  }

  func testDeletingAMeetingCascadesIdentityRowsAndNullsSampleProvenance() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
      consent: .remember, now: 200)
    let run = try await runFor(meetingID)
    _ = try await store.start(runID: run.id, now: 61)
    try await store.appendCandidates(
      runID: run.id,
      rows: [
        .init(
          meetingSpeakerID: clusters[1], knownSpeakerID: tomas.id, score: 0.9, tier: .recognized,
          reasons: [], sampleCount: 1, supportCount: 1)
      ])
    _ = try await store.complete(
      runID: run.id, decisions: [clusters[1]: decision(tomas.id, state: .recognized)], now: 62)
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[1], candidate: tomas.id, keepUnknown: false,
      now: 63)
    try await database.write { db in
      try db.execute(sql: "DELETE FROM meetings WHERE id=?", arguments: [meetingID.uuidString])
    }
    for table in [
      "meeting_identification", "identification_runs", "identity_assignments", "match_candidates",
      "rejected_candidates",
    ] {
      let rows = try await count("SELECT count(*) FROM \(table)")
      XCTAssertEqual(rows, 0, table)
    }
    let samples = try await store.samples(knownSpeakerID: tomas.id)
    XCTAssertEqual(samples.count, 1)
    XCTAssertTrue(samples[0].provenanceUnavailable)
    XCTAssertNil(samples[0].sourceTitle)
    XCTAssertEqual(samples[0].sourceDate, 200, "The creation date stands in for the meeting")
    let profiles = try await store.profiles(compatibleWith: identity)
    XCTAssertEqual(profiles.map(\.id), [tomas.id], "Still matched")
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.count, 1)
  }

  func testRemovingTheLastCompatibleSampleDerivesNeedsReenrollment() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
      consent: .remember, now: 200)
    let sample = try await store.samples(knownSpeakerID: tomas.id).first!
    try await store.removeSample(id: sample.id, now: 201)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.first?.state, .needsReenrollment)
    XCTAssertEqual(known.first?.activeSampleCount, 0)
    let profiles = try await store.profiles(compatibleWith: identity)
    XCTAssertEqual(profiles, [])
    do {
      try await store.removeSample(id: sample.id, now: 202)
      XCTFail("Removed twice")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .missingRow) }
  }

  func testDisablingRecognitionKeepsHistoricalRowsAndAModelChangeKeepsOldSamples() async throws {
    let (meetingID, clusters) = try await meeting()
    let tomas = try await known("Tomáš")
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id, drafts: [draft(1, meeting: meetingID, speaker: clusters[1])],
      consent: .remember, now: 200)
    let run = try await runFor(meetingID)
    _ = try await store.start(runID: run.id, now: 61)
    _ = try await store.complete(
      runID: run.id, decisions: [clusters[1]: decision(tomas.id, state: .recognized)], now: 62)
    let revision = try await store.knownSpeakers().first!.revision
    try await store.setRecognition(
      knownSpeakerID: tomas.id, enabled: false, expectedRevision: revision, now: 300)
    let profiles = try await store.profiles(compatibleWith: identity)
    XCTAssertEqual(profiles, [])
    let identities = try await store.identities(meetingID: meetingID)
    XCTAssertEqual(identities[clusters[1]]?.knownSpeakerID, tomas.id)
    // A new model revision: the old sample stays stored and stops being compared.
    let next = VoiceModelIdentity(
      engine: identity.engine, modelID: identity.modelID,
      modelRevision: String(repeating: "2", count: 40), manifestHash: identity.manifestHash,
      dimension: 256)
    try await store.setRecognition(
      knownSpeakerID: tomas.id, enabled: true, expectedRevision: revision + 1, now: 301)
    let nextStore = IdentityStore(database: database, identity: next)
    let compatible = try await nextStore.profiles(compatibleWith: next)
    XCTAssertEqual(compatible, [])
    let rows = try await nextStore.knownSpeakers()
    XCTAssertEqual(rows.first?.state, .needsReenrollment)
    let stored = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(stored, 1, "FR-029: the old sample is neither overwritten nor discarded")
  }

  func testRenameCopiesLinkedNamesInBatchesAndLeavesUnlinkedNamesAlone() async throws {
    let (meetingID, clusters) = try await meeting(remote: 2)
    let tomas = try await known("Tomáš")
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id, origin: .userConfirmation,
      now: 300)
    try await speakers.saveNames(meetingID: meetingID, names: [clusters[2]: "Tomáš"], now: 301)
    // 600 linked speakers across synthetic meetings: two batches of 500 and 100.
    try await database.write { db in
      for index in 0..<IdentityStore.renameBatch + 100 {
        let meeting = UUID().uuidString
        let speaker = UUID().uuidString
        try db.execute(
          sql: "INSERT INTO meetings(id,state,created_at,updated_at) VALUES(?,?,?,?)",
          arguments: [meeting, "completed", index, index])
        try db.execute(
          sql: """
            INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, track, origin,
              display_name) VALUES (?,?,NULL,0,'remote',NULL,'manual','Tomáš')
            """, arguments: [speaker, meeting])
        try db.execute(
          sql: """
            INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id,
              state, origin, confirmed_at, created_at, updated_at)
            VALUES (?,?,?,'self',?,'confirmed','user_confirmation',1,1,1)
            """, arguments: [UUID().uuidString, meeting, speaker, tomas.id.uuidString])
      }
    }
    let revision = try await store.knownSpeakers().first!.revision
    try await store.rename(
      knownSpeakerID: tomas.id, to: "Tomáš Novák", expectedRevision: revision, now: 302)
    let renamed = try await count(
      "SELECT count(*) FROM meeting_speakers WHERE display_name='Tomáš Novák'")
    XCTAssertEqual(renamed, IdentityStore.renameBatch + 101)
    let summaries = try await speakers.speakerSummaries(meetingID: meetingID)
    XCTAssertEqual(summaries.first { $0.id == clusters[1] }?.displayName, "Tomáš Novák")
    XCTAssertEqual(
      summaries.first { $0.id == clusters[2] }?.displayName, "Tomáš", "Typed name untouched")
  }

  // MARK: Past search (T081)

  func testMeetingsWithUnknownRemoteSpeakersAreNewestFirstAndCapped() async throws {
    let tomas = try await known("Tomáš")
    var ids: [UUID] = []
    var clustersOf: [UUID: [UUID]] = [:]
    for index in 0..<4 {
      let created = try await TranscriptMeetingFixture.make(
        in: fixture, stretches: [.init()], startedAt: 1_700_000_000_000 + Int64(index) * 1_000)
      let result = try await IdentificationTestSupport.acceptedDiarization(
        fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID)
      ids.append(created.meetingID)
      clustersOf[created.meetingID] = result.clusters
    }
    // Meeting 0: confirmed; meeting 1: rejected_unknown; 2 and 3 stay unknown/absent.
    try await store.link(
      meetingID: ids[0], speakerID: clustersOf[ids[0]]![1], to: tomas.id, origin: .userConfirmation,
      now: 300)
    try await store.reject(
      meetingID: ids[1], speakerID: clustersOf[ids[1]]![1], candidate: tomas.id, keepUnknown: true,
      now: 301)
    let run = try await runFor(ids[2])
    _ = try await store.complete(
      runID: run.id, decisions: [clustersOf[ids[2]]![1]: .unknown], now: 302)
    // A meeting without an accepted diarization run never qualifies.
    _ = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let found = try await store.meetingsWithUnknownRemoteSpeakers(limit: 500)
    XCTAssertEqual(found, [ids[3], ids[2]])
    let capped = try await store.meetingsWithUnknownRemoteSpeakers(limit: 1)
    XCTAssertEqual(capped, [ids[3]])
  }
}
