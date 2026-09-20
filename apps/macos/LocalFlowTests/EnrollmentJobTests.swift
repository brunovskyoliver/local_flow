import GRDB
import XCTest

@testable import LocalFlow

/// US1, US3 and US7 enrollment paths through `FakeVoiceEmbeddingRuntime` and a real
/// `IdentityStore` (T027, T055, T085).
@MainActor
final class EnrollmentJobTests: XCTestCase {
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

  /// 200 blocks of 4,096 frames at 48 kHz per track: 17.07 s of tone.
  private static let blocks = 200
  private static let stretchMs = Int64(blocks) * TranscriptMeetingFixture.blockMs

  /// A meeting whose local cluster speaks at [500, 5_000) on the microphone and whose
  /// remote cluster speaks in `remote` on the system track.
  private func meeting(
    remote: [(Int64, Int64)] = [(6_000, 14_000)], local: [(Int64, Int64)] = [(500, 5_000)]
  ) async throws -> (id: UUID, local: UUID, remote: UUID) {
    let created = try await TranscriptMeetingFixture.make(
      in: fixture,
      stretches: [.init(microphone: .blocks(Self.blocks), system: .blocks(Self.blocks))])
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID,
      local: local, remote: [remote], stretchLengths: [Self.stretchMs])
    return (created.meetingID, result.clusters[0], result.clusters[1])
  }

  private func makeJob(
    _ runtime: FakeVoiceEmbeddingRuntime, factory: FakeVoiceEmbeddingFactory? = nil,
    loadError: (any Error)? = nil
  ) -> (EnrollmentJob, ModelLifecycleCoordinator) {
    let embedder = factory ?? FakeVoiceEmbeddingFactory(runtime: runtime)
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: {
        if let loadError { throw loadError }
        return try await embedder.make()
      }, factory: { FakeTranscriptionRuntime() })
    let job = EnrollmentJob(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      clock: FakeMeetingClock())
    return (job, lifecycle)
  }

  private func request(
    _ meeting: (id: UUID, local: UUID, remote: UUID), target: EnrollmentRequest.Target,
    origin: IdentityOrigin = .newProfileCreated, consent: SampleConsent = .remember
  ) -> EnrollmentRequest {
    EnrollmentRequest(
      meetingID: meeting.id, rootID: meeting.remote, target: target, origin: origin,
      consent: consent, track: .system)
  }

  private func count(_ sql: String) async throws -> Int {
    try await fixture.history.database.read { try Int.fetchOne($0, sql: sql) ?? 0 }
  }

  // MARK: US1 (T027)

  func testNotNowWritesNoKnownSpeakerSampleAssignmentOrRun() async throws {
    let meeting = try await meeting()
    let model = AssignSpeakersModel(
      meetingID: meeting.id, store: speakers, identityStore: store, identificationEnabled: true,
      enroll: { _ in
        XCTFail("Not now never enrolls")
        return .disabled
      }, clock: FakeMeetingClock())
    await model.load()
    model.setDraft("Tomáš", for: meeting.remote)
    model.setIdentityAction(.notNow, for: meeting.remote)
    let closed = await model.save()
    XCTAssertTrue(closed)
    for table in ["known_speakers", "voice_samples", "identity_assignments", "identification_runs"]
    {
      let rows = try await count("SELECT count(*) FROM \(table)")
      XCTAssertEqual(rows, 0, "SC-005: \(table)")
    }
    let summaries = try await speakers.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.first { $0.id == meeting.remote }?.displayName, "Tomáš")
  }

  func testRememberCreatesTheProfileAndIdentityRowBeforeAnyLeaseAndStoresSamplesWithConsent()
    async throws
  {
    let meeting = try await meeting()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let store = self.store!
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: {
        // The profile and the confirmed row are committed before the model loads.
        let known = try await store.knownSpeakers()
        XCTAssertEqual(known.map(\.name), ["Tomáš"])
        let identities = try await store.identities(meetingID: meeting.id)
        XCTAssertEqual(identities[meeting.remote]?.state, .confirmed)
        XCTAssertEqual(identities[meeting.remote]?.origin, .newProfileCreated)
        return try await factory.make()
      }, factory: { FakeTranscriptionRuntime() })
    let job = EnrollmentJob(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      clock: FakeMeetingClock())
    let result = await job.run(request(meeting, target: .newProfile(name: "Tomáš")))
    guard case .outcome(let outcome, let knownID) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .stored(1))
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.first?.id, knownID)
    XCTAssertEqual(known.first?.activeSampleCount, 1)
    let rows = try await fixture.history.database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM voice_samples")
    }
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0]["consent"] as String, "remember")
    XCTAssertEqual(rows[0]["source_meeting_id"] as String, meeting.id.uuidString)
    XCTAssertEqual(rows[0]["source_speaker_id"] as String, meeting.remote.uuidString)
    XCTAssertEqual(rows[0]["track"] as String, "system")
    XCTAssertEqual(rows[0]["start_ms"] as Int64, 6_200)
    XCTAssertEqual(rows[0]["end_ms"] as Int64, 13_800)
    XCTAssertEqual(rows[0]["speech_ms"] as Int64, 7_600)
    XCTAssertEqual(rows[0]["quality_label"] as String, "good")
    let requests = await runtime.requests
    XCTAssertEqual(requests, [7_600 * 16], "One region, 16 kHz")
    let summaries = try await speakers.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.first { $0.id == meeting.remote }?.displayName, "Tomáš")
    // The lease was finished: nothing is resident or leased afterwards.
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(snapshot.state, .unloaded)
    let shutdowns = await runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)
  }

  func testZeroEligibleRegionsGivesAProfileWithNoSamplesAndNoUsableSample() async throws {
    // A 2 s turn is below the 3 s minimum after trims.
    let meeting = try await meeting(remote: [(6_000, 8_000)])
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    let (job, lifecycle) = makeJob(runtime, factory: factory)
    let result = await job.run(request(meeting, target: .newProfile(name: "Tomáš")))
    guard case .outcome(let outcome, _) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .noUsableSample)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.map(\.name), ["Tomáš"])
    XCTAssertEqual(known.first?.activeSampleCount, 0)
    XCTAssertEqual(known.first?.state, .needsReenrollment)
    let made = await factory.makeCount
    XCTAssertEqual(made, 0, "No region, no model")
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertEqual(identities[meeting.remote]?.knownSpeakerName, "Tomáš")
  }

  func testAnEmbedderFailureAfterTheProfileCommitLeavesZeroSamplesAndTheLinkedName()
    async throws
  {
    let meeting = try await meeting()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    await runtime.failRegion(1)
    let (job, lifecycle) = makeJob(runtime)
    let result = await job.run(request(meeting, target: .newProfile(name: "Tomáš")))
    guard case .outcome(let outcome, _) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .failed(.runtimeFailure))
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.first?.activeSampleCount, 0)
    let samples = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(samples, 0)
    let summaries = try await speakers.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.first { $0.id == meeting.remote }?.displayName, "Tomáš")
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded, "The lease is finished on failure")
    // A model that cannot load fails the same way, after the profile.
    let (broken, _) = makeJob(runtime, loadError: IdentificationFailureCategory.modelUnavailable)
    let second = try await self.meeting()
    let failed = await broken.run(request(second, target: .newProfile(name: "Lukáš")))
    guard case .outcome(let category, _) = failed else { return XCTFail("\(failed)") }
    XCTAssertEqual(category, .failed(.modelUnavailable))
    let names = try await store.knownSpeakers().map(\.name)
    XCTAssertEqual(names, ["Lukáš", "Tomáš"])
  }

  func testCancellationFinishesTheLeaseAndReportsInterrupted() async throws {
    let meeting = try await meeting()
    let gate = PreparationGate()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    await runtime.hold(gate)
    let (job, lifecycle) = makeJob(runtime)
    let req = request(meeting, target: .newProfile(name: "Tomáš"))
    let task = Task { await job.run(req) }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.open()
    let result = await task.value
    guard case .outcome(let outcome, _) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .failed(.interrupted))
    for _ in 0..<1000 {
      if await lifecycle.state == .unloaded { break }
      await Task.yield()
    }
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
    let samples = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(samples, 0)
  }

  func testABusyModelAndAPreemptionReportBackWithoutWritingSamples() async throws {
    let meeting = try await meeting()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let (job, lifecycle) = makeJob(runtime)
    let asr = try await lifecycle.acquire(session: UUID())
    let busy = await job.run(request(meeting, target: .newProfile(name: "Tomáš")))
    XCTAssertEqual(busy, .busy)
    try await lifecycle.finish(asr)
    let samples = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(samples, 0)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.count, 1, "The profile stands; the samples come with the retry")
    // Preempted by speech while the region is in flight.
    let gate = PreparationGate()
    await runtime.hold(gate)
    let existing = try XCTUnwrap(known.first?.id)
    let retry = request(meeting, target: .existing(knownSpeakerID: existing))
    let task = Task { await job.run(retry) }
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
    await lifecycle.cancelAndJoin(lease)
    let still = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(still, 0)
  }

  // MARK: US3 (T055)

  func testConfirmWithTheToggleOnAddsSamplesWithAlsoRememberConsent() async throws {
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let (job, _) = makeJob(runtime)
    let result = await job.run(
      request(
        meeting, target: .existing(knownSpeakerID: tomas.id), origin: .userConfirmation,
        consent: .alsoRemember))
    guard case .outcome(let outcome, let knownID) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .stored(1))
    XCTAssertEqual(knownID, tomas.id)
    let consent = try await fixture.history.database.read { db in
      try String.fetchAll(db, sql: "SELECT consent FROM voice_samples")
    }
    XCTAssertEqual(consent, ["also_remember"])
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertEqual(identities[meeting.remote]?.state, .confirmed)
    XCTAssertEqual(identities[meeting.remote]?.origin, .userConfirmation)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.count, 1, "No second profile")
  }

  func testACorrectionNeverAddsToTheRejectedSpeakerEvenWithTheToggleOn() async throws {
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    let lukas = try await store.createKnownSpeaker(name: "Lukáš", isLocalUser: false, now: 2)
    // Tomáš was suggested; the user corrects to Lukáš.
    try await store.link(
      meetingID: meeting.id, speakerID: meeting.remote, to: tomas.id, origin: .userConfirmation,
      now: 3)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let (job, _) = makeJob(runtime)
    let corrected = await job.run(
      request(
        meeting, target: .existing(knownSpeakerID: lukas.id), origin: .manualCorrection,
        consent: .alsoRemember))
    guard case .outcome(let outcome, _) = corrected else { return XCTFail("\(corrected)") }
    XCTAssertEqual(outcome, .stored(1))
    // Even a direct request for the rejected pair stores nothing (FR-007, SC-006).
    let rejected = await job.run(
      request(
        meeting, target: .existing(knownSpeakerID: tomas.id), origin: .userConfirmation,
        consent: .alsoRemember))
    guard case .outcome(let refused, _) = rejected else { return XCTFail("\(rejected)") }
    XCTAssertEqual(refused, .noUsableSample)
    let perSpeaker = try await fixture.history.database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT known_speaker_id, count(*) AS n FROM voice_samples GROUP BY 1"
      ).map { ($0["known_speaker_id"] as String, $0["n"] as Int) }
    }
    XCTAssertEqual(perSpeaker.map(\.0), [lukas.id.uuidString])
    XCTAssertEqual(perSpeaker.map(\.1), [1])
  }

  func testLowQualityRegionsAreNotAddedBecauseTheToggleWasOn() async throws {
    let meeting = try await meeting(remote: [(6_000, 10_000), (11_000, 15_000)])
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    // The segmentation model finds no speech in the second region.
    await runtime.noSpeech(onRegion: 2)
    let (job, _) = makeJob(runtime)
    let result = await job.run(
      request(
        meeting, target: .existing(knownSpeakerID: tomas.id), origin: .userConfirmation,
        consent: .alsoRemember))
    guard case .outcome(let outcome, _) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .stored(1))
    let requests = await runtime.requests
    XCTAssertEqual(requests.count, 2, "Both regions were tried")
    let samples = try await count("SELECT count(*) FROM voice_samples")
    XCTAssertEqual(samples, 1, "Only the usable region became a sample")
  }

  // MARK: US7 (T085)

  func testLocalEnrollmentReadsOnlyMicrophoneRegionsWithLocalEnrollConsent() async throws {
    let meeting = try await meeting(
      remote: [(6_500, 10_000)], local: [(500, 6_000), (10_500, 16_000)])
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 9)])
    let (job, _) = makeJob(runtime)
    var req = EnrollmentRequest(
      meetingID: meeting.id, rootID: meeting.local, target: .newProfile(name: "You"),
      origin: .newProfileCreated, consent: .localEnroll, track: .microphone)
    req.isLocalUser = true
    let result = await job.run(req)
    guard case .outcome(let outcome, _) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(outcome, .stored(2))
    let rows = try await fixture.history.database.read { db in
      try Row.fetchAll(db, sql: "SELECT track, consent FROM voice_samples")
    }
    XCTAssertEqual(rows.map { $0["track"] as String }, ["microphone", "microphone"])
    XCTAssertEqual(rows.map { $0["consent"] as String }, ["local_enroll", "local_enroll"])
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known.first?.isLocalUser, true)
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertNil(identities[meeting.local]?.knownSpeakerID, "\"You\" is never linked")
    // A second local profile is refused; the first stands.
    let second = await job.run(req)
    guard case .outcome(let refused, _) = second else { return XCTFail("\(second)") }
    XCTAssertEqual(refused, .failed(.persistenceFailure))
    let count = try await store.knownSpeakers().count
    XCTAssertEqual(count, 1)
  }
}
