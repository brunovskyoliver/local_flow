import GRDB
import XCTest

@testable import LocalFlow

final class TranscriptReconcilerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: TranscriptStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  private func seed(meeting: MeetingState, transcript: TranscriptState, time: Int = 1) async throws
    -> UUID
  {
    let id = UUID()
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "INSERT INTO meetings (id,state,created_at,updated_at) VALUES (?,?,?,?)",
        arguments: [id.uuidString, meeting.rawValue, time, time])
      try db.execute(
        sql:
          "INSERT INTO meeting_transcriptions (meeting_id,state,live_requested,updated_at) VALUES (?,?,1,?)",
        arguments: [id.uuidString, transcript.rawValue, time])
    }
    return id
  }

  func testRecoveryPolicyPreservesTextAndGapsAndIsIdempotent() async throws {
    var retryIDs: [UUID] = []
    var resumeIDs: [UUID] = []
    for meeting in [MeetingState.completed, .interrupted] {
      for state in [TranscriptState.pending, .live, .finalizing] {
        let id = try await seed(meeting: meeting, transcript: .pending)
        if state != .pending {
          let pass = UUID()
          try await store.transition(
            meetingID: id, to: .live, now: 2,
            effects: [.setPass(id: pass, kind: .live)])
          _ = try await store.appendSegments(
            meetingID: id, passID: pass,
            drafts: [
              .init(
                ordinal: 0, stretchSequence: 1, startMs: 0, endMs: 100,
                coveredMs: 200, windowIndex: 0, timingBasis: .window,
                rawText: "kept", assembledText: "kept", normalizedText: "Kept", analysisTracks: .mic
              )
            ], progress: nil, now: 3)
          try await store.appendGap(
            .init(
              meetingID: id, passID: pass, stretchSequence: 1,
              startMs: 100, endMs: 200, reason: .suspended, createdAt: 3))
          if state == .finalizing {
            try await store.transition(
              meetingID: id, to: .finalizing, now: 4,
              effects: [.setPass(id: UUID(), kind: .final)])
          }
        }
        if state == .finalizing { resumeIDs.append(id) } else { retryIDs.append(id) }
      }
    }
    let failed = try await seed(meeting: .failed, transcript: .finalizing)
    let beforeUsage = try await store.usage()
    let listing = fileListing(under: fixture.directory)
    let reconciler = TranscriptReconciler(store: store, meetings: fixture.store)
    let summary = await reconciler.run()
    XCTAssertEqual(summary.interrupted, 4)
    XCTAssertEqual(summary.failed, 1)
    XCTAssertEqual(Set(summary.resume), Set(resumeIDs))
    for id in retryIDs + [failed] {
      let row = try await store.transcription(meetingID: id)
      XCTAssertEqual(row?.state, id == failed ? .failed : .interrupted)
      XCTAssertEqual(row?.failureCategory, .finalizationInterrupted)
    }
    let outcomes = try await fixture.history.database.read { db in
      try String.fetchAll(db, sql: "SELECT summary FROM meeting_recovery_outcomes")
    }
    XCTAssertEqual(outcomes.count, 5)
    XCTAssertTrue(outcomes.allSatisfy { $0.hasPrefix("transcript:") })
    let afterUsage = try await store.usage()
    XCTAssertEqual(afterUsage, beforeUsage)
    let gaps = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_live_gaps")!
    }
    XCTAssertEqual(gaps, 4)
    let second = await reconciler.run()
    XCTAssertEqual(second.interrupted, 0)
    XCTAssertEqual(second.failed, 0)
    XCTAssertEqual(Set(second.resume), Set(resumeIDs))
    let outcomeCount = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_recovery_outcomes")!
    }
    XCTAssertEqual(outcomeCount, 5)
    XCTAssertEqual(fileListing(under: fixture.directory), listing)
  }

  func testOneLaunchProcessesAtMostOneHundredRows() async throws {
    for index in 0..<103 {
      _ = try await seed(meeting: .completed, transcript: .pending, time: index)
    }
    let reconciler = TranscriptReconciler(store: store, meetings: fixture.store)
    let first = await reconciler.run()
    XCTAssertEqual(first.found, 100)
    XCTAssertEqual(first.interrupted, 100)
    let remaining = try await store.activeRows(limit: 100)
    XCTAssertEqual(remaining.count, 3)
    let second = await reconciler.run()
    XCTAssertEqual(second.found, 3)
    XCTAssertEqual(second.interrupted, 3)
  }

  func testMeetingRecoveryRunsBeforeTranscriptRecoveryOnTheLaunchTask() async throws {
    let created = try await fixture.store.create(now: 1)
    let track = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .microphone,
      channelCount: 1, bitrate: 64_000)
    try await fixture.store.transition(
      id: created.id, to: .preparing, now: 2,
      effects: [.insertTracks([track]), .insertTranscription(liveRequested: true)])
    let writer = FileSegmentWriter(root: fixture.root)
    let handle = try writer.open(meetingID: created.id, kind: .microphone, sequence: 1)
    try writer.append(handle, frames: [ADTSFrame(bytes: ADTSFixtures.completeFrames(40))])
    writer.abandon(handle)
    let segment = MeetingSegment(
      id: UUID(), trackID: track.id, sequence: 1,
      relativePath: handle.relativePath, startOffsetMs: 0, startedAt: 3, hostStartNs: 0,
      openReason: .start)
    try await fixture.store.transition(
      id: created.id, to: .recording, now: 3,
      effects: [.setStartedAt(3), .openSegment(segment)])
    try await store.transition(
      meetingID: created.id, to: .live, now: 4,
      effects: [.setPass(id: UUID(), kind: .live)])
    let transcripts = TranscriptReconciler(store: store, meetings: fixture.store)
    let premature = await transcripts.run()
    XCTAssertEqual(premature.deferred, 1)
    let clock = FakeMeetingClock(now: 10_000)
    let meetings = MeetingReconciler(
      store: fixture.store, root: fixture.root, recorder: nil, clock: clock)
    // The launch task awaits meeting repair before querying transcript work.
    let result = await Task {
      let meetingResult = await meetings.run()
      let transcriptResult = await transcripts.run()
      return (meetingResult, transcriptResult)
    }.value
    XCTAssertEqual(result.0.recovered, 1)
    XCTAssertEqual(result.1.interrupted, 1)
    XCTAssertTrue(result.1.resume.isEmpty)
    let meeting = try await fixture.store.meeting(id: created.id)
    let transcript = try await store.transcription(meetingID: created.id)
    XCTAssertEqual(meeting?.state, .interrupted)
    XCTAssertEqual(transcript?.state, .interrupted)
  }

  func testOutcomeFailureRollsBackRecoveryAndRetryWritesOneOutcome() async throws {
    let id = try await seed(meeting: .completed, transcript: .live)
    let before = try await store.transcription(meetingID: id)
    try await fixture.history.database.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER reject_recovery BEFORE INSERT ON meeting_recovery_outcomes BEGIN SELECT RAISE(ABORT, 'private fixture payload'); END"
      )
    }
    let reconciler = TranscriptReconciler(store: store, meetings: fixture.store)
    let failed = await reconciler.run()
    XCTAssertEqual(failed.interrupted, 0)
    let after = try await store.transcription(meetingID: id)
    XCTAssertEqual(after, before)
    try await fixture.history.database.write { db in
      try db.execute(sql: "DROP TRIGGER reject_recovery")
    }
    let retried = await reconciler.run()
    XCTAssertEqual(retried.interrupted, 1)
    let count = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_recovery_outcomes")!
    }
    XCTAssertEqual(count, 1)
  }

  func testMissingMeetingIsCountedAndActiveMeetingIsDeferred() async throws {
    let id = try await seed(meeting: .recording, transcript: .live)
    let before = try await store.transcription(meetingID: id)
    let deferred = await TranscriptReconciler(store: store, meetings: fixture.store).run()
    XCTAssertEqual(deferred.deferred, 1)
    let after = try await store.transcription(meetingID: id)
    XCTAssertEqual(after, before)
    let missing = await TranscriptReconciler(store: store, meetings: StubMeetingStore(detail: nil))
      .run()
    XCTAssertEqual(missing.missingMeetings, 1)
    XCTAssertTrue(missing.resume.isEmpty)
  }
}

