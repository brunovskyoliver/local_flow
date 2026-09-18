import AVFoundation
import XCTest

@testable import LocalFlow

@MainActor
final class MeetingTranscriptionCoordinatorTests: XCTestCase {
  func testStartReturnsTapsWithoutWaitingForModelAndPublishesCommittedIdentity() async throws {
    let gate = TranscriptLoadGate()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    let initial = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    XCTAssertEqual(initial, .pending)
    let taps = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    XCTAssertEqual(taps?.count, 1)
    XCTAssertNotEqual(coordinator.status?.state, .live)
    await gate.open()
    await settle { coordinator.status?.state == .live }
    let stored = await store.transcription(meetingID: id)
    let row = try XCTUnwrap(stored)
    XCTAssertEqual(row.plannerVersion, LiveChunkPlanner.version)
    XCTAssertEqual(row.vocabularyHash, VocabularySnapshot.empty.hash)
    XCTAssertEqual(coordinator.status?.metadata, row)
    await coordinator.meetingWillDelete(id: id)
  }

  func testSyntheticPCMProducesCommittedProvisionalTextAndFreshStretch() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    let source = try FakeAnalysisTap()
    for index in 0..<1_407 {
      let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4_096)!
      buffer.frameLength = 4_096
      buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
      taps[.microphone]?.push(buffer)
      await coordinator.tick()
      await Task.yield()
      if index % 24 == 23 { await clock.advance(by: .seconds(2)) }
    }
    await settle { coordinator.isWindowInFlight == false }
    await clock.advance(by: .seconds(2))
    await coordinator.tick()
    await settle { (coordinator.status?.provisionalCount ?? 0) > 0 }
    let segments = await store.segments
    XCTAssertFalse(segments.isEmpty)
    XCTAssertEqual(coordinator.status?.provisionalCount, segments.count)
    XCTAssertEqual(coordinator.liveModel.segments.count, segments.count)
    let second = coordinator.stretchDidStart(
      meetingID: id, sequence: 2,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    XCTAssertFalse(second?[.microphone] === taps[.microphone])
    await coordinator.meetingWillDelete(id: id)
  }

  func testPauseAndResumeDuringModelLoadUseLatestTaps() async throws {
    let gate = TranscriptLoadGate()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let first = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    coordinator.meetingDidPause(id: id)
    let second = coordinator.stretchDidStart(
      meetingID: id, sequence: 2,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    XCTAssertFalse(first?[.microphone] === second?[.microphone])
    await gate.open()
    await settle { coordinator.status?.state == .live }
    let source = try FakeAnalysisTap()
    for _ in 0..<76 {
      let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4_096)!
      buffer.frameLength = 4_096
      buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
      second?[.microphone]?.push(buffer)
      await coordinator.tick()
      await Task.yield()
    }
    coordinator.meetingDidPause(id: id)
    await settle { (coordinator.status?.provisionalCount ?? 0) > 0 }
    let segments = await store.segments
    XCTAssertTrue(segments.allSatisfy { $0.draft.stretchSequence == 2 })
    await coordinator.meetingWillDelete(id: id)
  }

  func testPausedLoadDoesNotStartRecognition() async throws {
    let gate = TranscriptLoadGate()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    coordinator.meetingDidPause(id: id)
    await gate.open()
    await settle { coordinator.status?.state == .live }
    await coordinator.tick()
    let counts = await runtime.sampleCounts
    XCTAssertTrue(counts.isEmpty)
    XCTAssertFalse(coordinator.isWindowInFlight)
    await coordinator.meetingWillDelete(id: id)
  }

  func testPauseRetriesTransientBatchFailuresBeforeAdvancingStretch() async throws {
    let clock = FakeMeetingClock()
    let store = FakeTranscriptStore()
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let id = UUID()
    await store.seed(id)
    await store.failBatches(3)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    let source = try FakeAnalysisTap()
    for _ in 0..<12 {
      let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4_096)!
      buffer.frameLength = 4_096
      buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
      taps?[.microphone]?.push(buffer)
    }
    coordinator.meetingDidPause(id: id)
    await settle { (coordinator.status?.provisionalCount ?? 0) == 1 }
    let calls = await store.calls.filter { $0 == "appendSegments" }
    XCTAssertEqual(calls.count, 4)
    XCTAssertEqual(coordinator.status?.state, .live)
    await coordinator.meetingWillDelete(id: id)
  }

  func testStopDuringLoadAllowsNextMeetingToAcquire() async throws {
    let gate = TranscriptLoadGate()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let store = FakeTranscriptStore()
    let first = UUID()
    let second = UUID()
    await store.seed(first)
    await store.seed(second)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: first, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: first, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    coordinator.meetingDidStop(id: first)
    // New admission joins the stopped session even if its cleanup is still pending.
    _ = await coordinator.meetingWillStart(id: second, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: second, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    XCTAssertNotEqual(coordinator.status?.state, .live)
    await gate.open()
    await settle { coordinator.status?.meetingID == second && coordinator.status?.state == .live }
    let model = await lifecycle.snapshot()
    XCTAssertTrue(model.leased)
    await coordinator.meetingWillDelete(id: second)
  }

  func testIncompatibleTrackGeometryFailsOnlyTranscriptAndReleasesLease() async throws {
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    XCTAssertNil(coordinator.stretchDidStart(meetingID: id, sequence: 2, tracks: [:]))
    await settle { coordinator.status?.state == .failed }
    XCTAssertEqual(coordinator.status?.failure, .analysisStreamFailure)
    await coordinator.meetingWillDelete(id: id)
    let model = await lifecycle.snapshot()
    XCTAssertFalse(model.leased)
    // The observer only owns transcript storage, never the recording state or writer.
    let row = await store.transcription(meetingID: id)
    XCTAssertEqual(row?.state, .failed)
  }

  func testShutdownJoinsStoppedSessionAndReleasesLease() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    coordinator.meetingDidStop(id: id)
    await coordinator.shutdown()
    let model = await lifecycle.snapshot()
    XCTAssertFalse(model.leased)
  }

  func testDeletingLiveSessionJoinsRecognitionAndClosesEveryTap() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(30), clock: clock)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1, tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.isWindowInFlight }
    await coordinator.meetingWillDelete(id: id)
    let active = await runtime.active
    XCTAssertEqual(active, 0)
    let model = await lifecycle.snapshot()
    XCTAssertFalse(model.leased)
    XCTAssertFalse(taps[.microphone]!.ring.push(interleaved: [0.25], frames: 1))
    XCTAssertFalse(coordinator.isWindowInFlight)
    XCTAssertEqual(coordinator.queuedFinalizationCount, 0)
    await coordinator.shutdown()
  }

  func testDeletingOldMeetingDuringHandoffDoesNotClearNewSession() async throws {
    let gate = TranscriptLoadGate()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return FakeTranscriptionRuntime()
    }
    let store = FakeTranscriptStore()
    let first = UUID()
    let second = UUID()
    await store.seed(first)
    await store.seed(second)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: first, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: first, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    coordinator.meetingDidStop(id: first)
    _ = await coordinator.meetingWillStart(id: second, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: second, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    let deletion = Task { await coordinator.meetingWillDelete(id: first) }
    await Task.yield()
    await gate.open()
    await deletion.value
    await settle { coordinator.status?.meetingID == second && coordinator.status?.state == .live }
    let active = await lifecycle.snapshot()
    XCTAssertTrue(active.leased)
    await coordinator.shutdown()
    let stopped = await lifecycle.snapshot()
    XCTAssertFalse(stopped.leased)
  }

  func testPauseWaitsForFailedTimerBatchThenRetriesPendingText() async throws {
    let clock = FakeMeetingClock()
    let store = FakeTranscriptStore()
    let gate = TranscriptBatchGate()
    await store.holdNextBatch(gate)
    await store.failBatches(1)
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    let source = try FakeAnalysisTap()
    for _ in 0..<76 {
      let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4_096)!
      buffer.frameLength = 4_096
      buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
      taps?[.microphone]?.push(buffer)
      await coordinator.tick()
      await Task.yield()
    }
    await clock.advance(by: .seconds(2))
    for _ in 0..<500 {
      if await gate.entered { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    let entered = await gate.entered
    XCTAssertTrue(entered)
    coordinator.meetingDidPause(id: id)
    await gate.open()
    await coordinator.shutdown()
    let segments = await store.segments
    XCTAssertFalse(segments.isEmpty)
    XCTAssertEqual(segments.map(\.ordinal), Array(0..<segments.count))
    XCTAssertEqual(coordinator.status?.provisionalCount, segments.count)
    XCTAssertNotEqual(coordinator.status?.state, .failed)
  }

  func testDisabledMeetingNeverLoadsOrStartsAnalysis() async throws {
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id, requested: false)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, recorder: capture.recorder)
    let initial = await coordinator.meetingWillStart(id: id, options: .init(transcription: false))
    XCTAssertEqual(initial, .notRequested)
    for sequence in 1...2 {
      XCTAssertNil(
        coordinator.stretchDidStart(
          meetingID: id, sequence: sequence,
          tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
      await coordinator.tick()
      coordinator.meetingDidPause(id: id)
    }
    await coordinator.shutdown()
    XCTAssertEqual(coordinator.status?.state, .notRequested)
    XCTAssertFalse(coordinator.isFinalizing)
    let model = await lifecycle.snapshot()
    XCTAssertFalse(model.loaded)
    let segments = await store.segments
    let gaps = await store.liveGaps
    XCTAssertTrue(segments.isEmpty)
    XCTAssertTrue(gaps.isEmpty)
    let samples = try await capture.samples()
    XCTAssertFalse(samples.contains { $0["phase"] as? String == "transcriptLive" })
  }

  func testPauseRetainsLeaseThenExpiresAndResumePreservesTimeline() async throws {
    let clock = FakeMeetingClock()
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let first = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(first[.microphone]!, coordinator: coordinator, blocks: 24)
    coordinator.meetingDidPause(id: id)
    await settle { coordinator.status?.liveState == .stopped }
    let retained = await lifecycle.snapshot()
    XCTAssertTrue(retained.leased)
    let before = await store.segments
    XCTAssertFalse(before.isEmpty)
    await clock.advance(by: .seconds(601))
    for _ in 0..<500 {
      if !(await lifecycle.snapshot()).leased { break }
      await Task.yield()
    }
    let expired = await lifecycle.snapshot()
    XCTAssertFalse(expired.leased)
    let second = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 2,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.metadata?.modelReloadCount == 1 }
    try await feed(second[.microphone]!, coordinator: coordinator, blocks: 24)
    coordinator.meetingDidPause(id: id)
    await settle { coordinator.status?.liveState == .stopped }
    let segments = await store.segments
    let resumed = segments.filter { $0.draft.stretchSequence == 2 }
    XCTAssertFalse(resumed.isEmpty)
    XCTAssertEqual(resumed.first?.draft.windowIndex, 0)
    XCTAssertEqual(resumed.first?.startMs, 2_048)
    XCTAssertEqual(segments.map(\.ordinal), Array(0..<segments.count))
    XCTAssertTrue(segments.allSatisfy { $0.draft.endMs <= $0.draft.coveredMs })
    XCTAssertEqual(
      coordinator.status?.metadata?.analysisDescriptor?.stretches.map(\.lengthMs), [2_048, 2_048])
    await coordinator.shutdown()
  }

  func testThirtyMinutesAtThreeTimesSlowdownStaysBoundedAndRecordsGaps() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(18), clock: clock)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    var states = Set<LiveState>()
    for _ in 0..<1_800 {
      try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 12)
      await clock.advance(by: .seconds(1))
      if let state = coordinator.status?.liveState { states.insert(state) }
      XCTAssertLessThanOrEqual(coordinator.analysisQueueHighWater, 480_000)
      XCTAssertLessThanOrEqual(coordinator.pendingSegmentCount, 200)
      XCTAssertLessThanOrEqual(coordinator.analysisGapRangeCount, LiveRecognizer.maximumGapRanges)
    }
    XCTAssertEqual(coordinator.status?.state, .live)
    XCTAssertTrue(states.contains(.catchingUp))
    XCTAssertTrue(states.contains(.degraded))
    let gaps = await store.liveGaps
    XCTAssertTrue(gaps.contains { $0.reason == .backpressure })
    let sorted = gaps.sorted { $0.startMs < $1.startMs }
    for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertLessThanOrEqual(a.endMs, b.startMs) }
    XCTAssertTrue(sorted.allSatisfy { $0.startMs >= 0 && $0.endMs <= 1_843_200 })
    let sizes = await store.batchSizes
    XCTAssertTrue(sizes.allSatisfy { $0 <= 50 })
    await coordinator.meetingWillDelete(id: id)
  }

  func testFullQueueSuspendsThenResumesWithoutOverlappingGaps() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(60), clock: clock)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.isWindowInFlight }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 480)
    XCTAssertEqual(coordinator.status?.liveState, .suspended)
    XCTAssertEqual(coordinator.analysisQueueHighWater, 480_000)
    let row = await store.transcription(meetingID: id)
    XCTAssertEqual(row?.liveState, coordinator.status?.liveState)
    let gaps = await store.liveGaps
    XCTAssertEqual(gaps.filter { $0.reason == .suspended }.count, 1)
    await clock.advance(by: .seconds(61))
    await coordinator.tick()
    await settle { coordinator.status?.liveState != .suspended }
    XCTAssertEqual(coordinator.status?.state, .live)
    let all = await store.liveGaps.sorted { $0.startMs < $1.startMs }
    for (a, b) in zip(all, all.dropFirst()) { XCTAssertLessThanOrEqual(a.endMs, b.startMs) }
    await coordinator.meetingWillDelete(id: id)
  }

  func testPauseAllowsOneTailThenRecordsRemainderAndQuickResumeKeepsLease() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(18), clock: clock)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.isWindowInFlight }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 240)
    coordinator.meetingDidPause(id: id)
    await clock.advance(by: .seconds(19))
    for _ in 0..<500 {
      if await runtime.sampleCounts.count == 2 { break }
      await Task.yield()
    }
    await clock.advance(by: .seconds(19))
    await settle { coordinator.status?.liveState == .stopped }
    let calls = await runtime.sampleCounts
    XCTAssertEqual(calls.count, 2, "one in-flight window plus at most one pause tail")
    let gaps = await store.liveGaps
    XCTAssertEqual(gaps.filter { $0.reason == .pauseDrain }.count, 1)
    await clock.advance(by: .seconds(30))
    let pausedCalls = await runtime.sampleCounts
    XCTAssertEqual(pausedCalls, calls)
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 2,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.liveState == .live }
    XCTAssertEqual(coordinator.status?.metadata?.modelReloadCount, 0)
    let model = await lifecycle.snapshot()
    XCTAssertTrue(model.leased)
    await coordinator.shutdown()
  }

  func testReloadGapAccountsForAudioCapturedWhileModelLoads() async throws {
    let clock = FakeMeetingClock()
    let gate = TranscriptLoadGate()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.waitOnReload()
      return FakeTranscriptionRuntime()
    }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    coordinator.meetingDidPause(id: id)
    await settle { coordinator.status?.liveState == .stopped }
    await clock.advance(by: .seconds(601))
    for _ in 0..<500 {
      if !(await lifecycle.snapshot()).leased { break }
      await Task.yield()
    }
    try await lifecycle.unloadIfIdle()
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 2,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 24)
    await gate.open()
    await settle { coordinator.status?.metadata?.modelReloadCount == 1 }
    for _ in 0..<500 {
      if await store.liveGaps.contains(where: { $0.reason == .modelReload }) { break }
      await Task.yield()
    }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 24)
    coordinator.meetingDidPause(id: id)
    await settle { coordinator.status?.liveState == .stopped }
    let gaps = await store.liveGaps
    let reload = try XCTUnwrap(gaps.first { $0.reason == .modelReload })
    XCTAssertEqual(reload.stretchSequence, 2)
    XCTAssertEqual(reload.startMs, 0)
    XCTAssertGreaterThan(reload.endMs, 2_000)
    let segments = await store.segments
    XCTAssertTrue(segments.allSatisfy { $0.startMs >= reload.endMs })
    await coordinator.shutdown()
  }

  func testTapOverflowRecordsGapWithoutFailingTheLivePass() async throws {
    let store = FakeTranscriptStore()
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
    block.frameLength = 4_096
    block.floatChannelData![0].initialize(repeating: 0, count: 4_096)
    for _ in 0..<80 { taps[.microphone]?.push(block) }
    coordinator.meetingDidPause(id: id)
    await settle { coordinator.status?.liveState == .stopped }
    XCTAssertEqual(coordinator.status?.state, .live)
    let gaps = await store.liveGaps
    let overflow = try XCTUnwrap(gaps.first { $0.reason == .tapOverflow })
    XCTAssertEqual(overflow.endMs - overflow.startMs, 4_096)
    XCTAssertEqual(
      coordinator.status?.metadata?.analysisDescriptor?.stretches.first?.lengthMs, 6_826)
    await coordinator.shutdown()
  }

  // MARK: Phase 8: stop drain and automatic finalization (US5)

  /// Everything a live → final run needs on a real store: the Feature 004 meeting
  /// with track files, the transcript store and a finalizer over the same files.
  private struct FinalizingHarness {
    let fixture: MeetingTestStore
    let meeting: TranscriptMeetingFixture
    let store: TranscriptStore
    let lifecycle: ModelLifecycleCoordinator
    let coordinator: MeetingTranscriptionCoordinator
    let meetings: LoggingMeetingStore

    @MainActor
    static func make(
      runtime: FakeTranscriptionRuntime = FakeTranscriptionRuntime(), clock: FakeMeetingClock,
      stretches: [TranscriptMeetingFixture.Stretch] = [.init()],
      recorder: ResourceRecorder? = nil
    ) async throws -> Self {
      let fixture = try MeetingTestStore.make()
      let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: stretches)
      let store = TranscriptStore(database: fixture.history.database)
      let lifecycle = ModelLifecycleCoordinator { runtime }
      let meetings = LoggingMeetingStore(fixture.store)
      let finalizer = MeetingFinalizer(
        store: store, meetings: meetings, storageRoot: fixture.root, lifecycle: lifecycle,
        clock: clock, recorder: recorder)
      let coordinator = MeetingTranscriptionCoordinator(
        store: store, lifecycle: lifecycle, clock: clock, recorder: recorder,
        finalizer: finalizer)
      return .init(
        fixture: fixture, meeting: meeting, store: store, lifecycle: lifecycle,
        coordinator: coordinator, meetings: meetings)
    }
    func cleanup() { fixture.cleanup() }
  }

  func testStopDrainsThenCompleteStartsFinalizationWithoutUserAction() async throws {
    let clock = FakeMeetingClock()
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let runtime = FakeTranscriptionRuntime(delay: .seconds(18), clock: clock)
    // Stretch 1 decodes to ~17 s so the live gap (inside the first 5 s) is covered.
    let harness = try await FinalizingHarness.make(
      runtime: runtime, clock: clock,
      stretches: [.init(microphone: .blocks(200), system: .blocks(200)), .init()],
      recorder: capture.recorder)
    defer { harness.cleanup() }
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.isWindowInFlight }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 120)
    coordinator.meetingDidStop(id: id)
    // The in-flight window finishes within the 30 s bound; queued audio drains to a gap.
    await clock.advance(by: .seconds(19))
    await settle { coordinator.status?.state == .finalizing }
    XCTAssertFalse(coordinator.isFinalizing, "finalization waits for meetingDidComplete")
    let gaps = try await harness.store.gaps(meetingID: id)
    XCTAssertEqual(gaps.filter { $0.reason == .stopDrain }.count, 1)
    let released = await harness.lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    let provisionalBefore = coordinator.status?.provisionalCount ?? 0
    XCTAssertGreaterThan(provisionalBefore, 0)
    let detailValue = try await harness.fixture.store.detail(id: id)
    let detail = try XCTUnwrap(detailValue)
    await runtime.setDelay(.zero)
    coordinator.meetingDidComplete(id: id, detail: detail)
    await settle { coordinator.isFinalizing || coordinator.status?.state == .final }
    await settle { coordinator.status?.state == .final }
    XCTAssertFalse(coordinator.isFinalizing)
    let outcome = try XCTUnwrap(coordinator.lastFinalization)
    XCTAssertEqual(outcome.row.replacedProvisionalCount, provisionalBefore)
    XCTAssertEqual(outcome.totalGapCount, gaps.count)
    XCTAssertGreaterThanOrEqual(outcome.coveredGapCount, 1, "the live gap is covered by the pass")
    XCTAssertEqual(coordinator.status?.progress, 1)
    XCTAssertEqual(coordinator.status?.finalCount, outcome.row.segmentCount)
    XCTAssertEqual(coordinator.status?.provisionalCount, 0)
    let remainingGaps = try await harness.store.gaps(meetingID: id)
    XCTAssertTrue(remainingGaps.isEmpty)
    let leaseAfter = await harness.lifecycle.snapshot()
    XCTAssertFalse(leaseAfter.leased)
    XCTAssertEqual(Set(harness.meetings.calls), ["detail"])
    let samples = try await capture.samples()
    XCTAssertTrue(samples.contains { $0["phase"] as? String == "transcriptFinalizing" })
    await coordinator.shutdown()
  }

  func testStopCancelsInflightInferenceAfterThirtySecondsAndStillFinalizes() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(90), clock: clock)
    let harness = try await FinalizingHarness.make(runtime: runtime, clock: clock)
    defer { harness.cleanup() }
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.isWindowInFlight }
    coordinator.meetingDidStop(id: id)
    await clock.advance(by: .seconds(29))
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertNotEqual(coordinator.status?.state, .finalizing, "still waiting inside the bound")
    await clock.advance(by: .seconds(2))
    await settle { coordinator.status?.state == .finalizing }
    let detailValue = try await harness.fixture.store.detail(id: id)
    let detail = try XCTUnwrap(detailValue)
    // Finalization reuses the lifecycle after the revoked session; the runtime is
    // recreated with no delay so the pass completes on the test clock.
    await runtime.setDelay(.zero)
    coordinator.meetingDidComplete(id: id, detail: detail)
    await settle { coordinator.status?.state == .final }
    await coordinator.shutdown()
  }

  func testFinalizationQueueIsFIFOBoundedAndWaitsForTheLiveSession() async throws {
    let clock = FakeMeetingClock()
    let store = FakeTranscriptStore()
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let live = UUID()
    await store.seed(live)
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let realDetailValue = try await fixture.store.detail(id: meeting.meetingID)
    let realDetail = try XCTUnwrap(realDetailValue)
    let meetings = StubMeetingStore(detail: realDetail)
    let finalizer = MeetingFinalizer(
      store: store, meetings: meetings, storageRoot: fixture.root, lifecycle: lifecycle,
      clock: clock)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock, finalizer: finalizer)
    var notices: [String] = []
    coordinator.noticePublished = { notices.append($0) }
    _ = await coordinator.meetingWillStart(id: live, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: live, sequence: 1, tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .live }
    var queued: [UUID] = []
    for _ in 0..<100 {
      let id = UUID()
      await store.seed(id, requested: false)
      queued.append(id)
      coordinator.requestFinalization(meetingID: id, revision: 0)
    }
    XCTAssertEqual(coordinator.queuedFinalizationCount, 100)
    let overflow = UUID()
    await store.seed(overflow, requested: false)
    coordinator.requestFinalization(meetingID: overflow, revision: 0)
    XCTAssertEqual(coordinator.queuedFinalizationCount, 100)
    XCTAssertEqual(notices, [TranscriptErrorMessage.tooManyWaiting])
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(coordinator.isFinalizing, "nothing runs while a live session exists")
    XCTAssertTrue(meetings.detailCalls.isEmpty)
    coordinator.meetingDidStop(id: live)
    await settle { coordinator.queuedFinalizationCount == 0 && !coordinator.isFinalizing }
    XCTAssertEqual(meetings.detailCalls, queued, "FIFO, one at a time")
    // Every queued transcript went not_requested → pending → finalizing → final on the fake.
    for id in queued {
      let row = await store.transcription(meetingID: id)
      XCTAssertEqual(row?.state, .final)
    }
    await coordinator.shutdown()
  }

  func testNewLiveSessionPreemptsFinalizationWhichResumesAfterwards() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(5), clock: clock)
    let harness = try await FinalizingHarness.make(
      runtime: runtime, clock: clock, stretches: [.init(), .init(), .init()])
    defer { harness.cleanup() }
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    let revisionValue = try await harness.store.transcription(meetingID: id)
    let revision = try XCTUnwrap(revisionValue).revision
    coordinator.requestFinalization(meetingID: id, revision: revision)
    await settle { coordinator.isFinalizing }
    for _ in 0..<500 {
      if await runtime.active == 1 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    // A meeting starts with transcription: the pass yields at the window boundary.
    let second = try await TranscriptMeetingFixture.make(
      in: harness.fixture, stretches: [.init()], startedAt: 1_800_000_000_000)
    _ = await coordinator.meetingWillStart(
      id: second.meetingID, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: second.meetingID, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { !coordinator.isFinalizing }
    XCTAssertEqual(coordinator.queuedFinalizationCount, 1, "re-queued at the head")
    await runtime.setDelay(.zero)
    await settle {
      coordinator.status?.meetingID == second.meetingID && coordinator.status?.state == .live
    }
    let paused = try await harness.store.transcription(meetingID: id)
    XCTAssertEqual(paused?.state, .finalizing)
    coordinator.meetingDidStop(id: second.meetingID)
    let secondDetailValue = try await harness.fixture.store.detail(id: second.meetingID)
    coordinator.meetingDidComplete(id: second.meetingID, detail: try XCTUnwrap(secondDetailValue))
    var final: MeetingTranscription?
    for _ in 0..<1_000 {
      final = try await harness.store.transcription(meetingID: id)
      if final?.state == .final { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertEqual(final?.state, .final)
    XCTAssertEqual(final?.analysisDescriptor?.stretches.count, 3)
    await settle { !coordinator.isFinalizing && coordinator.queuedFinalizationCount == 0 }
    let secondRow = try await harness.store.transcription(meetingID: second.meetingID)
    XCTAssertEqual(secondRow?.state, .final, "the stopped meeting finalizes after the head")
    await coordinator.shutdown()
  }

  func testDeletionDuringFinalizationCancelsAndDropsTheRequest() async throws {
    let clock = FakeMeetingClock()
    let runtime = FakeTranscriptionRuntime(delay: .seconds(5), clock: clock)
    let harness = try await FinalizingHarness.make(runtime: runtime, clock: clock)
    defer { harness.cleanup() }
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    // Exercise the bounded tombstone set rollover before deleting the active pass.
    for _ in 0..<1_000 { await coordinator.meetingWillDelete(id: UUID()) }
    let revisionValue = try await harness.store.transcription(meetingID: id)
    coordinator.requestFinalization(meetingID: id, revision: try XCTUnwrap(revisionValue).revision)
    await settle { coordinator.isFinalizing }
    for _ in 0..<500 {
      if await runtime.active == 1 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    await coordinator.meetingWillDelete(id: id)
    XCTAssertFalse(coordinator.isFinalizing)
    XCTAssertEqual(coordinator.queuedFinalizationCount, 0)
    let released = await harness.lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    await coordinator.shutdown()
  }

  // MARK: Phase 9: failure separation (US6)

  func testAcquisitionFailuresMapToModelCategoriesAndLeaveNoTapOrLease() async throws {
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let cases: [(Error, TranscriptFailureCategory)] = [
      (DictationFailure.modelUnavailable, .modelUnavailable),
      (ModelProvisioner.Error.incompleteManifest, .modelProvisioning),
      (DictationFailure.invalidAudio, .modelLoadFailure),
    ]
    for (thrown, expected) in cases {
      let lifecycle = ModelLifecycleCoordinator { throw thrown }
      let store = FakeTranscriptStore()
      let id = UUID()
      await store.seed(id)
      let coordinator = MeetingTranscriptionCoordinator(
        store: store, lifecycle: lifecycle, recorder: capture.recorder)
      _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
      let taps = coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
      await settle { coordinator.status?.state == .failed }
      XCTAssertEqual(coordinator.status?.failure, expected)
      let row = await store.transcription(meetingID: id)
      XCTAssertEqual(row?.state, .failed)
      XCTAssertEqual(row?.failureCategory, expected)
      XCTAssertEqual(coordinator.installedTapCount, 0)
      XCTAssertEqual(taps?.count, 1, "the tap handed out is detached, not retained")
      let snapshot = await lifecycle.snapshot()
      XCTAssertFalse(snapshot.leased)
      XCTAssertFalse(snapshot.loaded)
      XCTAssertNil(
        coordinator.stretchDidStart(
          meetingID: id, sequence: 2,
          tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
      await coordinator.shutdown()
    }
    let samples = try await capture.samples()
    let keys = samples.filter { $0["metric"] as? String == "transcriptFailure" }
      .compactMap { $0["meetingKey"] as? String }
    XCTAssertEqual(
      Set(keys), ["model_unavailable", "model_provisioning", "model_load_failure"])
    // The transcription coordinator owns no meeting store: `meetings.*` is unreachable.
    let mirror = Mirror(
      reflecting: MeetingTranscriptionCoordinator(
        store: FakeTranscriptStore(),
        lifecycle: ModelLifecycleCoordinator { FakeTranscriptionRuntime() }))
    XCTAssertFalse(mirror.children.contains { $0.value is any MeetingStoring })
  }

  func testNthWindowFailureKeepsEarlierRowsDetachesTapsAndFinishesLease() async throws {
    let clock = FakeMeetingClock()
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let runtime = FakeTranscriptionRuntime(failureOnCall: 3)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock, recorder: capture.recorder)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    for _ in 0..<3 {
      try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
      await settle { !coordinator.isWindowInFlight }
      await clock.advance(by: .seconds(3))
      await coordinator.tick()
    }
    await settle { coordinator.status?.state == .failed }
    XCTAssertEqual(coordinator.status?.failure, .runtimeFailure)
    let row = await store.transcription(meetingID: id)
    XCTAssertEqual(row?.failureCategory, .runtimeFailure)
    let segments = await store.segments
    XCTAssertEqual(segments.count, 2, "the two windows before the failure are kept")
    XCTAssertEqual(coordinator.installedTapCount, 0)
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    // Recording continues: later stretches are ignored by the failed transcript.
    XCTAssertNil(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 2,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    coordinator.meetingDidStop(id: id)
    await coordinator.shutdown()
    let after = await store.transcription(meetingID: id)
    XCTAssertEqual(after?.state, .failed, "a failed live pass is not auto-finalized")
    let samples = try await capture.samples()
    XCTAssertTrue(
      samples.contains {
        $0["metric"] as? String == "transcriptFailure"
          && $0["meetingKey"] as? String == "runtime_failure"
      })
  }

  func testFourConsecutiveBatchFailuresAndCapacityMapToPersistenceCategories() async throws {
    for (setup, expected) in [
      (
        { (store: FakeTranscriptStore) async in await store.failBatches(4) },
        TranscriptFailureCategory.persistenceFailure
      ),
      (
        { (store: FakeTranscriptStore) async in await store.setSegmentCapacity(0) },
        .persistenceCapacity
      ),
    ] {
      let clock = FakeMeetingClock()
      let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
      let store = FakeTranscriptStore()
      let id = UUID()
      await store.seed(id)
      await setup(store)
      let coordinator = MeetingTranscriptionCoordinator(
        store: store, lifecycle: lifecycle, clock: clock)
      _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
      let taps = try XCTUnwrap(
        coordinator.stretchDidStart(
          meetingID: id, sequence: 1,
          tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
      await settle { coordinator.status?.state == .live }
      try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
      await settle { !coordinator.isWindowInFlight }
      for _ in 0..<5 {
        await clock.advance(by: .seconds(3))
        await coordinator.tick()
        await Task.yield()
      }
      await settle { coordinator.status?.state == .failed }
      XCTAssertEqual(coordinator.status?.failure, expected)
      let row = await store.transcription(meetingID: id)
      XCTAssertEqual(row?.failureCategory, expected)
      XCTAssertEqual(coordinator.installedTapCount, 0)
      let released = await lifecycle.snapshot()
      XCTAssertFalse(released.leased)
      await coordinator.shutdown()
    }
  }

  func testVocabularySnapshotFailureIsRuntimeFailureWithDetailAndTakesNoLease() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let store = FakeTranscriptStore()
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, vocabulary: FailingVocabulary())
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    await settle { coordinator.status?.state == .failed }
    XCTAssertEqual(coordinator.status?.failure, .runtimeFailure)
    let row = await store.transcription(meetingID: id)
    XCTAssertEqual(row?.failureDetail, "vocabulary_unavailable")
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.loaded)
    await coordinator.shutdown()
  }

  func testFailureIsPublishedOnlyAfterTheRowCommitted() async throws {
    let gate = TranscriptBatchGate()
    let store = FakeTranscriptStore()
    await store.holdNextTransition(gate)
    let lifecycle = ModelLifecycleCoordinator { throw DictationFailure.modelUnavailable }
    let id = UUID()
    await store.seed(id)
    let coordinator = MeetingTranscriptionCoordinator(store: store, lifecycle: lifecycle)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    _ = coordinator.stretchDidStart(
      meetingID: id, sequence: 1,
      tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)])
    for _ in 0..<500 {
      if await gate.entered { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertNil(coordinator.status?.failure, "not published while the write is pending")
    await gate.open()
    await settle { coordinator.status?.failure == .modelUnavailable }
    let row = await store.transcription(meetingID: id)
    XCTAssertEqual(row?.state, .failed)
    await coordinator.shutdown()
  }

  func testRetryAfterLiveFailureProducesFinalThroughTheFinalizer() async throws {
    let clock = FakeMeetingClock()
    let harness = try await FinalizingHarness.make(
      runtime: FakeTranscriptionRuntime(failureOnCall: 1), clock: clock)
    defer { harness.cleanup() }
    let digests = try harness.meeting.fileDigests()
    let listing = fileListing(under: harness.fixture.directory)
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { coordinator.status?.state == .failed }
    XCTAssertEqual(try harness.meeting.fileDigests(), digests)
    XCTAssertEqual(fileListing(under: harness.fixture.directory), listing)
    coordinator.meetingDidStop(id: id)
    let detailValue = try await harness.fixture.store.detail(id: id)
    coordinator.meetingDidComplete(id: id, detail: try XCTUnwrap(detailValue))
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(coordinator.status?.state, .failed)
    let failedRow = try await harness.store.transcription(meetingID: id)
    coordinator.requestFinalization(meetingID: id, revision: try XCTUnwrap(failedRow).revision)
    await settle { coordinator.status?.state == .final }
    XCTAssertNil(coordinator.status?.failure)
    XCTAssertEqual(try harness.meeting.fileDigests(), digests)
    XCTAssertEqual(fileListing(under: harness.fixture.directory), listing)
    // A stale revision is refused with a notice and writes nothing.
    var notices: [String] = []
    coordinator.noticePublished = { notices.append($0) }
    coordinator.requestFinalization(meetingID: id, revision: 0)
    await settle { !notices.isEmpty }
    XCTAssertEqual(notices, [TranscriptErrorMessage.changed])
    await coordinator.shutdown()
  }

  // MARK: Phase 11: notes stay independent (US8)

  func testNotesAreByteIdenticalAndNeverReadByTranscriptTypes() async throws {
    let clock = FakeMeetingClock()
    let phrase = "zebra-quokka-\(UUID().uuidString)"
    let harness = try await FinalizingHarness.make(
      runtime: FakeTranscriptionRuntime(windows: [
        .init(text: "spoken words only", tokens: [])
      ]), clock: clock, stretches: [.init(), .init()])
    defer { harness.cleanup() }
    let coordinator = harness.coordinator
    let id = harness.meeting.meetingID
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    let liveNotes = "During live: \(phrase) — line one\nline two"
    let notesValue = try await harness.fixture.store.notes(meetingID: id)
    var revision = try XCTUnwrap(notesValue).revision
    revision = try await harness.fixture.store.saveNotes(
      meetingID: id, text: liveNotes, revision: revision, now: 10)
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    coordinator.meetingDidStop(id: id)
    await settle { coordinator.status?.state == .finalizing }
    let finalizingNotes = liveNotes + "\nDuring finalization: \(phrase) again"
    _ = try await harness.fixture.store.saveNotes(
      meetingID: id, text: finalizingNotes, revision: revision, now: 11)
    let detailValue = try await harness.fixture.store.detail(id: id)
    coordinator.meetingDidComplete(id: id, detail: try XCTUnwrap(detailValue))
    await settle { coordinator.status?.state == .final }
    let afterValue = try await harness.fixture.store.notes(meetingID: id)
    let after = try XCTUnwrap(afterValue)
    XCTAssertEqual(Array(after.text.utf8), Array(finalizingNotes.utf8))
    let segments = try await harness.store.page(
      meetingID: id, finality: .final, after: nil, limit: 200)
    XCTAssertFalse(segments.isEmpty)
    for segment in segments {
      XCTAssertFalse(segment.draft.rawText.contains(phrase))
      XCTAssertFalse(segment.draft.assembledText.contains(phrase))
      XCTAssertFalse(segment.normalizedText.contains(phrase))
    }
    XCTAssertEqual(
      Set(harness.meetings.calls).subtracting(["detail"]), [],
      "no transcript type reads or writes notes")
    await coordinator.shutdown()
  }

  // MARK: Phase 14: pass vocabulary and source integrity

  func testVocabularyEditsStayOutOfLivePassAndFinalizationTakesANewSnapshot() async throws {
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let store = TranscriptStore(database: fixture.history.database)
    let vocabulary = VocabularyStore(history: fixture.history)
    let entry = VocabularyEntry(canonical: "Kubernetes", aliases: ["kube"])
    try await vocabulary.save(entry)
    let initial = try await vocabulary.snapshot()
    let runtime = FakeTranscriptionRuntime(windows: [.init(text: "kube", tokens: [])])
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let clock = FakeMeetingClock()
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      vocabulary: vocabulary, clock: clock)
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, vocabulary: vocabulary, clock: clock,
      finalizer: finalizer)
    let id = meeting.meetingID
    let digests = try meeting.fileDigests()
    let listing = fileListing(under: fixture.directory)
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { !coordinator.isWindowInFlight }
    try await vocabulary.save(
      VocabularyEntry(id: entry.id, canonical: "K8s", aliases: ["kube"]))
    let edited = try await vocabulary.snapshot()
    XCTAssertNotEqual(initial.revision, edited.revision)
    XCTAssertNotEqual(initial.hash, edited.hash)
    try await feed(taps[.microphone]!, coordinator: coordinator, blocks: 76)
    await settle { !coordinator.isWindowInFlight }
    coordinator.meetingDidPause(id: id)
    await settle { (coordinator.status?.provisionalCount ?? 0) >= 2 }
    let liveRow = try await store.transcription(meetingID: id)
    XCTAssertEqual(liveRow?.vocabularyRevision, initial.revision)
    XCTAssertEqual(liveRow?.vocabularyHash, initial.hash)
    let live = try await store.page(meetingID: id, finality: .provisional, after: nil, limit: 200)
    XCTAssertGreaterThanOrEqual(live.count, 2)
    XCTAssertTrue(live.allSatisfy { $0.normalizedText.contains("Kubernetes") })
    XCTAssertFalse(live.contains { $0.normalizedText.contains("K8s") })
    XCTAssertEqual(try meeting.fileDigests(), digests)
    XCTAssertEqual(fileListing(under: fixture.directory), listing)
    coordinator.meetingDidStop(id: id)
    await settle { coordinator.status?.state == .finalizing }
    let detail = try await fixture.store.detail(id: id)
    coordinator.meetingDidComplete(id: id, detail: try XCTUnwrap(detail))
    await settle { coordinator.status?.state == .final }
    let finalRow = try await store.transcription(meetingID: id)
    XCTAssertEqual(finalRow?.vocabularyRevision, edited.revision)
    XCTAssertEqual(finalRow?.vocabularyHash, edited.hash)
    let final = try await store.page(meetingID: id, finality: .final, after: nil, limit: 200)
    XCTAssertFalse(final.isEmpty)
    XCTAssertTrue(final.allSatisfy { $0.normalizedText.contains("K8s") })
    XCTAssertEqual(try meeting.fileDigests(), digests)
    XCTAssertEqual(fileListing(under: fixture.directory), listing)
    await coordinator.shutdown()
  }

  private func feed(
    _ tap: MeetingAnalysisTap, coordinator: MeetingTranscriptionCoordinator,
    blocks: Int
  ) async throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
    block.frameLength = 4_096
    block.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
    for _ in 0..<blocks {
      tap.push(block)
      await coordinator.tick()
      await Task.yield()
    }
  }

  private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Condition did not settle")
  }
}

actor TranscriptLoadGate {
  private var loads = 0
  func waitOnReload() async {
    loads += 1
    if loads > 1 { await wait() }
  }
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}
