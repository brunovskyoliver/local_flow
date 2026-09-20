import GRDB
import XCTest

@testable import LocalFlow

/// The run pipeline through `FakeVoiceEmbeddingRuntime`: success, the zero-candidate
/// short circuit, preemption, failure categories, reruns and the local profile
/// (T039, T078, T085).
@MainActor
final class MeetingIdentifierTests: XCTestCase {
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

  private static let blocks = 260
  private static let stretchMs = Int64(blocks) * TranscriptMeetingFixture.blockMs

  /// One local cluster at [500, 5_000) on the microphone; remote clusters on the system
  /// track: the same person at [6_000, 14_000), a different person at [15_000, 21_000)
  /// and a short one at [21_500, 22_000) (below the region minimum).
  private func meeting(
    remote: [[(Int64, Int64)]]? = nil, blocks: Int = MeetingIdentifierTests.blocks
  )
    async throws -> (id: UUID, clusters: [UUID])
  {
    let created = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(blocks), system: .blocks(blocks))])
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID,
      remote: remote ?? [[(6_000, 14_000)], [(15_000, 21_000)], [(21_500, 22_000)]],
      stretchLengths: [Int64(blocks) * TranscriptMeetingFixture.blockMs])
    return (created.meetingID, result.clusters)
  }

  private func makeIdentifier(
    _ runtime: FakeVoiceEmbeddingRuntime, store: (any IdentityStoring)? = nil,
    loadError: (any Error)? = nil, recorder: ResourceRecorder? = nil
  ) -> (MeetingIdentifier, ModelLifecycleCoordinator, FakeVoiceEmbeddingFactory) {
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: {
        if let loadError { throw loadError }
        return try await factory.make()
      }, factory: { FakeTranscriptionRuntime() })
    let identifier = MeetingIdentifier(
      store: store ?? self.store, speakers: speakers, transcripts: transcripts,
      meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      identity: identity, clock: FakeMeetingClock(), recorder: recorder)
    return (identifier, lifecycle, factory)
  }

  /// Tomáš, enrolled with three samples close to `unit(axis: 1)`.
  private func enrollTomas(from meeting: (id: UUID, clusters: [UUID])) async throws
    -> KnownSpeakerRow
  {
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: (0..<3).map {
        IdentificationTestSupport.draft(
          vector: VoiceVectors.related(axis: 1, other: 20 + $0, cosine: 0.95),
          meetingID: meeting.id, speakerID: meeting.clusters[1], startMs: Int64($0) * 9_000,
          endMs: Int64($0) * 9_000 + 8_000)
      }, consent: .remember, now: 2)
    return tomas
  }

  /// FR-026: transcript rows, turns, audio rows and samples. Names on
  /// `meeting_speakers` are metadata the existing name path may copy on recognition.
  private func preserved() throws -> String {
    try IdentificationTestSupport.digest(
      fixture.history.database,
      tables: IdentificationTestSupport.preservedTables.filter { $0 != "meeting_speakers" }
        + ["voice_samples"])
  }

  private func count(_ sql: String) async throws -> Int {
    try await fixture.history.database.read { try Int.fetchOne($0, sql: sql) ?? 0 }
  }

  // MARK: T039

  func testAdmissionRecordsTheAcceptedDiarizationRun() async throws {
    let (identifier, _, _) = makeIdentifier(FakeVoiceEmbeddingRuntime())
    let meeting = try await meeting(blocks: 4)
    let diarization = try await speakers.diarization(meetingID: meeting.id)
    let admitted = try await identifier.admit(meetingID: meeting.id, trigger: .manual)
    let run = try XCTUnwrap(admitted)
    XCTAssertEqual(run.diarizationRunID, diarization?.acceptedRunID)
    XCTAssertEqual(run.state, .pending)
    XCTAssertEqual(run.thresholdPolicy, "tiers_v1@wespeaker_resnet34lm_256/11111111")
    XCTAssertEqual(run.identity, identity)
    let bare = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    do {
      _ = try await identifier.admit(meetingID: bare.meetingID, trigger: .manual)
      XCTFail("No accepted diarization run")
    } catch { XCTAssertEqual(error as? IdentityStore.Error, .missingRow) }
  }

  func testZeroCompatibleProfilesCompletesWithEveryRemoteRootUnknownAndNoLease() async throws {
    let runtime = FakeVoiceEmbeddingRuntime()
    let (identifier, lifecycle, factory) = makeIdentifier(runtime)
    let meeting = try await meeting(blocks: 4)
    // A local-only profile is evidence, not a candidate: still no lease.
    let me = try await store.createKnownSpeaker(name: "Me", isLocalUser: true, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: me.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 5), meetingID: meeting.id, speakerID: meeting.clusters[0],
          track: .microphone)
      ], consent: .localEnroll, now: 2)
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .automatic)
    let outcome = await identifier.run(meetingID: meeting.id)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(run.unknownCount, 3)
    XCTAssertEqual(run.clusterCount, 3)
    let made = await factory.makeCount
    XCTAssertEqual(made, 0)
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
    let identities = try await store.identities(meetingID: meeting.id)
    for cluster in meeting.clusters.dropFirst() {
      XCTAssertEqual(identities[cluster]?.state, .unknown)
      XCTAssertEqual(identities[cluster]?.origin, .automaticMatch)
    }
    XCTAssertEqual(identities[meeting.clusters[0]]?.knownSpeakerID, nil, "\"You\" has no row")
    let rows = try await count(
      "SELECT count(*) FROM identity_assignments WHERE score IS NOT NULL")
    XCTAssertEqual(rows, 0, "No score without a comparison")
    let candidates = try await count("SELECT count(*) FROM match_candidates")
    XCTAssertEqual(candidates, 0)
  }

  func testSuccessRecognizesTheSamePersonLeavesOthersUnknownAndTouchesNothingElse()
    async throws
  {
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let meeting = try await meeting()
    let tomas = try await enrollTomas(from: meeting)
    // Region 1 (same person) matches; region 2 (different person) is orthogonal.
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [
      VoiceVectors.unit(axis: 1), VoiceVectors.unit(axis: 2),
    ])
    let (identifier, lifecycle, _) = makeIdentifier(runtime, recorder: capture.recorder)
    let before = try preserved()
    let textBefore = try await count("SELECT sum(length(normalized_text)) FROM transcript_segments")
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .manual)
    var progress: [(Int, Int)] = []
    let sink = ProgressSink()
    let outcome = await identifier.run(meetingID: meeting.id) { done, planned in
      Task { await sink.add(done, planned) }
    }
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    progress = await sink.values
    XCTAssertEqual(progress.first?.1, 2, "Two regions planned: the short cluster has none")
    XCTAssertEqual(progress.last?.0, 2)
    XCTAssertEqual(run.recognizedCount, 1)
    XCTAssertEqual(run.unknownCount, 2)
    XCTAssertEqual(run.regionCount, 2)
    XCTAssertEqual(run.rejectedRegionCount, 0)
    XCTAssertEqual(run.candidateCount, 2, "One candidate row per scored (root, profile)")
    let requests = await runtime.requests
    XCTAssertEqual(requests, [7_600 * 16, 5_600 * 16], "Query regions, one per remote root")
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertEqual(identities[meeting.clusters[1]]?.state, .recognized)
    XCTAssertEqual(identities[meeting.clusters[1]]?.knownSpeakerID, tomas.id)
    XCTAssertEqual(identities[meeting.clusters[2]]?.state, .unknown)
    XCTAssertEqual(identities[meeting.clusters[3]]?.state, .unknown)
    let rows = try await fixture.history.database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT meeting_speaker_id, tier, reasons FROM match_candidates ORDER BY tier")
    }
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(
      Set(rows.map { $0["tier"] as String }), ["recognized", "below"])
    XCTAssertEqual(
      rows.first { ($0["tier"] as String) == "below" }?["reasons"] as String?, "below_medium")
    // The lease was finished before matching; nothing is resident afterwards.
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(snapshot.state, .unloaded)
    XCTAssertEqual(
      try preserved(), before, "Transcript, turns, audio rows and samples are byte-identical")
    let textAfter = try await count("SELECT sum(length(normalized_text)) FROM transcript_segments")
    XCTAssertEqual(textAfter, textBefore)
    // Metrics: counts and durations only.
    let samples = try await capture.samples()
    let metrics = samples.compactMap { $0["metric"] as? String }
    XCTAssertTrue(metrics.contains("identificationDuration"))
    XCTAssertTrue(metrics.contains("identificationRecognized"))
    XCTAssertTrue(metrics.contains("identificationComparisons"))
    for sample in samples {
      for forbidden in ["name", "vector", "text", "meetingID", "start", "end"] {
        XCTAssertNil(sample[forbidden])
      }
    }
    // "You" was never queried: only system-track regions were read.
    XCTAssertEqual(requests.count, 2)
  }

  func testABusyModelLeavesTheRunPendingAndAPreemptionRequeuesIt() async throws {
    let meeting = try await meeting()
    _ = try await enrollTomas(from: meeting)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let (identifier, lifecycle, _) = makeIdentifier(runtime)
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .manual)
    let asr = try await lifecycle.acquire(session: UUID())
    let busy = await identifier.run(meetingID: meeting.id)
    XCTAssertEqual(busy, .busy)
    var state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .pending)
    try await lifecycle.finish(asr)
    // Preempted while a region is in flight: back to pending, restarted from the first region.
    let gate = PreparationGate()
    await runtime.hold(gate)
    let task = Task { await identifier.run(meetingID: meeting.id) }
    await gate.waitUntilStarted()
    let speech = Task { try await lifecycle.acquire(session: UUID()) }
    for _ in 0..<1000 {
      if await lifecycle.state == .releasing { break }
      await Task.yield()
    }
    await gate.open()
    let lease = try await speech.value
    let preempted = await task.value
    XCTAssertEqual(preempted, .preempted)
    state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .pending)
    let run = try await store.latestRun(meetingID: meeting.id)
    XCTAssertEqual(run?.preemptionCount, 1)
    XCTAssertEqual(run?.regionCount, 0)
    let candidates = try await count("SELECT count(*) FROM match_candidates")
    XCTAssertEqual(candidates, 0)
    await lifecycle.cancelAndJoin(lease)
    let again = await identifier.run(meetingID: meeting.id)
    guard case .succeeded(let completed) = again else { return XCTFail("\(again)") }
    XCTAssertEqual(completed.preemptionCount, 1)
    let requests = await runtime.requests
    XCTAssertEqual(requests.count, 3, "First region twice, then the rest")
  }

  // MARK: T078

  func testRerunAdmitsAManualRunAndReplacesAutomaticRowsButKeepsManualOnes() async throws {
    let meeting = try await meeting()
    let tomas = try await enrollTomas(from: meeting)
    let lukas = try await store.createKnownSpeaker(name: "Lukáš", isLocalUser: false, now: 3)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [
      VoiceVectors.unit(axis: 1), VoiceVectors.unit(axis: 2),
    ])
    let (identifier, _, _) = makeIdentifier(runtime)
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .automatic)
    guard case .succeeded = await identifier.run(meetingID: meeting.id) else { return XCTFail() }
    // The user corrects the different person to Lukáš: a manual row.
    try await store.link(
      meetingID: meeting.id, speakerID: meeting.clusters[2], to: lukas.id,
      origin: .manualCorrection,
      now: 10)
    let transcription = try await transcripts.transcription(meetingID: meeting.id)
    let diarization = try await speakers.diarization(meetingID: meeting.id)
    let before = try preserved()
    // A fresh scripted runtime: the fake hands out vectors in call order.
    let (again, _, _) = makeIdentifier(
      FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1), VoiceVectors.unit(axis: 2)]))
    let readmitted = try await again.admit(meetingID: meeting.id, trigger: .manual)
    let rerun = try XCTUnwrap(readmitted)
    XCTAssertEqual(rerun.trigger, .manual)
    let outcome = await again.run(meetingID: meeting.id)
    guard case .succeeded(let completed) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(completed.preservedManualCount, 1)
    XCTAssertEqual(completed.recognizedCount, 1)
    // Neither transcription nor diarization ran again (SC-007).
    let transcriptionAfter = try await transcripts.transcription(meetingID: meeting.id)
    XCTAssertEqual(transcriptionAfter, transcription)
    let diarizationAfter = try await speakers.diarization(meetingID: meeting.id)
    XCTAssertEqual(diarizationAfter?.acceptedRunID, diarization?.acceptedRunID)
    XCTAssertEqual(diarizationAfter?.revision, diarization?.revision)
    XCTAssertEqual(try preserved(), before)
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertEqual(identities[meeting.clusters[1]]?.knownSpeakerID, tomas.id)
    XCTAssertEqual(identities[meeting.clusters[2]]?.knownSpeakerID, lukas.id)
    XCTAssertEqual(identities[meeting.clusters[2]]?.origin, .manualCorrection)
    let superseded = try await count(
      "SELECT count(*) FROM identification_runs WHERE state='superseded'")
    XCTAssertEqual(superseded, 1)
  }

  func testEveryFailureCategoryLeavesEverythingIdenticalAndDeletesOnlyItsCandidates()
    async throws
  {
    let meeting = try await meeting()
    _ = try await enrollTomas(from: meeting)
    // An accepted run first, so "previous assignments" exist.
    let good = FakeVoiceEmbeddingRuntime(scripts: [
      VoiceVectors.unit(axis: 1), VoiceVectors.unit(axis: 2),
    ])
    let (identifier, _, _) = makeIdentifier(good)
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .automatic)
    guard case .succeeded(let accepted) = await identifier.run(meetingID: meeting.id) else {
      return XCTFail()
    }
    let before = try IdentificationTestSupport.digest(
      fixture.history.database,
      tables: IdentificationTestSupport.preservedTables + [
        "voice_samples", "identity_assignments", "match_candidates",
      ])

    func check(_ expected: IdentificationFailureCategory, _ outcome: MeetingIdentifier.Outcome)
      async throws
    {
      XCTAssertEqual(outcome, .failed(expected))
      let after = try IdentificationTestSupport.digest(
        fixture.history.database,
        tables: IdentificationTestSupport.preservedTables + [
          "voice_samples", "identity_assignments", "match_candidates",
        ])
      XCTAssertEqual(after, before, "\(expected)")
      let run = try await store.latestRun(meetingID: meeting.id)
      XCTAssertEqual(run?.failureCategory, expected)
      let identification = try await store.identification(meetingID: meeting.id)
      XCTAssertEqual(identification?.acceptedRunID, accepted.id, "\(expected)")
    }

    // model_unavailable, os_unsupported, model_load_failure: the factory refuses.
    for category in [
      IdentificationFailureCategory.modelUnavailable, .osUnsupported, .modelLoadFailure,
    ] {
      let (failing, _, _) = makeIdentifier(good, loadError: category)
      _ = try await failing.admit(meetingID: meeting.id, trigger: .retry)
      try await check(category, await failing.run(meetingID: meeting.id))
    }
    // runtime_failure: the embedder throws.
    let broken = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    await broken.failRegion(1)
    let (runtimeFailing, _, _) = makeIdentifier(broken)
    _ = try await runtimeFailing.admit(meetingID: meeting.id, trigger: .retry)
    try await check(.runtimeFailure, await runtimeFailing.run(meetingID: meeting.id))
    // diarization_changed: the accepted diarization run moved on after admission.
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .retry)
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meeting_diarization SET accepted_run_id=NULL WHERE meeting_id=?",
        arguments: [meeting.id.uuidString])
    }
    let changed = await identifier.run(meetingID: meeting.id)
    XCTAssertEqual(changed, .failed(.diarizationChanged))
    let run = try await store.latestRun(meetingID: meeting.id)
    XCTAssertEqual(run?.failureCategory, .diarizationChanged)
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meeting_diarization SET accepted_run_id=? WHERE meeting_id=?",
        arguments: [accepted.diarizationRunID.uuidString, meeting.id.uuidString])
    }
    // persistence_failure and persistence_capacity: the store refuses.
    for (error, category) in [
      (IdentityStore.Error.missingRow, IdentificationFailureCategory.persistenceFailure),
      (IdentityStore.Error.persistenceCapacity, .persistenceCapacity),
    ] {
      let failing = FailingIdentityStore(store, failCompleteWith: error)
      let (identifier, _, _) = makeIdentifier(good, store: failing)
      _ = try await identifier.admit(meetingID: meeting.id, trigger: .retry)
      try await check(category, await identifier.run(meetingID: meeting.id))
    }
    // audio_missing: every stretch file is gone. audio_decode_failure: a file is garbage.
    let loaded = try await fixture.store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    let paths = detail.tracks.flatMap { $0.segments.map(\.relativePath) }
    let urls = paths.compactMap { fixture.root.resolve(relativePath: $0) }
    let system = try XCTUnwrap(urls.first { $0.lastPathComponent.hasPrefix("system") })
    let original = try Data(contentsOf: system)
    try Data(repeating: 0x55, count: 2_048).write(to: system)
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .retry)
    try await check(.audioDecodeFailure, await identifier.run(meetingID: meeting.id))
    try original.write(to: system)
    for url in urls { try FileManager.default.removeItem(at: url) }
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .retry)
    try await check(.audioMissing, await identifier.run(meetingID: meeting.id))
  }

  // MARK: T085

  func testTheLocalProfileIsScoredAsEvidenceOnlyAndNeverNamesOrRelabels() async throws {
    let meeting = try await meeting()
    let me = try await store.createKnownSpeaker(name: "Me", isLocalUser: true, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: me.id,
      drafts: (0..<3).map {
        IdentificationTestSupport.draft(
          vector: VoiceVectors.related(axis: 1, other: 30 + $0, cosine: 0.95),
          meetingID: meeting.id, speakerID: meeting.clusters[0], track: .microphone,
          startMs: Int64($0) * 9_000, endMs: Int64($0) * 9_000 + 8_000)
      }, consent: .localEnroll, now: 2)
    _ = try await enrollTomas(from: meeting)
    // The first remote root sounds exactly like the local profile and like Tomáš.
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [
      VoiceVectors.unit(axis: 1), VoiceVectors.unit(axis: 2),
    ])
    let (identifier, _, _) = makeIdentifier(runtime)
    let labelsBefore = try await transcripts.labeledPage(
      meetingID: meeting.id, finality: .final, after: nil, limit: 200
    ).map { $0.label?.text }
    _ = try await identifier.admit(meetingID: meeting.id, trigger: .manual)
    guard case .succeeded = await identifier.run(meetingID: meeting.id) else { return XCTFail() }
    let rows = try await fixture.history.database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT known_speaker_id, tier FROM match_candidates WHERE meeting_speaker_id=?",
        arguments: [meeting.clusters[1].uuidString])
    }
    let tiers = Dictionary(
      uniqueKeysWithValues: rows.map { ($0["known_speaker_id"] as String, $0["tier"] as String) })
    XCTAssertEqual(tiers[me.id.uuidString], "local_evidence")
    XCTAssertEqual(tiers.count, 2)
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertNotEqual(identities[meeting.clusters[1]]?.knownSpeakerID, me.id)
    XCTAssertNil(identities[meeting.clusters[0]]?.knownSpeakerID)
    let labelsAfter = try await transcripts.labeledPage(
      meetingID: meeting.id, finality: .final, after: nil, limit: 200
    ).map { $0.label?.text }
    XCTAssertEqual(labelsAfter.filter { $0 == "You" }, labelsBefore.filter { $0 == "You" })
    XCTAssertTrue(labelsBefore.contains("You"))
  }

  private actor ProgressSink {
    private(set) var values: [(Int, Int)] = []
    func add(_ done: Int, _ planned: Int) { values.append((done, planned)) }
  }
}