@MainActor
final class TranscriptRestartTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: TranscriptStore!
  override func setUp() async throws {
    fixture = try MeetingTestStore.make()
    store = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() async throws { fixture.cleanup() }

  private func coordinator(runtime: FakeTranscriptionRuntime, clock: FakeMeetingClock)
    -> (MeetingTranscriptionCoordinator, ModelLifecycleCoordinator, MeetingFinalizer)
  {
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root,
      lifecycle: lifecycle, vocabulary: EmptyVocabularyProvider(), clock: clock)
    return (
      MeetingTranscriptionCoordinator(
        store: store, lifecycle: lifecycle, clock: clock,
        finalizer: finalizer), lifecycle, finalizer
    )
  }

  func testFreshCoordinatorResumesInterruptedFinalizerWithoutRepeatingCommittedWindows()
    async throws
  {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init(), .init()])
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(1), clock: clock)
    let (_, lifecycle, finalizer) = coordinator(runtime: runtime, clock: clock)
    let initialValue = try await store.transcription(meetingID: meeting.meetingID)
    let initial = try XCTUnwrap(initialValue)
    let task = Task {
      try await finalizer.run(meetingID: meeting.meetingID, revision: initial.revision)
    }
    await wait { await runtime.active == 1 }
    await clock.advance(by: .seconds(1))
    await wait {
      let count = await runtime.sampleCounts.count
      let active = await runtime.active
      return count == 2 && active == 1
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled finalizer completed")
    } catch { XCTAssertTrue(error is CancellationError) }
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    let beforeValue = try await store.transcription(meetingID: meeting.meetingID)
    let before = try XCTUnwrap(beforeValue)
    let kept = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertFalse(kept.isEmpty)
    let windows = await runtime.received
    let recovery = await TranscriptReconciler(store: store, meetings: fixture.store).run()
    XCTAssertEqual(recovery.resume, [meeting.meetingID])
    let resumedRuntime = FakeTranscriptionRuntime()
    let (fresh, _, _) = coordinator(runtime: resumedRuntime, clock: clock)
    fresh.resumeFinalizations(recovery.resume)
    await wait {
      try? await self.store.transcription(meetingID: meeting.meetingID)?.state == .final
    }
    let after = try await store.transcription(meetingID: meeting.meetingID)
    let segments = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    let resumedWindows = await resumedRuntime.received
    XCTAssertEqual(after?.passID, before.passID)
    XCTAssertEqual(Array(segments.prefix(kept.count)), kept)
    XCTAssertEqual(resumedWindows.count, 2)
    XCTAssertEqual(resumedWindows.first, windows.dropFirst().first)
  }

  func testRestartDuringLiveKeepsCommittedTextAndAdmitsRetry() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, finalState: .interrupted)
    let clock = FakeMeetingClock()
    let (old, _, _) = coordinator(runtime: FakeTranscriptionRuntime(), clock: clock)
    _ = await old.meetingWillStart(id: meeting.meetingID, options: .init(transcription: true))
    _ = old.stretchDidStart(
      meetingID: meeting.meetingID, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await wait { old.status?.state == .live }
    let liveValue = try await store.transcription(meetingID: meeting.meetingID)
    let live = try XCTUnwrap(liveValue)
    let pass = try XCTUnwrap(live.passID)
    _ = try await store.appendSegments(
      meetingID: meeting.meetingID, passID: pass,
      drafts: [
        .init(
          ordinal: 0, stretchSequence: 1, startMs: 0, endMs: 100, coveredMs: 100,
          windowIndex: 0, timingBasis: .window, rawText: "saved", assembledText: "saved",
          normalizedText: "Saved", analysisTracks: .mic)
      ], progress: nil, now: clock.nowMilliseconds)
    // Tear down the live resources without a stop transition or row deletion.
    // This leaves exactly the durable state available after process loss.
    await old.meetingWillDelete(id: meeting.meetingID)
    let kept = try await store.page(
      meetingID: meeting.meetingID, finality: .provisional, after: nil, limit: 200)
    let summary = await TranscriptReconciler(store: store, meetings: fixture.store).run()
    XCTAssertEqual(summary.interrupted, 1)
    XCTAssertTrue(summary.resume.isEmpty)
    let recoveredValue = try await store.transcription(meetingID: meeting.meetingID)
    let recovered = try XCTUnwrap(recoveredValue)
    XCTAssertEqual(recovered.state, .interrupted)
    let afterRecovery = try await store.page(
      meetingID: meeting.meetingID, finality: .provisional, after: nil, limit: 200)
    XCTAssertEqual(afterRecovery, kept)
    let (fresh, _, _) = coordinator(runtime: FakeTranscriptionRuntime(), clock: clock)
    fresh.requestFinalization(meetingID: meeting.meetingID, revision: recovered.revision)
    await wait {
      try? await self.store.transcription(meetingID: meeting.meetingID)?.state == .final
    }
    let completed = try await store.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(completed?.replacedProvisionalCount, kept.count)
  }

  func testDeletionJoinsFinalizerAndReleasesLeaseBeforeRemovingAudio() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(10), clock: clock)
    let (coordinator, lifecycle, _) = coordinator(runtime: runtime, clock: clock)
    let rowValue = try await store.transcription(meetingID: meeting.meetingID)
    let row = try XCTUnwrap(rowValue)
    coordinator.requestFinalization(meetingID: meeting.meetingID, revision: row.revision)
    await wait { await runtime.active == 1 }
    let before = try meeting.fileDigests()
    await coordinator.meetingWillDelete(id: meeting.meetingID)
    let snapshot = await lifecycle.snapshot()
    let active = await runtime.active
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(active, 0)
    XCTAssertEqual(try meeting.fileDigests(), before, "Join finishes before audio removal")
    let meetingRowValue = try await fixture.store.meeting(id: meeting.meetingID)
    let meetingRow = try XCTUnwrap(meetingRowValue)
    let deleted = try await fixture.store.deleteConfirmed(
      id: meeting.meetingID, revision: meetingRow.revision)
    XCTAssertTrue(deleted.complete)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.root.meetingDirectory(meeting.meetingID).path))
    let gone = try await store.transcription(meetingID: meeting.meetingID)
    XCTAssertNil(gone)
  }

  private func wait(_ condition: @escaping @MainActor () async -> Bool?) async {
    for _ in 0..<1_000 {
      if await condition() == true { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Condition did not settle")
  }
}
