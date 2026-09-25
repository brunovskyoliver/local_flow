import GRDB
import XCTest

@testable import LocalFlow

/// The identification scheduler: enrollment ordering, triggers, the bounded queue,
/// cancel, deletion and the past-meeting search (T029, T040, T079).
@MainActor
final class SpeakerIdentificationCoordinatorTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!
  private var store: IdentityStore!
  private var enabled = true
  private var notices: [String] = []
  private var lifecycle: ModelLifecycleCoordinator!
  private var runtime: FakeVoiceEmbeddingRuntime!
  private var factory: FakeVoiceEmbeddingFactory!
  private let identity = IdentificationTestSupport.identity

  override func setUp() async throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
    store = IdentityStore(database: fixture.history.database, identity: identity)
    enabled = true
    notices = []
  }
  override func tearDown() async throws { fixture.cleanup() }

  private static let blocks = 200
  private static let stretchMs = Int64(blocks) * TranscriptMeetingFixture.blockMs

  private func makeCoordinator(
    scripts: [[Float]] = [VoiceVectors.unit(axis: 1)], retryDelay: Duration = .milliseconds(10),
    signalled: Bool = false
  ) -> SpeakerIdentificationCoordinator {
    let runtime = FakeVoiceEmbeddingRuntime(scripts: scripts)
    self.runtime = runtime
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    self.factory = factory
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: { FakeDiarizationRuntime() },
      voiceEmbeddingFactory: { try await factory.make() }, factory: { FakeTranscriptionRuntime() })
    self.lifecycle = lifecycle
    let identifier = MeetingIdentifier(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      clock: FakeMeetingClock())
    let enrollment = EnrollmentJob(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      clock: FakeMeetingClock())
    let coordinator = SpeakerIdentificationCoordinator(
      identifier: identifier, enrollment: enrollment, store: store,
      enabled: { [unowned self] in self.enabled }, retryDelay: retryDelay,
      lifecycle: signalled ? lifecycle : nil)
    coordinator.noticePublished = { [unowned self] in self.notices.append($0) }
    return coordinator
  }

  /// A completed meeting with an accepted diarization run: one local and one remote
  /// cluster with audio behind them.
  private func meeting(startedAt: Int64 = 1_700_000_000_000, light: Bool = false) async throws
    -> (id: UUID, local: UUID, remote: UUID)
  {
    // A light meeting has a few blocks of audio: enough for a run that never reads it.
    let blocks = light ? 4 : Self.blocks
    let created = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(blocks), system: .blocks(blocks))],
      startedAt: startedAt)
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID,
      stretchLengths: [Self.stretchMs])
    return (created.meetingID, result.clusters[0], result.clusters[1])
  }

  private func request(_ meeting: (id: UUID, local: UUID, remote: UUID), name: String)
    -> EnrollmentRequest
  {
    EnrollmentRequest(
      meetingID: meeting.id, rootID: meeting.remote, target: .newProfile(name: name),
      origin: .newProfileCreated, consent: .remember, track: .system)
  }

  private func state(_ id: UUID) async -> MeetingIdentificationState? {
    try? await store.meetingState(meetingID: id)
  }

  // MARK: Enrollment (T029)

  func testEnrollmentRunsQueueOrderedWithItsOwnLeaseAndPublishesEnrollmentDidStore()
    async throws
  {
    let coordinator = makeCoordinator()
    var stored: [(UUID, String)] = []
    coordinator.enrollmentDidStore = { stored.append(($0, $1)) }
    let first = try await meeting()
    let second = try await meeting(startedAt: 1_800_000_000_000)
    let firstRequest = request(first, name: "Tomáš")
    let secondRequest = request(second, name: "Lukáš")
    async let a = coordinator.enroll(firstRequest)
    async let b = coordinator.enroll(secondRequest)
    let outcomes = await [a, b]
    XCTAssertEqual(outcomes, [.stored(1), .stored(1)])
    let names = try await store.knownSpeakers().map(\.name)
    XCTAssertEqual(names, ["Lukáš", "Tomáš"])
    XCTAssertEqual(stored.map(\.1), ["Tomáš", "Lukáš"], "Published once each, in order")
    let made = await factory.makeCount
    XCTAssertEqual(made, 2, "Each job takes and releases its own lease")
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(snapshot.state, .unloaded)
    XCTAssertNil(coordinator.activeMeetingID)
  }

  func testEnrollmentWaitsWhileADiarizationOrSpeechLeaseIsActive() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    let diarization = try await lifecycle.acquire(session: UUID(), workload: .diarization)
    let task = Task { await coordinator.enroll(request(meeting, name: "Tomáš")) }
    try await Task.sleep(for: .milliseconds(60))
    let madeWhileBusy = await factory.makeCount
    XCTAssertEqual(madeWhileBusy, 0, "No embedder while the diarizer is leased")
    let samples = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM voice_samples")
    }
    XCTAssertEqual(samples, 0)
    try await lifecycle.finish(diarization)
    let outcome = await task.value
    XCTAssertEqual(outcome, .stored(1))
    let made = await factory.makeCount
    XCTAssertEqual(made, 1)
  }

  /// A busy enrollment waits for the lease to be released instead of polling on the
  /// fallback timer, so a long diarization does not use up its attempts.
  func testABusyEnrollmentStartsWhenTheModelIsReleased() async throws {
    let coordinator = makeCoordinator(retryDelay: .seconds(60), signalled: true)
    let meeting = try await meeting()
    let diarization = try await lifecycle.acquire(session: UUID(), workload: .diarization)
    let task = Task { await coordinator.enroll(request(meeting, name: "Tomáš")) }
    try await Task.sleep(for: .milliseconds(60))
    let madeWhileBusy = await factory.makeCount
    XCTAssertEqual(madeWhileBusy, 0)
    let started = ContinuousClock.now
    try await lifecycle.finish(diarization)
    let outcome = await task.value
    XCTAssertEqual(outcome, .stored(1))
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "not the 60 s fallback")
  }

  func testTheGlobalSettingOffReturnsDisabledWithoutTouchingTheStore() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    enabled = false
    let outcome = await coordinator.enroll(request(meeting, name: "Tomáš"))
    XCTAssertEqual(outcome, .disabled)
    let known = try await store.knownSpeakers()
    XCTAssertEqual(known, [])
    coordinator.diarizationDidAdopt(meetingID: meeting.id)
    await coordinator.requestRun(meetingID: meeting.id, trigger: .manual)
    try await Task.sleep(for: .milliseconds(30))
    let observed = await state(meeting.id)
    XCTAssertEqual(observed, .notRequested)
    let queued = await coordinator.startPastSearch(knownSpeakerID: UUID())
    XCTAssertEqual(queued, 0)
  }

  func testMeetingWillDeleteCancelsAPendingEnrollmentAndStatusReportsThePhase() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    let other = try await self.meeting(startedAt: 1_800_000_000_000)
    let gate = PreparationGate()
    await runtime.hold(gate)
    await coordinator.observe(meetingID: other.id)
    let running = Task { await coordinator.enroll(request(meeting, name: "Tomáš")) }
    await gate.waitUntilStarted()
    let pending = Task { await coordinator.enroll(request(other, name: "Lukáš")) }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(coordinator.status?.enrolling, true, "Queued for the displayed meeting")
    await coordinator.meetingWillDelete(id: other.id)
    let dropped = await pending.value
    XCTAssertEqual(dropped, .failed(.interrupted))
    XCTAssertNil(coordinator.status, "The deleted meeting's status is gone")
    await gate.open()
    let outcome = await running.value
    XCTAssertEqual(outcome, .stored(1))
    let names = try await store.knownSpeakers().map(\.name)
    XCTAssertEqual(names, ["Tomáš"], "The dropped job never ran")
    let samples = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM voice_samples")
    }
    XCTAssertEqual(samples, 1)
  }

  // MARK: FR-002: adoption hands the waiting summary its settle

  func testDiarizationAdoptSettlesTheSummaryAfterTheRun() async throws {
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator()
    coordinator.intelligence = intelligence
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meeting.id, speakerID: meeting.remote)
      ], consent: .remember, now: 2)
    let gate = PreparationGate()
    await runtime.hold(gate)
    XCTAssertTrue(coordinator.diarizationDidAdopt(meetingID: meeting.id))
    await gate.waitUntilStarted()
    XCTAssertTrue(intelligence.finalized.isEmpty, "the run is in flight; no settle yet")
    await gate.open()
    await DiarizationTestSupport.eventually { await self.state(meeting.id) == .succeeded }
    XCTAssertEqual(intelligence.finalized, [meeting.id])
    await coordinator.shutdown()
  }

  func testDiarizationAdoptReportsNoRunWhenDisabled() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    enabled = false
    XCTAssertFalse(coordinator.diarizationDidAdopt(meetingID: meeting.id))
  }

  func testCancelledIdentificationSettlesTheSummary() async throws {
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator()
    coordinator.intelligence = intelligence
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meeting.id, speakerID: meeting.remote)
      ], consent: .remember, now: 2)
    let gate = PreparationGate()
    await runtime.hold(gate)
    XCTAssertTrue(coordinator.diarizationDidAdopt(meetingID: meeting.id))
    await gate.waitUntilStarted()
    let cancelling = Task { await coordinator.cancel(meetingID: meeting.id) }
    await DiarizationTestSupport.eventually { intelligence.finalized == [meeting.id] }
    await gate.open()
    await cancelling.value
    await coordinator.shutdown()
  }

  // MARK: Runs (T040)

  func testDiarizationDidAdoptEnqueuesAnAutomaticRunOnlyAfterTheLeaseFinished() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meeting.id, speakerID: meeting.remote)
      ], consent: .remember, now: 2)
    // A diarization lease is still held: the run is admitted but waits.
    let diarization = try await lifecycle.acquire(session: UUID(), workload: .diarization)
    coordinator.diarizationDidAdopt(meetingID: meeting.id)
    try await Task.sleep(for: .milliseconds(60))
    let made = await factory.makeCount
    XCTAssertEqual(made, 0)
    let observed = await state(meeting.id)
    XCTAssertEqual(observed, .pending)
    try await lifecycle.finish(diarization)
    await DiarizationTestSupport.eventually { await self.state(meeting.id) == .succeeded }
    let identities = try await store.identities(meetingID: meeting.id)
    XCTAssertEqual(identities[meeting.remote]?.state, .possible, "One sample: support below 2")
    XCTAssertEqual(identities[meeting.remote]?.knownSpeakerName, "Tomáš")
  }

  /// A profile with a sample, so runs need the model and wait while it is busy.
  private func profile(sourcedFrom meeting: (id: UUID, local: UUID, remote: UUID)) async throws
    -> KnownSpeakerRow
  {
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meeting.id, speakerID: meeting.remote)
      ], consent: .remember, now: 2)
    return tomas
  }

  func testTheQueueDeduplicatesHoldsAHundredAndReportsOverflow() async throws {
    let coordinator = makeCoordinator()
    let source = try await meeting(startedAt: 1_600_000_000_000)
    _ = try await profile(sourcedFrom: source)
    let lease = try await lifecycle.acquire(session: UUID())
    var ids: [UUID] = []
    for index in 0..<SpeakerIdentificationCoordinator.queueCapacity {
      let meeting = try await self.meeting(
        startedAt: 1_700_000_000_000 + Int64(index), light: true)
      ids.append(meeting.id)
    }
    for id in ids { await coordinator.requestRun(meetingID: id, trigger: .manual) }
    await coordinator.requestRun(meetingID: ids[0], trigger: .manual)
    // One run may have started and is waiting on the busy model.
    XCTAssertGreaterThanOrEqual(coordinator.queuedCount, ids.count - 1)
    let extra = try await meeting(startedAt: 1_900_000_000_000, light: true)
    await coordinator.requestRun(meetingID: extra.id, trigger: .manual)
    XCTAssertEqual(notices.last, SpeakerIdentificationCoordinator.queueFullNotice)
    let extraState = await state(extra.id)
    XCTAssertEqual(extraState, .notRequested, "Refused before admission")
    notices = []
    coordinator.diarizationDidAdopt(meetingID: extra.id)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(notices.last, SpeakerIdentificationCoordinator.queueFullNotice)
    await coordinator.cancel(meetingID: ids[1])
    XCTAssertLessThan(coordinator.queuedCount, ids.count)
    let cancelledState = await state(ids[1])
    XCTAssertEqual(cancelledState, .notRequested, "Cancel deletes the run row")
    await lifecycle.cancelAndJoin(lease)
    await coordinator.shutdown()
  }

  func testOneRunAtATimeWithProgressAndCancelDeletesTheRunRow() async throws {
    let coordinator = makeCoordinator()
    let meeting = try await meeting()
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meeting.id, speakerID: meeting.remote)
      ], consent: .remember, now: 2)
    let gate = PreparationGate()
    await runtime.hold(gate)
    await coordinator.observe(meetingID: meeting.id)
    await coordinator.requestRun(meetingID: meeting.id, trigger: .manual)
    await gate.waitUntilStarted()
    XCTAssertEqual(coordinator.activeMeetingID, meeting.id)
    XCTAssertEqual(coordinator.status?.state, .running)
    XCTAssertEqual(coordinator.status?.progress, 0, "0 of 1 region done")
    // Cancel joins the in-flight region, which the gate releases (like Core ML would).
    let cancelling = Task { await coordinator.cancel(meetingID: meeting.id) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    await cancelling.value
    await DiarizationTestSupport.eventually { coordinator.activeMeetingID == nil }
    let observed = await state(meeting.id)
    XCTAssertEqual(observed, .notRequested)
    let runs = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM identification_runs")
    }
    XCTAssertEqual(runs, 0)
    let unloaded = await lifecycle.state
    XCTAssertEqual(unloaded, .unloaded)
  }

  // MARK: Past search (T079)

  func testPastSearchQueuesOnlyMeetingsWithUnknownRootsNewestFirstOneAtATime() async throws {
    let coordinator = makeCoordinator()
    var meetings: [(id: UUID, local: UUID, remote: UUID)] = []
    for index in 0..<3 {
      meetings.append(try await meeting(startedAt: 1_700_000_000_000 + Int64(index) * 1_000))
    }
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await store.addSamples(
      knownSpeakerID: tomas.id,
      drafts: (0..<3).map {
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: meetings[0].id,
          speakerID: meetings[0].remote, startMs: Int64($0) * 9_000,
          endMs: Int64($0) * 9_000 + 8_000)
      }, consent: .remember, now: 2)
    // Meeting 1 already has a confirmed remote root: skipped at admission.
    try await store.link(
      meetingID: meetings[1].id, speakerID: meetings[1].remote, to: tomas.id,
      origin: .userConfirmation, now: 3)
    await coordinator.observe(meetingID: meetings[2].id)
    let queued = await coordinator.startPastSearch(knownSpeakerID: tomas.id)
    XCTAssertEqual(queued, 2)
    XCTAssertEqual(coordinator.status?.pastSearch?.name, "Tomáš")
    await DiarizationTestSupport.eventually {
      let newest = await self.state(meetings[2].id)
      let oldest = await self.state(meetings[0].id)
      return newest == .succeeded && oldest == .succeeded
    }
    let skipped = await state(meetings[1].id)
    XCTAssertEqual(skipped, .notRequested, "No Unknown remote root: nothing admitted")
    let run = try await store.latestRun(meetingID: meetings[2].id)
    XCTAssertEqual(run?.trigger, .pastSearch)
    let identities = try await store.identities(meetingID: meetings[2].id)
    XCTAssertEqual(identities[meetings[2].remote]?.state, .recognized)
    await DiarizationTestSupport.eventually { coordinator.status?.pastSearch == nil }
    XCTAssertEqual(coordinator.pastSearchRemaining, 0)
  }

  func testCancelPastSearchDropsTheQueueAndItIsMemoryOnly() async throws {
    let coordinator = makeCoordinator()
    var meetings: [UUID] = []
    for index in 0..<3 {
      let light = try await meeting(
        startedAt: 1_700_000_000_000 + Int64(index) * 1_000, light: true)
      meetings.append(light.id)
    }
    let source = try await meeting(startedAt: 1_600_000_000_000, light: true)
    let tomas = try await profile(sourcedFrom: source)
    let lease = try await lifecycle.acquire(session: UUID())
    let queued = await coordinator.startPastSearch(knownSpeakerID: tomas.id)
    XCTAssertEqual(queued, 4)
    try await Task.sleep(for: .milliseconds(20))
    coordinator.cancelPastSearch()
    XCTAssertEqual(coordinator.pastSearchRemaining, 0)
    await lifecycle.cancelAndJoin(lease)
    await coordinator.shutdown()
    // A relaunch starts with an empty past-search queue: only `pending` runs resume.
    let relaunched = makeCoordinator()
    XCTAssertEqual(relaunched.pastSearchRemaining, 0)
    let active = try await store.activeRuns(limit: 10)
    XCTAssertLessThanOrEqual(active.count, 1, "At most the run that was in flight")
  }

  // MARK: T078 — evidence-change notice

  /// Confirmations, corrections, adopted results and enrollments all funnel
  /// through `identitiesDidChange`; the observer hears it exactly once with
  /// the meeting id.
  func testIdentitiesDidChangeNotifiesEvidenceDidChangeOnce() async throws {
    let coordinator = makeCoordinator()
    let observer = FakeIntelligenceObserver()
    coordinator.intelligence = observer
    let id = UUID()

    coordinator.identitiesDidChange(meetingID: id)

    XCTAssertEqual(observer.evidenceChanges, [id])
  }
}
