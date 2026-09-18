import XCTest

@testable import LocalFlow

final class MeetingReconcilerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var clock: FakeMeetingClock!
  private var capture: RecorderCapture!
  private var store: MeetingStore { fixture.store }
  private var root: MeetingStorageRoot { fixture.root }
  private let t0: Int64 = 1_700_000_000_000

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    clock = FakeMeetingClock(now: t0 + 3_600_000)
    capture = try RecorderCapture.make()
  }
  override func tearDown() {
    fixture.cleanup()
    capture.cleanup()
  }

  private func reconciler() -> MeetingReconciler {
    MeetingReconciler(store: store, root: root, recorder: capture.recorder, clock: clock)
  }

  /// A meeting in `state` with two tracks and one open (or finalized) segment per
  /// track whose file holds `frames` complete frames plus `trailing` bytes.
  @discardableResult
  private func seed(
    state: MeetingState, frames: [MeetingTrackKind: Int] = [.microphone: 40, .system: 40],
    trailing: Int = 30, pauseOpen: Bool = false, stage: FinalizationStage? = nil,
    finalizedMicrophone: Bool = false, writeFiles: Bool = true
  ) async throws -> (Meeting, [MeetingTrackDetail]) {
    let created = try await store.create(now: t0)
    let tracks = [
      MeetingTrack(
        id: UUID(), meetingID: created.id, kind: .microphone, channelCount: 1, bitrate: 64_000),
      MeetingTrack(
        id: UUID(), meetingID: created.id, kind: .system, channelCount: 2, bitrate: 96_000),
    ]
    try await store.transition(
      id: created.id, to: .preparing, now: t0, effects: [.insertTracks(tracks)])
    guard state != .preparing else {
      let detail = try await store.detail(id: created.id)!
      return (detail.meeting, detail.tracks)
    }
    var effects: [MeetingTransitionEffect] = [.setStartedAt(t0 + 1_000)]
    for track in tracks {
      let segment = MeetingSegment(
        id: UUID(), trackID: track.id, sequence: 1,
        relativePath: SegmentHandle.relativePath(
          meetingID: created.id, kind: track.kind, sequence: 1, open: true),
        startOffsetMs: 0, startedAt: t0 + 1_000, hostStartNs: 5, openReason: .start)
      effects.append(.openSegment(segment))
      if writeFiles, let count = frames[track.kind] {
        let url = root.resolve(relativePath: segment.relativePath)!
        var bytes = ADTSFixtures.completeFrames(count, channels: track.kind == .microphone ? 1 : 2)
        if trailing > 0 {
          bytes += ADTSFixtures.completeFrames(1, channels: track.kind == .microphone ? 1 : 2)
            .prefix(trailing)
        }
        try ADTSFixtures.write(bytes, to: url)
      }
    }
    try await store.transition(id: created.id, to: .recording, now: t0 + 1_000, effects: effects)
    _ = try await store.saveNotes(
      meetingID: created.id, text: "keep me", revision: 0, now: t0 + 2_000)
    if state == .paused || pauseOpen {
      _ = try await store.openPause(meetingID: created.id, reason: .user, at: t0 + 60_000)
      if state == .paused {
        try await store.transition(id: created.id, to: .paused, now: t0 + 60_000, effects: [])
      }
    }
    if state == .finalizing {
      try await store.transition(
        id: created.id, to: .finalizing, now: t0 + 90_000, effects: [.setStoppedAt(t0 + 90_000)])
      if let stage {
        try await store.setFinalizationStage(meetingID: created.id, stage: stage, now: t0 + 90_000)
      }
      if finalizedMicrophone {
        let detail = try await store.detail(id: created.id)!
        let mic = detail.track(.microphone)!.segments[0]
        let part = root.resolve(relativePath: mic.relativePath)!
        let final = root.resolve(relativePath: String(mic.relativePath.dropLast(5)))!
        let scan = try ADTSValidator.scan(url: part)
        try FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes)
        try await store.finalizeSegment(
          id: mic.id, durationMs: scan.durationMs, byteSize: Int64(scan.completeBytes),
          relativePath: String(mic.relativePath.dropLast(5)), closeReason: .stop, droppedFrames: 0,
          now: t0 + 90_000)
        try await store.markTrackFinalized(id: detail.track(.microphone)!.id, now: t0 + 90_000)
      }
    }
    // Heartbeat-style bump so updated_at is the last persisted instant.
    let detail = try await store.detail(id: created.id)!
    return (detail.meeting, detail.tracks)
  }

  private func listing() -> [String] {
    var names: [String] = []
    if let enumerator = FileManager.default.enumerator(atPath: root.url.path) {
      for case let name as String in enumerator { names.append(name) }
    }
    return names.sorted()
  }

  func testRecordingRowBecomesInterruptedWithTruncatedRenamedSegments() async throws {
    let (meeting, _) = try await seed(state: .recording)
    let before = listing()
    let summary = await reconciler().run()
    XCTAssertEqual(
      summary,
      ReconciliationSummary(
        meetingsFound: 1, recovered: 1, unrecoverable: 0, orphansReconstructed: 0, deferred: 0))
    let detail = try await store.detail(id: meeting.id)!
    XCTAssertEqual(detail.meeting.state, .interrupted)
    XCTAssertEqual(detail.meeting.failureReason, .notRunningAtLastState)
    XCTAssertEqual(
      detail.meeting.stoppedAt, meeting.updatedAt, "ended at the last persisted instant")
    XCTAssertNotNil(detail.meeting.completedAt)
    for track in detail.tracks {
      XCTAssertEqual(track.track.health, .finalized)
      let segment = track.segments[0]
      XCTAssertEqual(segment.state, .finalized)
      XCTAssertEqual(segment.closeReason, .recovered)
      XCTAssertTrue(segment.relativePath.hasSuffix(".aac"))
      XCTAssertEqual(segment.byteSize, Int64(40 * 207))
      XCTAssertEqual(segment.durationMs, 40 * 1_024 * 1_000 / 48_000)
      XCTAssertEqual(segment.recoveryNote, "truncated=30 frames=40")
      let url = root.resolve(relativePath: segment.relativePath)!
      XCTAssertEqual(try ADTSValidator.scan(url: url).trailingBytes, 0)
      XCTAssertEqual(track.track.totalDurationMs, segment.durationMs)
    }
    XCTAssertEqual(detail.notes.text, "keep me")
    XCTAssertEqual(detail.outcomes.count, 1)
    XCTAssertEqual(detail.outcomes[0].foundState, .recording)
    XCTAssertEqual(detail.outcomes[0].segmentsRecovered, 2)
    XCTAssertEqual(detail.outcomes[0].bytesTruncated, 60)
    XCTAssertEqual(listing().count, before.count, "renamed, never deleted")
    XCTAssertEqual(listing().filter { $0.hasSuffix(".part") }.count, 0)
    let metrics = try await capture.metrics()
    XCTAssertEqual(metrics.filter { $0 == "meetingRecoveryOutcome" }.count, 1)
    let samples = try await capture.samples()
    XCTAssertTrue(samples.contains { $0["meetingKey"] as? String == "recovered" })
  }

  func testPausedRowClosesThePauseAtUpdatedAtAndExcludesIt() async throws {
    let (meeting, _) = try await seed(state: .paused)
    _ = await reconciler().run()
    let detail = try await store.detail(id: meeting.id)!
    XCTAssertEqual(detail.meeting.state, .interrupted)
    XCTAssertEqual(detail.pauses.count, 1)
    XCTAssertEqual(detail.pauses[0].closedBy, .reconciliation)
    XCTAssertEqual(detail.pauses[0].endedAt, meeting.updatedAt)
    XCTAssertEqual(detail.meeting.wallClockMs, meeting.updatedAt - (t0 + 1_000))
    XCTAssertEqual(detail.meeting.recordedMs, 59_000, "the open pause is excluded")
    XCTAssertTrue(detail.outcomes[0].pauseClosed)
  }

  func testFinalizingWithMicrophoneStageKeepsItAndRecoversSystem() async throws {
    let (meeting, _) = try await seed(state: .finalizing, stage: .mic, finalizedMicrophone: true)
    _ = await reconciler().run()
    let detail = try await store.detail(id: meeting.id)!
    XCTAssertEqual(detail.meeting.state, .interrupted)
    let mic = detail.track(.microphone)!
    XCTAssertEqual(mic.segments[0].closeReason, .stop, "already finalized; untouched")
    XCTAssertEqual(mic.track.health, .finalized)
    let sys = detail.track(.system)!
    XCTAssertEqual(sys.segments[0].closeReason, .recovered)
    XCTAssertEqual(sys.track.health, .finalized)
    XCTAssertEqual(detail.outcomes[0].foundStage, .mic)
    XCTAssertEqual(detail.outcomes[0].segmentsRecovered, 1)
  }

  func testZeroCompleteFramesStaysPartAndUnrecoverableWithFileKept() async throws {
    let (meeting, tracks) = try await seed(
      state: .recording, frames: [.microphone: 0, .system: 40], trailing: 3)
    let micPart = root.resolve(relativePath: tracks[0].segments[0].relativePath)!
    XCTAssertEqual(try Data(contentsOf: micPart).count, 3)
    let summary = await reconciler().run()
    XCTAssertEqual(summary.recovered, 1)
    let detail = try await store.detail(id: meeting.id)!
    let mic = detail.track(.microphone)!
    XCTAssertEqual(mic.segments[0].state, .unrecoverable)
    XCTAssertEqual(mic.segments[0].failureReason, .unrecoverableMedia)
    XCTAssertTrue(mic.segments[0].relativePath.hasSuffix(".part"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: micPart.path), "the file is kept")
    XCTAssertEqual(mic.track.health, .unrecoverable)
    XCTAssertEqual(mic.track.failureReason, .unrecoverableMedia)
    XCTAssertEqual(detail.track(.system)!.segments[0].state, .finalized)
    XCTAssertEqual(detail.notes.text, "keep me")
    XCTAssertEqual(detail.outcomes[0].segmentsUnrecoverable, 1)
  }

  func testMissingFileIsUnrecoverableWithFileMissing() async throws {
    let (meeting, _) = try await seed(state: .recording, frames: [.system: 40], writeFiles: true)
    let summary = await reconciler().run()
    XCTAssertEqual(summary.recovered, 1)
    let detail = try await store.detail(id: meeting.id)!
    XCTAssertEqual(detail.track(.microphone)!.segments[0].state, .unrecoverable)
    XCTAssertEqual(detail.track(.microphone)!.segments[0].failureReason, .fileMissing)
    XCTAssertEqual(detail.outcomes[0].segmentsMissing, 1)
  }

  func testStaleMetadataIsRevalidatedAndCorrected() async throws {
    let (meeting, tracks) = try await seed(state: .recording)
    // The row says finalized with a .part path while the file is still .part.
    let mic = tracks[0].segments[0]
    try await store.finalizeSegment(
      id: mic.id, durationMs: 1, byteSize: 1, relativePath: mic.relativePath, closeReason: .stop,
      droppedFrames: 0, now: t0 + 5_000)
    _ = await reconciler().run()
    let detail = try await store.detail(id: meeting.id)!
    let corrected = detail.track(.microphone)!.segments[0]
    XCTAssertEqual(corrected.state, .finalized)
    XCTAssertTrue(corrected.relativePath.hasSuffix(".aac"))
    XCTAssertEqual(corrected.byteSize, Int64(40 * 207))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.resolve(relativePath: corrected.relativePath)!.path))
  }

  func testOrphanDirectoryBecomesInterruptedMeetingWithReconstructedTracks() async throws {
    let orphan = UUID()
    let directory = root.meetingDirectory(orphan)
    try ADTSFixtures.write(
      ADTSFixtures.completeFrames(50), to: directory.appendingPathComponent("mic-0001.aac"))
    try ADTSFixtures.write(
      ADTSFixtures.truncatedMidFrame(20, cut: 10),
      to: directory.appendingPathComponent("mic-0002.aac.part"))
    try ADTSFixtures.write(
      ADTSFixtures.completeFrames(30, channels: 2),
      to: directory.appendingPathComponent("system-0001.aac"))
    try ADTSFixtures.write(
      [0xFF, 0xF1], to: directory.appendingPathComponent("system-0002.aac.part"))
    try Data("x".utf8).write(to: directory.appendingPathComponent("unrelated.txt"))
    let summary = await reconciler().run()
    XCTAssertEqual(summary.orphansReconstructed, 1)
    XCTAssertEqual(summary.meetingsFound, 0)
    let detail = try await store.detail(id: orphan)!
    XCTAssertEqual(detail.meeting.state, .interrupted)
    XCTAssertEqual(detail.meeting.failureReason, .recordMissing)
    XCTAssertNil(detail.meeting.title)
    let mic = detail.track(.microphone)!
    XCTAssertEqual(mic.segments.map(\.sequence), [1, 2])
    XCTAssertEqual(mic.segments.map(\.state), [.finalized, .finalized])
    XCTAssertEqual(mic.segments[1].startOffsetMs, mic.segments[0].durationMs)
    XCTAssertEqual(mic.track.health, .finalized)
    XCTAssertEqual(mic.track.totalDurationMs, mic.segments.map(\.durationMs).reduce(0, +))
    let fifty: Int64 = 50 * 1_024 * 1_000 / 48_000
    let twenty: Int64 = 20 * 1_024 * 1_000 / 48_000
    XCTAssertEqual(mic.segments.map(\.durationMs), [fifty, twenty])
    let sys = detail.track(.system)!
    XCTAssertEqual(sys.track.channelCount, 2)
    XCTAssertEqual(sys.segments.map(\.state), [.finalized, .unrecoverable])
    XCTAssertEqual(sys.segments[1].failureReason, .unrecoverableMedia)
    XCTAssertEqual(detail.notes.text, "")
    XCTAssertEqual(detail.outcomes.count, 1)
    XCTAssertEqual(detail.outcomes[0].segmentsRecovered, 3)
    XCTAssertEqual(detail.outcomes[0].segmentsUnrecoverable, 1)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    XCTAssertEqual(
      names,
      ["mic-0001.aac", "mic-0002.aac", "system-0001.aac", "system-0002.aac.part", "unrelated.txt"])
    let page = try await store.page(before: nil, limit: 20)
    XCTAssertEqual(page.map(\.id), [orphan])
    XCTAssertFalse(page[0].hasTrackWarning, "both tracks have a playable segment")
    // A second run finds nothing to do.
    let again = await reconciler().run()
    XCTAssertTrue(again.isSilent)
  }

  func testCreatedRowThatNeverPreparedBecomesFailedAndUnblocksCreate() async throws {
    let created = try await store.create(now: t0)
    let summary = await reconciler().run()
    XCTAssertEqual(summary.meetingsFound, 1)
    XCTAssertEqual(summary.recovered, 0)
    let detail = try await store.detail(id: created.id)!
    XCTAssertEqual(detail.meeting.state, .failed)
    XCTAssertEqual(detail.meeting.failureReason, .notRunningAtLastState)
    XCTAssertEqual(detail.outcomes.count, 1)
    let next = try await store.create(now: t0 + 1)
    try await store.transition(id: next.id, to: .failed, now: t0 + 2, effects: [])
    // A preparing row with no media is failed too.
    let prepared = try await seed(state: .preparing)
    _ = await reconciler().run()
    let preparedRow = try await store.meeting(id: prepared.0.id)
    XCTAssertEqual(preparedRow?.state, .failed)
  }

  func testTerminalRowsAreUntouchedAndAQuietLaunchIsSilent() async throws {
    let (meeting, _) = try await seed(state: .recording)
    _ = await reconciler().run()
    let after = try await store.detail(id: meeting.id)!
    let listingBefore = listing()
    let summary = await reconciler().run()
    XCTAssertTrue(summary.isSilent)
    XCTAssertNil(summary.noticeText)
    let again = try await store.detail(id: meeting.id)!
    XCTAssertEqual(again, after, "terminal row untouched")
    XCTAssertEqual(listing(), listingBefore)
    XCTAssertEqual(again.outcomes.count, 1, "no second outcome")
  }

  func testWorkListIsBoundedAndTheRemainderIsDeferred() async throws {
    // Rows above the bound: create 3 created rows by writing them directly.
    try await fixture.history.database.write { db in
      for index in 0..<(MeetingReconciler.maximumRows + 3) {
        let id = UUID().uuidString
        try db.execute(
          sql:
            "INSERT INTO meetings (id, state, created_at, updated_at) VALUES (?, 'created', ?, ?)",
          arguments: [id, 1_000 + index, 1_000 + index])
        try db.execute(
          sql:
            "INSERT INTO meeting_notes (meeting_id, text, author, updated_at, revision) VALUES (?, '', 'user', 0, 0)",
          arguments: [id])
      }
    }
    for index in 0..<(MeetingReconciler.maximumDirectoryEntries + 2) {
      try FileManager.default.createDirectory(
        at: root.url.appendingPathComponent("not-a-uuid-\(index)"),
        withIntermediateDirectories: true)
    }
    let summary = await reconciler().run()
    XCTAssertEqual(summary.meetingsFound, MeetingReconciler.maximumRows)
    XCTAssertEqual(summary.deferred, 3 + 2)
    XCTAssertTrue(summary.noticeText?.contains("deferred") == true)
    let remaining = try await store.activeStateRows()
    XCTAssertEqual(remaining.count, 3)
    let samples = try await capture.samples()
    XCTAssertTrue(samples.contains { $0["meetingKey"] as? String == "deferred" })
  }

  func testNoticeTextSummarizesWithoutContent() {
    var summary = ReconciliationSummary()
    summary.meetingsFound = 2
    summary.recovered = 1
    summary.unrecoverable = 1
    XCTAssertEqual(
      summary.noticeText, "1 meeting recovered, 1 with audio that could not be made playable")
    summary.orphansReconstructed = 1
    XCTAssertTrue(summary.noticeText!.contains("1 found without a record"))
  }

  /// Launch wiring: `AppServices` runs the reconciler on a detached task and the
  /// coordinator's gate resolves when it finishes; dictation is unaffected.
  @MainActor
  func testLaunchGateDoesNotBlockAndResolvesWhenSilent() async throws {
    let gate = MeetingReconciliationGate()
    XCTAssertFalse(gate.isComplete)
    let waiting = Task { await gate.wait() }
    let reconciler = reconciler()
    let task = Task.detached { await reconciler.run() }
    let summary = await task.value
    gate.complete(summary)
    _ = await waiting.value
    XCTAssertTrue(gate.isComplete)
    XCTAssertTrue(summary.isSilent)
    XCTAssertNil(gate.summary?.noticeText)
  }
}
