import GRDB
import XCTest

@testable import LocalFlow

/// The reconciler takes only a store and a clock, so it cannot read audio (T026).
final class DiarizationReconcilerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: SpeakerStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = SpeakerStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  /// Only one meeting may be active, so each test meeting is created and failed at once.
  private func meeting(now: Int64) async throws -> UUID {
    let meeting = try await fixture.store.create(now: now)
    try await fixture.store.transition(
      id: meeting.id, to: .failed, now: now,
      effects: [.failure(.notRunningAtLastState, detail: nil)])
    return meeting.id
  }

  private func admit(_ meetingID: UUID, now: Int64) async throws -> DiarizationRun {
    try await store.admit(
      meetingID: meetingID, transcriptPassID: UUID(), trigger: .automatic,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: now)
  }

  /// A run that got as far as one window: a speaker and a turn.
  private func started(_ meetingID: UUID, now: Int64) async throws -> DiarizationRun {
    let run = try await admit(meetingID, now: now)
    _ = try await store.start(runID: run.id, now: now + 1)
    let speaker = SpeakerDraft(
      id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident)
    try await store.appendWindow(
      runID: run.id, speakers: [speaker],
      turns: [.init(speakerID: speaker.id, track: .system, startMs: 0, endMs: 500, quality: nil)],
      audioMs: 500)
    return run
  }

  private func count(_ table: String, run: UUID) throws -> Int {
    try fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM \(table) WHERE run_id=?", arguments: [run.uuidString]) ?? 0
    }
  }

  func testRunningIsInterruptedPendingResumesAndTheAcceptedRunStays() async throws {
    let interruptedMeeting = try await meeting(now: 1)
    let accepted = try await started(interruptedMeeting, now: 10)
    _ = try await store.complete(runID: accepted.id, assignments: [], now: 20)
    let running = try await started(interruptedMeeting, now: 30)
    let pendingMeeting = try await meeting(now: 2)
    _ = try await admit(pendingMeeting, now: 40)

    let summary = await DiarizationReconciler(store: store, clock: FakeMeetingClock()).run()

    XCTAssertEqual(summary.found, 2)
    XCTAssertEqual(summary.interrupted, 1)
    XCTAssertEqual(summary.resume, [pendingMeeting])
    let interrupted = try await store.run(id: running.id)
    XCTAssertEqual(interrupted?.state, .interrupted)
    XCTAssertEqual(interrupted?.failureCategory, .interrupted)
    XCTAssertEqual(try count("speaker_turns", run: running.id), 0)
    XCTAssertEqual(try count("meeting_speakers", run: running.id), 0)
    // The accepted result is untouched and still accepted.
    XCTAssertEqual(try count("speaker_turns", run: accepted.id), 1)
    let row = try await store.diarization(meetingID: interruptedMeeting)
    XCTAssertEqual(row?.acceptedRunID, accepted.id)
    XCTAssertNil(row?.currentRunID)
    let state = try await store.meetingState(meetingID: interruptedMeeting)
    XCTAssertEqual(state, .interrupted)
    let stillPending = try await store.meetingState(meetingID: pendingMeeting)
    XCTAssertEqual(stillPending, .pending)
  }

  func testAtMostOneHundredRunsPerLaunch() async throws {
    for index in 0..<101 {
      _ = try await admit(try await meeting(now: Int64(index)), now: Int64(index))
    }
    let reconciler = DiarizationReconciler(store: store, clock: FakeMeetingClock())
    let first = await reconciler.run()
    XCTAssertEqual(first.found, 100)
    XCTAssertEqual(first.resume.count, 100)
    XCTAssertEqual(DiarizationReconciler.maximumRows, 100)
  }
}
