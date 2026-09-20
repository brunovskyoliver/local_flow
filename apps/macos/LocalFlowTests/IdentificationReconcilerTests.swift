import GRDB
import XCTest

@testable import LocalFlow

/// Launch reconciliation of identification runs (T080): the reconciler takes only a
/// store and a clock, so it cannot read audio.
@MainActor
final class IdentificationReconcilerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!
  private var store: IdentityStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
    store = IdentityStore(
      database: fixture.history.database, identity: IdentificationTestSupport.identity)
  }
  override func tearDown() { fixture.cleanup() }

  private func meeting(startedAt: Int64) async throws -> (id: UUID, remote: UUID) {
    let created = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], startedAt: startedAt)
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID)
    return (created.meetingID, result.clusters[1])
  }

  private func admit(_ meetingID: UUID, now: Int64) async throws -> IdentificationRun {
    try await store.admit(
      meetingID: meetingID, trigger: .automatic, identity: IdentificationTestSupport.identity,
      policy: "tiers_v1@wespeaker_resnet34lm_256/11111111", now: now)
  }

  private func count(_ table: String, run: UUID) throws -> Int {
    try fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM \(table) WHERE run_id=?", arguments: [run.uuidString]) ?? 0
    }
  }

  func testRunningIsInterruptedWithItsCandidatesGonePendingResumesAndAssignmentsStay()
    async throws
  {
    let interruptedMeeting = try await meeting(startedAt: 1_700_000_000_000)
    let tomas = try await store.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    let accepted = try await admit(interruptedMeeting.id, now: 10)
    _ = try await store.start(runID: accepted.id, now: 11)
    let candidate = IdentityMatcher.Candidate(
      knownSpeakerID: tomas.id, score: 0.9, tier: .recognized, reasons: [], sampleCount: 3,
      supportCount: 3)
    try await store.appendCandidates(
      runID: accepted.id,
      rows: [
        .init(
          meetingSpeakerID: interruptedMeeting.remote, knownSpeakerID: tomas.id, score: 0.9,
          tier: .recognized, reasons: [], sampleCount: 3, supportCount: 3)
      ])
    _ = try await store.complete(
      runID: accepted.id,
      decisions: [
        interruptedMeeting.remote: .init(
          state: .recognized, best: candidate, second: nil, candidates: [candidate])
      ], now: 12)
    let running = try await admit(interruptedMeeting.id, now: 30)
    _ = try await store.start(runID: running.id, now: 31)
    try await store.appendCandidates(
      runID: running.id,
      rows: [
        .init(
          meetingSpeakerID: interruptedMeeting.remote, knownSpeakerID: tomas.id, score: 0.4,
          tier: .below, reasons: [.belowMedium], sampleCount: 3, supportCount: 0)
      ])
    let pendingMeeting = try await meeting(startedAt: 1_800_000_000_000)
    _ = try await admit(pendingMeeting.id, now: 40)
    let assignmentsBefore = try IdentificationTestSupport.digest(
      fixture.history.database, tables: ["identity_assignments"])

    let summary = await IdentificationReconciler(store: store, clock: FakeMeetingClock()).run()

    XCTAssertEqual(summary.found, 2)
    XCTAssertEqual(summary.interrupted, 1)
    XCTAssertEqual(summary.resume, [pendingMeeting.id])
    let interrupted = try await store.run(id: running.id)
    XCTAssertEqual(interrupted?.state, .interrupted)
    XCTAssertEqual(interrupted?.failureCategory, .interrupted)
    XCTAssertEqual(try count("match_candidates", run: running.id), 0)
    XCTAssertEqual(
      try count("match_candidates", run: accepted.id), 1, "The accepted run keeps its rows")
    let assignmentsAfter = try IdentificationTestSupport.digest(
      fixture.history.database, tables: ["identity_assignments"])
    XCTAssertEqual(assignmentsAfter, assignmentsBefore)
    let row = try await store.identification(meetingID: interruptedMeeting.id)
    XCTAssertEqual(row?.acceptedRunID, accepted.id)
    XCTAssertNil(row?.currentRunID)
    let state = try await store.meetingState(meetingID: interruptedMeeting.id)
    XCTAssertEqual(state, .interrupted)
    let stillPending = try await store.meetingState(meetingID: pendingMeeting.id)
    XCTAssertEqual(stillPending, .pending)
  }

  func testAtMostAHundredRowsPerLaunchOldestFirst() async throws {
    var ids: [UUID] = []
    for index in 0..<(IdentificationReconciler.maximumRows + 5) {
      let meeting = try await meeting(startedAt: 1_700_000_000_000 + Int64(index))
      _ = try await admit(meeting.id, now: Int64(index))
      ids.append(meeting.id)
    }
    let summary = await IdentificationReconciler(store: store, clock: FakeMeetingClock()).run()
    XCTAssertEqual(summary.found, IdentificationReconciler.maximumRows)
    XCTAssertEqual(summary.resume, Array(ids.prefix(IdentificationReconciler.maximumRows)))
  }

  func testResumeHandsPendingRunsToTheCoordinatorAndReadsNoAudio() async throws {
    let meeting = try await meeting(startedAt: 1_700_000_000_000)
    _ = try await admit(meeting.id, now: 10)
    let stamps = try FileManager.default.contentsOfDirectory(
      at: fixture.root.meetingDirectory(meeting.id),
      includingPropertiesForKeys: [.contentAccessDateKey]
    ).map { try $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }
    let summary = await IdentificationReconciler(store: store, clock: FakeMeetingClock()).run()
    XCTAssertEqual(summary.resume, [meeting.id])
    let after = try FileManager.default.contentsOfDirectory(
      at: fixture.root.meetingDirectory(meeting.id),
      includingPropertiesForKeys: [.contentAccessDateKey]
    ).map { try $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }
    XCTAssertEqual(after, stamps, "No audio file was opened")
    // The coordinator queues them; with no profiles the run completes without a lease.
    let factory = FakeVoiceEmbeddingFactory()
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: { try await factory.make() }, factory: { FakeTranscriptionRuntime() })
    let coordinator = SpeakerIdentificationCoordinator(
      identifier: MeetingIdentifier(
        store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
        storageRoot: fixture.root, lifecycle: lifecycle,
        identity: IdentificationTestSupport.identity, clock: FakeMeetingClock()),
      enrollment: EnrollmentJob(
        store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
        storageRoot: fixture.root, lifecycle: lifecycle,
        identity: IdentificationTestSupport.identity, clock: FakeMeetingClock()),
      store: store, enabled: { true })
    coordinator.resume(summary.resume)
    let store = self.store!
    await DiarizationTestSupport.eventually {
      (try? await store.meetingState(meetingID: meeting.id)) == .succeeded
    }
    let made = await factory.makeCount
    XCTAssertEqual(made, 0)
  }
}
