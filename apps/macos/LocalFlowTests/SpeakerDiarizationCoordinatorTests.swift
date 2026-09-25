import GRDB
import XCTest

@testable import LocalFlow

@MainActor
final class SpeakerDiarizationCoordinatorTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!
  private var automatic = true
  private var installed = true
  private var notices: [String] = []
  private var lifecycle: ModelLifecycleCoordinator!

  override func setUp() async throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
    automatic = true
    installed = true
    notices = []
  }
  override func tearDown() async throws { fixture.cleanup() }

  private func makeCoordinator(
    _ runtime: FakeDiarizationRuntime = FakeDiarizationRuntime(),
    retryDelay: Duration = .milliseconds(10), signalled: Bool = false,
    speechBuilds: Counter? = nil
  ) -> SpeakerDiarizationCoordinator {
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: { runtime },
      factory: {
        await speechBuilds?.increment()
        return FakeTranscriptionRuntime()
      })
    self.lifecycle = lifecycle
    let diarizer = MeetingDiarizer(
      speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: DiarizationTestSupport.identity,
      clock: FakeMeetingClock())
    let coordinator = SpeakerDiarizationCoordinator(
      diarizer: diarizer, store: speakers, automaticEnabled: { [unowned self] in self.automatic },
      modelInstalled: { [unowned self] in self.installed }, retryDelay: retryDelay,
      lifecycle: signalled ? lifecycle : nil)
    coordinator.noticePublished = { [unowned self] in self.notices.append($0) }
    return coordinator
  }

  /// A completed meeting with a final transcript, ready to diarize.
  private func finalMeeting(startedAt: Int64 = 1_700_000_000_000) async throws -> UUID {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], startedAt: startedAt)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100)])
    return meeting.meetingID
  }

  private func state(_ id: UUID) async -> MeetingDiarizationState? {
    try? await speakers.meetingState(meetingID: id)
  }

  func testAutomaticRunOnlyAfterFinalAndWhenEnabledAndInstalled() async throws {
    let coordinator = makeCoordinator()
    // A transcript that is not final yet: nothing is admitted.
    let early = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    coordinator.meetingTranscriptDidFinalize(id: early.meetingID, echoProfile: nil)
    try await Task.sleep(for: .milliseconds(50))
    let observed1 = await state(early.meetingID)
    XCTAssertEqual(observed1, .notRequested)

    let id = try await finalMeeting(startedAt: 1_800_000_000_000)
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await DiarizationTestSupport.eventually { await self.state(id) == .succeeded }

    automatic = false
    let off = try await finalMeeting(startedAt: 1_900_000_000_000)
    coordinator.meetingTranscriptDidFinalize(id: off, echoProfile: nil)
    automatic = true
    installed = false
    let missing = try await finalMeeting(startedAt: 2_000_000_000_000)
    coordinator.meetingTranscriptDidFinalize(id: missing, echoProfile: nil)
    try await Task.sleep(for: .milliseconds(50))
    let observed2 = await state(off)
    XCTAssertEqual(observed2, .notRequested)
    let observed3 = await state(missing)
    XCTAssertEqual(observed3, .notRequested)

    // Label speakers is always available, whatever the preference or install state.
    automatic = false
    await coordinator.requestRun(meetingID: off, revision: nil, trigger: .manual)
    await DiarizationTestSupport.eventually { await self.state(off) != .pending }
    await DiarizationTestSupport.eventually { await self.state(off) != .running }
    let observed4 = await state(off)
    XCTAssertNotEqual(observed4, .notRequested)
  }

  func testOneRunAtATimeAndTheQueueIsBoundedAndDeduplicated() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let first = try await finalMeeting()
    let second = try await finalMeeting(startedAt: 1_800_000_000_000)
    await coordinator.requestRun(meetingID: first, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    await coordinator.requestRun(meetingID: second, revision: nil, trigger: .manual)
    await coordinator.requestRun(meetingID: second, revision: nil, trigger: .manual)
    XCTAssertEqual(coordinator.activeMeetingID, first)
    XCTAssertEqual(coordinator.queuedCount, 1)
    let observed5 = await state(second)
    XCTAssertEqual(observed5, .pending)

    // Fill the queue to 100 with already-pending ids.
    coordinator.resume((0..<150).map { _ in UUID() })
    XCTAssertEqual(coordinator.queuedCount, SpeakerDiarizationCoordinator.queueCapacity)
    let overflowAuto = try await finalMeeting(startedAt: 1_900_000_000_000)
    coordinator.meetingTranscriptDidFinalize(id: overflowAuto, echoProfile: nil)
    try await Task.sleep(for: .milliseconds(50))
    let observed6 = await state(overflowAuto)
    XCTAssertEqual(observed6, .notRequested)
    XCTAssertTrue(notices.isEmpty)
    await coordinator.requestRun(meetingID: overflowAuto, revision: nil, trigger: .manual)
    XCTAssertEqual(notices, ["Speaker labeling queue is full"])
    let observed7 = await state(overflowAuto)
    XCTAssertEqual(observed7, .notRequested)

    await gate.open()
    await coordinator.shutdown()
  }

  func testMeetingWillDeleteCancelsJoinsAndLeavesNoRunRows() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    let observed8 = await state(id)
    XCTAssertEqual(observed8, .running)
    // The in-flight window ignores cancellation; deletion joins it.
    let deletion = Task { await coordinator.meetingWillDelete(id: id) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    await deletion.value
    XCTAssertNil(coordinator.activeMeetingID)
    let runs = try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM diarization_runs WHERE meeting_id=?",
        arguments: [id.uuidString]) ?? 0
    }
    XCTAssertEqual(runs, 0)
  }

  func testCancelRemovesAPendingRun() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let first = try await finalMeeting()
    let second = try await finalMeeting(startedAt: 1_800_000_000_000)
    await coordinator.requestRun(meetingID: first, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    await coordinator.requestRun(meetingID: second, revision: nil, trigger: .manual)
    await coordinator.cancel(meetingID: second)
    XCTAssertEqual(coordinator.queuedCount, 0)
    let observed9 = await state(second)
    XCTAssertEqual(observed9, .notRequested)
    await gate.open()
    await coordinator.shutdown()
  }

  // MARK: US6 — retry, preemption, re-enqueue, in-room and stale results (T063)

  /// The store and, when it observes `id`, the coordinator's status have settled.
  private func settled(_ id: UUID, _ coordinator: SpeakerDiarizationCoordinator) async {
    await DiarizationTestSupport.eventually {
      let state = await self.state(id)
      guard state != .pending && state != .running else { return false }
      guard coordinator.status?.meetingID == id else { return true }
      return coordinator.status?.state == state
    }
  }

  func testRetryAfterAFailureOrAnInterruptionCreatesANewPendingRun() async throws {
    let runtime = FakeDiarizationRuntime()
    await runtime.failWindow(1)
    let coordinator = makeCoordinator(runtime)
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await settled(id, coordinator)
    let failed = try await speakers.latestRun(meetingID: id)
    XCTAssertEqual(failed?.state, .failed)
    XCTAssertEqual(failed?.failureCategory, .runtimeFailure)
    await coordinator.observe(meetingID: id)
    XCTAssertEqual(coordinator.status?.state, .failed)
    XCTAssertEqual(coordinator.status?.failure, .runtimeFailure)
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .retry)
    await settled(id, coordinator)
    let retried = try await speakers.latestRun(meetingID: id)
    XCTAssertNotEqual(retried?.id, failed?.id)
    XCTAssertEqual(retried?.trigger, .retry)
    XCTAssertEqual(retried?.state, .succeeded)
    XCTAssertEqual(coordinator.status?.state, .succeeded)
    XCTAssertNil(coordinator.status?.failure)
    // An interrupted run (a crash, reconciled at launch) retries the same way.
    // The fake clock stands still, so `latestRun` breaks the tie by insertion order.
    let later: Int64 = 1_700_000_000_000
    let interrupted = try await speakers.admit(
      meetingID: id, transcriptPassID: try XCTUnwrap(retried?.transcriptPassID), trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: later)
    _ = try await speakers.start(runID: interrupted.id, now: later + 1)
    try await speakers.interrupt(runID: interrupted.id, now: later + 2)
    await coordinator.observe(meetingID: id)
    XCTAssertEqual(coordinator.status?.state, .interrupted)
    XCTAssertEqual(coordinator.status?.failure, .interrupted)
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .retry)
    await settled(id, coordinator)
    let again = try await speakers.latestRun(meetingID: id)
    XCTAssertEqual(again?.state, .succeeded)
    XCTAssertNotEqual(again?.id, interrupted.id)
    XCTAssertEqual(coordinator.status?.state, .succeeded)
  }

  func testAPreemptedRunReturnsToTheQueueHeadAndResumesWhenTheModelIsFree() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let first = try await finalMeeting()
    let second = try await finalMeeting(startedAt: 1_800_000_000_000)
    await coordinator.requestRun(meetingID: first, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    await coordinator.requestRun(meetingID: second, revision: nil, trigger: .manual)
    XCTAssertEqual(coordinator.queuedCount, 1)
    // Speech recognition takes the model mid-window.
    let lifecycle = try XCTUnwrap(lifecycle)
    let speech = Task { try await lifecycle.acquire(session: UUID(), workload: .speechRecognition) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    let lease = try await speech.value
    await DiarizationTestSupport.eventually { coordinator.activeMeetingID == nil }
    let requeued = try await speakers.latestRun(meetingID: first)
    XCTAssertEqual(requeued?.state, .pending)
    XCTAssertEqual(requeued?.preemptionCount, 1)
    XCTAssertEqual(coordinator.queuedCount, 2, "back at the head, ahead of the second meeting")
    let firstState = await state(first)
    XCTAssertEqual(firstState, .pending)
    // While speech recognition holds the lease, the retry loop keeps both pending.
    try await Task.sleep(for: .milliseconds(60))
    let stillPending = await state(first)
    XCTAssertEqual(stillPending, .pending)
    try await lifecycle.finish(lease)
    await lifecycle.cancelSessionAndJoin(lease.sessionID)
    await settled(first, coordinator)
    await settled(second, coordinator)
    let resumed = try await speakers.latestRun(meetingID: first)
    XCTAssertEqual(resumed?.id, requeued?.id, "the same run resumes")
    XCTAssertEqual(resumed?.state, .succeeded)
    let secondRun = try await speakers.latestRun(meetingID: second)
    XCTAssertEqual(secondRun?.state, .succeeded)
    await coordinator.shutdown()
  }

  /// A busy run waits for the lease to be released, not for the fallback timer.
  func testABusyRunStartsWhenTheModelIsReleasedNotOnATimer() async throws {
    let coordinator = makeCoordinator(retryDelay: .seconds(60), signalled: true)
    let id = try await finalMeeting()
    let lifecycle = try XCTUnwrap(lifecycle)
    let speech = try await lifecycle.acquire(session: UUID(), workload: .speechRecognition)
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await DiarizationTestSupport.eventually {
      coordinator.queuedCount == 1 && coordinator.activeMeetingID == nil
    }
    let pending = await state(id)
    XCTAssertEqual(pending, .pending)
    try await lifecycle.finish(speech)
    await settled(id, coordinator)
    let done = await state(id)
    XCTAssertEqual(done, .succeeded, "started on release, a minute before the fallback")
    await coordinator.shutdown()
  }

  /// Keep model ready does not reload live speech between queued runs; it reloads
  /// once the queue is empty.
  func testKeepModelReadyWaitsForTheQueueToDrain() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let builds = Counter()
    let coordinator = makeCoordinator(runtime, signalled: true, speechBuilds: builds)
    let lifecycle = try XCTUnwrap(lifecycle)
    await lifecycle.setKeepLoaded(true)
    let first = try await finalMeeting()
    let second = try await finalMeeting(startedAt: 1_800_000_000_000)
    await coordinator.requestRun(meetingID: first, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    await coordinator.requestRun(meetingID: second, revision: nil, trigger: .manual)
    await gate.open()
    await settled(first, coordinator)
    await settled(second, coordinator)
    await DiarizationTestSupport.eventually { await lifecycle.snapshot().loaded }
    let count = await builds.value
    XCTAssertEqual(count, 1, "one reload after both runs, none between them")
    await lifecycle.setKeepLoaded(false)
    await coordinator.shutdown()
  }

  /// A run that finds the model busy goes back to the queue with the finalization
  /// pass's echo profile, so its retry does not decode both tracks again.
  func testABusyRunKeepsTheHandedEchoProfileForItsRetry() async throws {
    let coordinator = makeCoordinator(retryDelay: .seconds(60))
    let id = try await finalMeeting()
    let lifecycle = try XCTUnwrap(lifecycle)
    let speech = try await lifecycle.acquire(session: UUID(), workload: .speechRecognition)
    var profile = EchoGate.Profile()
    profile.stretches[0] = .init(baseMs: 0, microphone: [-20, -30], system: [-25, -35])
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: profile)
    await DiarizationTestSupport.eventually {
      coordinator.queuedCount == 1 && coordinator.activeMeetingID == nil
    }
    // Past the one attempt; the next is a minute away.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(coordinator.queuedCount, 1, "back at the head of the queue")
    XCTAssertNil(coordinator.activeMeetingID)
    let pending = await state(id)
    XCTAssertEqual(pending, .pending)
    XCTAssertEqual(coordinator.echoProfileMeetingIDs, [id], "the profile waits for the retry")
    try await lifecycle.finish(speech)
    await coordinator.meetingWillDelete(id: id)
    XCTAssertTrue(coordinator.echoProfileMeetingIDs.isEmpty)
    await coordinator.shutdown()
  }

  func testATranscriptChangeReEnqueuesAutomaticallyWhenEnabled() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    let oldRow = try await transcripts.transcription(meetingID: id)
    try await transcripts.discardPass(meetingID: id, passID: try XCTUnwrap(oldRow?.passID))
    let newPass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: id, segments: [(0, 100)])
    await gate.open()
    // The failure and the automatic re-admission are two steps; wait for the second.
    await DiarizationTestSupport.eventually {
      let latest = (try? await self.speakers.latestRun(meetingID: id)) ?? nil
      return latest?.trigger == .automatic && latest?.state == .succeeded
    }
    let rerun = try await speakers.latestRun(meetingID: id)
    XCTAssertEqual(rerun?.state, .succeeded)
    XCTAssertEqual(rerun?.trigger, .automatic)
    XCTAssertEqual(rerun?.transcriptPassID, newPass)
    let failed = try await fixture.history.database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT failure_category FROM diarization_runs WHERE meeting_id=? AND state='failed'",
        arguments: [id.uuidString])
    }
    XCTAssertEqual(failed, ["transcript_changed"])
    // With automatic labeling off, the failure stands until the user asks again.
    automatic = false
    let other = try await finalMeeting(startedAt: 1_800_000_000_000)
    let secondGate = PreparationGate()
    await runtime.hold(secondGate)
    await coordinator.requestRun(meetingID: other, revision: nil, trigger: .manual)
    await secondGate.waitUntilStarted()
    let otherRow = try await transcripts.transcription(meetingID: other)
    try await transcripts.discardPass(meetingID: other, passID: try XCTUnwrap(otherRow?.passID))
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: other, segments: [(0, 100)])
    await secondGate.open()
    await settled(other, coordinator)
    let stands = try await speakers.latestRun(meetingID: other)
    XCTAssertEqual(stands?.state, .failed)
    XCTAssertEqual(stands?.failureCategory, .transcriptChanged)
  }

  func testTheInRoomToggleUpdatesTheSnapshotAndAdmitsAnInRoomChangeRun() async throws {
    let runtime = FakeDiarizationRuntime()
    let coordinator = makeCoordinator(runtime)
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await settled(id, coordinator)
    await coordinator.observe(meetingID: id)
    XCTAssertEqual(coordinator.status?.inRoom, false)
    let before = await runtime.requests
    XCTAssertEqual(before.map(\.numSpeakers), [nil, 1], "the microphone is one speaker")
    await coordinator.setInRoom(meetingID: id, inRoom: true)
    XCTAssertEqual(coordinator.status?.inRoom, true)
    await settled(id, coordinator)
    let row = try await speakers.diarization(meetingID: id)
    XCTAssertEqual(row?.inRoom, true)
    let rerun = try await speakers.latestRun(meetingID: id)
    XCTAssertEqual(rerun?.trigger, .inRoomChange)
    XCTAssertEqual(rerun?.inRoom, true)
    XCTAssertEqual(rerun?.state, .succeeded)
    let after = await runtime.requests
    XCTAssertEqual(after.map(\.numSpeakers), [nil, 1, nil, nil], "the microphone is unconstrained")
    XCTAssertEqual(coordinator.status?.state, .succeeded)
  }

  func testCancelWhileRunningJoinsAndDeletesTheRun() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let coordinator = makeCoordinator(runtime)
    let id = try await finalMeeting()
    await coordinator.observe(meetingID: id)
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    await DiarizationTestSupport.eventually { coordinator.status?.state == .running }
    XCTAssertEqual(coordinator.status?.progress, 0, "0% from the first window on")
    let cancelling = Task { await coordinator.cancel(meetingID: id) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    await cancelling.value
    XCTAssertNil(coordinator.activeMeetingID)
    let observed = await state(id)
    XCTAssertEqual(observed, .notRequested)
    XCTAssertEqual(coordinator.status?.state, .notRequested)
    let runs = try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM diarization_runs WHERE meeting_id=?",
        arguments: [id.uuidString]) ?? 0
    }
    XCTAssertEqual(runs, 0)
  }

  func testAReFinalizedPassHidesTheStaleResultAndEnqueuesAnAutomaticRun() async throws {
    let coordinator = makeCoordinator()
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await settled(id, coordinator)
    let shown = try await transcripts.acceptedSpeakers(meetingID: id)
    XCTAssertNotNil(shown)
    // Re-transcribe: the new pass is pending, then final.
    let oldRow = try await transcripts.transcription(meetingID: id)
    try await transcripts.discardPass(meetingID: id, passID: try XCTUnwrap(oldRow?.passID))
    let newPass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: id, segments: [(0, 100)])
    let hidden = try await transcripts.acceptedSpeakers(meetingID: id)
    XCTAssertNil(hidden, "a result for another pass is not shown")
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await DiarizationTestSupport.eventually {
      let latest = (try? await self.speakers.latestRun(meetingID: id)) ?? nil
      return latest?.transcriptPassID == newPass
    }
    await settled(id, coordinator)
    let rerun = try await speakers.latestRun(meetingID: id)
    let debugRuns = try await fixture.history.database.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT id, state, \"trigger\", created_at, failure_category FROM diarization_runs WHERE meeting_id=? ORDER BY rowid",
        arguments: [id.uuidString]
      ).map(\.description)
    }
    print("DEBUG runs", debugRuns, notices)
    XCTAssertEqual(rerun?.state, .succeeded)
    XCTAssertEqual(rerun?.trigger, .automatic)
    let visible = try await transcripts.acceptedSpeakers(meetingID: id)
    XCTAssertEqual(visible?.runID, rerun?.id)
  }

  // MARK: FR-002: the automatic summary waits for speaker work to settle

  func testAutomaticSummaryWaitsForTheRunToFinish() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator(runtime)
    coordinator.intelligence = intelligence
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await gate.waitUntilStarted()
    XCTAssertTrue(intelligence.finalized.isEmpty, "the run is in flight; no settle yet")
    await gate.open()
    await DiarizationTestSupport.eventually { await self.state(id) == .succeeded }
    XCTAssertEqual(intelligence.finalized, [id])
    await coordinator.shutdown()
  }

  func testAutomaticSummarySettlesAtOnceWhenLabelingIsOff() async throws {
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator()
    coordinator.intelligence = intelligence
    automatic = false
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    XCTAssertEqual(intelligence.finalized, [id])
    let observed = await state(id)
    XCTAssertEqual(observed, .notRequested)
  }

  func testAutomaticSummarySettlesWhenTheModelIsMissing() async throws {
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator()
    coordinator.intelligence = intelligence
    installed = false
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await DiarizationTestSupport.eventually { intelligence.finalized == [id] }
    let observed = await state(id)
    XCTAssertEqual(observed, .notRequested)
  }

  func testAutomaticSummarySettlesWhenLabelingFails() async throws {
    let runtime = FakeDiarizationRuntime()
    await runtime.failWindow(1)
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator(runtime)
    coordinator.intelligence = intelligence
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await DiarizationTestSupport.eventually { await self.state(id) == .failed }
    XCTAssertEqual(intelligence.finalized, [id])
    await coordinator.shutdown()
  }

  func testAutomaticSummarySettlesWhenLabelingIsCancelled() async throws {
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator(runtime)
    coordinator.intelligence = intelligence
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await gate.waitUntilStarted()
    let cancelTask = Task { await coordinator.cancel(meetingID: id) }
    await DiarizationTestSupport.eventually { intelligence.finalized == [id] }
    await gate.open()
    await cancelTask.value
    await coordinator.shutdown()
  }

  func testResumedRunsSettleTheSummary() async throws {
    let intelligence = FakeIntelligenceObserver()
    let coordinator = makeCoordinator()
    coordinator.intelligence = intelligence
    let id = try await finalMeeting()
    // A pending run left over from before the relaunch.
    let diarizer = MeetingDiarizer(
      speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: DiarizationTestSupport.identity,
      clock: FakeMeetingClock())
    let pending = try await diarizer.admit(
      meetingID: id, trigger: .automatic, expectedRevision: nil)
    XCTAssertEqual(pending.state, .pending)
    coordinator.resume([id])
    await DiarizationTestSupport.eventually { await self.state(id) == .succeeded }
    XCTAssertEqual(intelligence.finalized, [id])
    await coordinator.shutdown()
  }

  // MARK: Feature 010 (T041): adoption is published after the lease finished

  @MainActor
  private final class ObservingIdentification: IdentificationObserving {
    var adopted: [UUID] = []
    var leasedAtAdoption: [Bool] = []
    var acceptedAtAdoption: [UUID?] = []
    let lifecycle: ModelLifecycleCoordinator
    let store: SpeakerStore
    init(lifecycle: ModelLifecycleCoordinator, store: SpeakerStore) {
      self.lifecycle = lifecycle
      self.store = store
    }
    func diarizationDidAdopt(meetingID: UUID) -> Bool {
      adopted.append(meetingID)
      Task {
        let snapshot = await lifecycle.snapshot()
        let accepted = try? await store.diarization(meetingID: meetingID)?.acceptedRunID
        await MainActor.run {
          leasedAtAdoption.append(snapshot.leased)
          acceptedAtAdoption.append(accepted)
        }
      }
      return false
    }
    func meetingWillDelete(id: UUID) async {}
  }

  func testDiarizationDidAdoptIsPublishedAfterTheLeaseFinishedAndNotOnFailureOrCancel()
    async throws
  {
    let runtime = FakeDiarizationRuntime(scripts: [DiarizationScripts.window([(0, 0, 0.1)])])
    let coordinator = makeCoordinator(runtime)
    let observer = ObservingIdentification(lifecycle: lifecycle, store: speakers)
    coordinator.identification = observer
    let id = try await finalMeeting()
    await coordinator.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await settled(id, coordinator)
    await DiarizationTestSupport.eventually { observer.leasedAtAdoption.count == 1 }
    XCTAssertEqual(observer.adopted, [id])
    XCTAssertEqual(observer.leasedAtAdoption, [false], "The diarizer's lease had finished")
    let accepted = try await speakers.diarization(meetingID: id)?.acceptedRunID
    XCTAssertNotNil(accepted)
    XCTAssertEqual(observer.acceptedAtAdoption, [accepted], "Adoption had committed")
    // A failed run publishes nothing.
    await runtime.failWindow(3)
    let failing = try await finalMeeting(startedAt: 1_800_000_000_000)
    await coordinator.requestRun(meetingID: failing, revision: nil, trigger: .manual)
    await settled(failing, coordinator)
    let failed = await state(failing)
    XCTAssertEqual(failed, .failed)
    XCTAssertEqual(observer.adopted, [id])
    // A cancelled run publishes nothing.
    let gate = PreparationGate()
    await runtime.hold(gate)
    let cancelled = try await finalMeeting(startedAt: 1_900_000_000_000)
    await coordinator.requestRun(meetingID: cancelled, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    let cancelling = Task { await coordinator.cancel(meetingID: cancelled) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    await cancelling.value
    await settled(cancelled, coordinator)
    XCTAssertEqual(observer.adopted, [id])
  }

  // MARK: T078 — evidence-change notice

  /// A manual segment assignment is an evidence write: the observer hears it
  /// exactly once with the meeting id.
  func testCorrectSegmentNotifiesEvidenceDidChangeOnce() async throws {
    let coordinator = makeCoordinator()
    let observer = FakeIntelligenceObserver()
    coordinator.intelligence = observer
    let id = try await finalMeeting()
    coordinator.meetingTranscriptDidFinalize(id: id, echoProfile: nil)
    await DiarizationTestSupport.eventually { await self.state(id) == .succeeded }
    let rows = try await transcripts.page(
      meetingID: id, finality: .final, after: nil, limit: 10)
    let segment = try XCTUnwrap(rows.first?.id)
    let before = observer.evidenceChanges.count

    let corrected = await coordinator.correctSegment(
      meetingID: id, segmentID: segment, to: .newSpeaker)
    XCTAssertTrue(corrected)
    XCTAssertEqual(observer.evidenceChanges.count, before + 1)
    XCTAssertEqual(observer.evidenceChanges.last, id)
  }
}