/// The real store with one injected failure at `complete`, for the persistence categories.
actor FailingIdentityStore: IdentityStoring {
  private let store: IdentityStore
  private let error: any Error
  init(_ store: IdentityStore, failCompleteWith error: any Error) {
    self.store = store
    self.error = error
  }

  func complete(runID: UUID, decisions: [UUID: IdentityMatcher.Decision], now: Int64) async throws
    -> IdentificationRun
  { throw error }

  func knownSpeakers() async throws -> [KnownSpeakerRow] { try await store.knownSpeakers() }
  func createKnownSpeaker(name: String, isLocalUser: Bool, now: Int64) async throws
    -> KnownSpeakerRow
  { try await store.createKnownSpeaker(name: name, isLocalUser: isLocalUser, now: now) }
  func enroll(
    meetingID: UUID, speakerID: UUID?, name: String, isLocalUser: Bool, origin: IdentityOrigin,
    now: Int64
  ) async throws -> KnownSpeakerRow {
    try await store.enroll(
      meetingID: meetingID, speakerID: speakerID, name: name, isLocalUser: isLocalUser,
      origin: origin, now: now)
  }
  func rename(knownSpeakerID: UUID, to name: String, expectedRevision: Int64, now: Int64)
    async throws
  {
    try await store.rename(
      knownSpeakerID: knownSpeakerID, to: name, expectedRevision: expectedRevision, now: now)
  }
  func setRecognition(knownSpeakerID: UUID, enabled: Bool, expectedRevision: Int64, now: Int64)
    async throws
  {
    try await store.setRecognition(
      knownSpeakerID: knownSpeakerID, enabled: enabled, expectedRevision: expectedRevision, now: now
    )
  }
  func deleteKnownSpeaker(id: UUID, expectedRevision: Int64) async throws {
    try await store.deleteKnownSpeaker(id: id, expectedRevision: expectedRevision)
  }
  func samples(knownSpeakerID: UUID) async throws -> [VoiceSampleRow] {
    try await store.samples(knownSpeakerID: knownSpeakerID)
  }
  func removeSample(id: UUID, now: Int64) async throws {
    try await store.removeSample(id: id, now: now)
  }
  func addSamples(
    knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent, now: Int64
  ) async throws -> Int {
    try await store.addSamples(
      knownSpeakerID: knownSpeakerID, drafts: drafts, consent: consent, now: now)
  }
  func profiles(compatibleWith identity: VoiceModelIdentity) async throws -> [CandidateProfile] {
    try await store.profiles(compatibleWith: identity)
  }
  func identification(meetingID: UUID) async throws -> MeetingIdentification? {
    try await store.identification(meetingID: meetingID)
  }
  func admit(
    meetingID: UUID, trigger: IdentificationTrigger, identity: VoiceModelIdentity,
    policy: String, now: Int64
  ) async throws -> IdentificationRun {
    try await store.admit(
      meetingID: meetingID, trigger: trigger, identity: identity, policy: policy, now: now)
  }
  func run(id: UUID) async throws -> IdentificationRun? { try await store.run(id: id) }
  func start(runID: UUID, now: Int64) async throws -> IdentificationRun {
    try await store.start(runID: runID, now: now)
  }
  func appendCandidates(runID: UUID, rows: [MatchCandidateDraft]) async throws {
    try await store.appendCandidates(runID: runID, rows: rows)
  }
  func fail(runID: UUID, category: IdentificationFailureCategory, detail: String?, now: Int64)
    async throws
  {
    try await store.fail(runID: runID, category: category, detail: detail, now: now)
  }
  func interrupt(runID: UUID, now: Int64) async throws {
    try await store.interrupt(runID: runID, now: now)
  }
  func requeue(runID: UUID) async throws { try await store.requeue(runID: runID) }
  func cancel(runID: UUID) async throws { try await store.cancel(runID: runID) }
  func activeRuns(limit: Int) async throws -> [IdentificationRun] {
    try await store.activeRuns(limit: limit)
  }
  func latestRun(meetingID: UUID) async throws -> IdentificationRun? {
    try await store.latestRun(meetingID: meetingID)
  }
  func meetingState(meetingID: UUID) async throws -> MeetingIdentificationState {
    try await store.meetingState(meetingID: meetingID)
  }
  func meetingsWithUnknownRemoteSpeakers(limit: Int) async throws -> [UUID] {
    try await store.meetingsWithUnknownRemoteSpeakers(limit: limit)
  }
  func identities(meetingID: UUID) async throws -> [UUID: SpeakerIdentity] {
    try await store.identities(meetingID: meetingID)
  }
  func rejectedCandidates(meetingID: UUID) async throws -> [UUID: Set<UUID>] {
    try await store.rejectedCandidates(meetingID: meetingID)
  }
  func recordRegions(runID: UUID, extracted: Int, rejected: Int) async throws {
    try await store.recordRegions(runID: runID, extracted: extracted, rejected: rejected)
  }
  func link(
    meetingID: UUID, speakerID: UUID, to knownSpeakerID: UUID, origin: IdentityOrigin, now: Int64
  ) async throws {
    try await store.link(
      meetingID: meetingID, speakerID: speakerID, to: knownSpeakerID, origin: origin, now: now)
  }
  func reject(
    meetingID: UUID, speakerID: UUID, candidate knownSpeakerID: UUID, keepUnknown: Bool, now: Int64
  ) async throws {
    try await store.reject(
      meetingID: meetingID, speakerID: speakerID, candidate: knownSpeakerID,
      keepUnknown: keepUnknown, now: now)
  }
  func resolveMerged(meetingID: UUID, rootID: UUID, to resolution: MergedResolution, now: Int64)
    async throws
  {
    try await store.resolveMerged(meetingID: meetingID, rootID: rootID, to: resolution, now: now)
  }
  func clearMergedResolution(meetingID: UUID, rootID: UUID) async throws {
    try await store.clearMergedResolution(meetingID: meetingID, rootID: rootID)
  }
  func unlink(meetingID: UUID, speakerID: UUID, now: Int64) async throws {
    try await store.unlink(meetingID: meetingID, speakerID: speakerID, now: now)
  }
}
