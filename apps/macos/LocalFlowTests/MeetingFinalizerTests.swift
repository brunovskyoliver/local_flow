import AVFoundation
import GRDB
import XCTest

@testable import LocalFlow

/// FR-010 to FR-012, FR-018 and US5/US6: the final pass over durable audio.
final class MeetingFinalizerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: TranscriptStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  private func makeFinalizer(
    runtime: FakeTranscriptionRuntime = FakeTranscriptionRuntime(),
    lifecycle: ModelLifecycleCoordinator? = nil,
    meetings: (any MeetingStoring)? = nil,
    vocabulary: any VocabularyProviding = EmptyVocabularyProvider(),
    clock: any MeetingClock = FakeMeetingClock(), recorder: ResourceRecorder? = nil
  ) -> (MeetingFinalizer, ModelLifecycleCoordinator) {
    let lifecycle = lifecycle ?? ModelLifecycleCoordinator { runtime }
    let finalizer = MeetingFinalizer(
      store: store, meetings: meetings ?? fixture.store, storageRoot: fixture.root,
      lifecycle: lifecycle, vocabulary: vocabulary, clock: clock, recorder: recorder)
    return (finalizer, lifecycle)
  }

  private func revision(_ id: UUID) async throws -> Int64 {
    let row = try await store.transcription(meetingID: id)
    return try XCTUnwrap(row).revision
  }

  // MARK: Admission

  func testAdmissionChecksRevisionTerminalStateAndSourceAudio() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let (finalizer, lifecycle) = makeFinalizer()
    let beforeValue = try await store.transcription(meetingID: meeting.meetingID)
    let before = try XCTUnwrap(beforeValue)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: before.revision + 5)
      XCTFail("stale revision admitted")
    } catch { XCTAssertEqual(error as? MeetingFinalizer.Error, .staleRevision) }
    let unchanged = try await store.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(unchanged, before)

    // A meeting that is still active is refused before any transition.
    let active = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], startedAt: 1_800_000_000_000, finalState: .interrupted)
    let activeRevision = try await revision(active.meetingID)
    let outcome = try await finalizer.run(meetingID: active.meetingID, revision: activeRevision)
    XCTAssertEqual(outcome.row.state, .final, "an interrupted meeting is terminal and admitted")

    // No track file at all: refused with guidance, no lease taken, row untouched.
    let silent = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .missing, system: .unrecoverable)],
      startedAt: 1_900_000_000_000)
    let silentBeforeValue = try await store.transcription(meetingID: silent.meetingID)
    let silentBefore = try XCTUnwrap(silentBeforeValue)
    do {
      _ = try await finalizer.run(meetingID: silent.meetingID, revision: silentBefore.revision)
      XCTFail("no source audio admitted")
    } catch { XCTAssertEqual(error as? MeetingFinalizer.Error, .noSourceAudio) }
    let silentAfter = try await store.transcription(meetingID: silent.meetingID)
    XCTAssertEqual(silentAfter, silentBefore)
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(
      TranscriptErrorMessage.noSourceAudio, "No recorded audio is available to transcribe.")
  }

  func testAdmissionTransitionsToFinalizingWithNewPassAndRecordedMs() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let gate = TranscriptLoadGate()
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let (finalizer, _) = makeFinalizer(lifecycle: lifecycle)
    let beforeValue = try await store.transcription(meetingID: meeting.meetingID)
    let before = try XCTUnwrap(beforeValue)
    let detailValue = try await fixture.store.detail(id: meeting.meetingID)
    let detail = try XCTUnwrap(detailValue)
    let task = Task {
      try await finalizer.run(meetingID: meeting.meetingID, revision: before.revision)
    }
    var admitted: MeetingTranscription?
    for _ in 0..<500 {
      if let row = try await store.transcription(meetingID: meeting.meetingID),
        row.state == .finalizing
      {
        admitted = row
        break
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    let row = try XCTUnwrap(admitted)
    XCTAssertEqual(row.passKind, .final)
    XCTAssertNotNil(row.passID)
    XCTAssertNotEqual(row.passID, before.passID)
    XCTAssertEqual(row.recordedMsAtPass, detail.meeting.recordedMs)
    XCTAssertNotNil(row.finalizationStartedAt)
    XCTAssertNil(row.progressSequence)
    await gate.open()
    let outcome = try await task.value
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.plannerVersion, MeetingFinalizer.geometry)
    XCTAssertTrue(outcome.row.pipelineVersion?.hasPrefix(MeetingFinalizer.geometry + "+") == true)
  }

  // MARK: Decode and windows

  func testDecodeFillsOneProductionWindowAtATimeAndPersistsPerStretch() async throws {
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    // 180 blocks = 737,280 frames at 48 kHz ≈ 245,760 analysis samples: one full
    // window plus a remainder for stretch 1, a short tail for stretch 2.
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture,
      stretches: [.init(microphone: .blocks(180), system: .blocks(180)), .init()])
    let hashesBefore = try meeting.fileHashes()
    let runtime = FakeTranscriptionRuntime(windows: [
      .init(
        text: "hello world.",
        tokens: [
          .init(text: "hello", start: 0.1, end: 0.4), .init(text: "world.", start: 0.5, end: 0.9),
        ])
    ])
    let (finalizer, lifecycle) = makeFinalizer(runtime: runtime, recorder: capture.recorder)
    let idle = await finalizer.residentWindowSamples
    XCTAssertEqual(idle, 0, "no window is allocated before a pass")
    let revision = try await revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    let released = await finalizer.residentWindowSamples
    XCTAssertEqual(released, 0, "the pass releases its window")
    let counts = await runtime.sampleCounts
    XCTAssertEqual(counts.count, 3)
    XCTAssertEqual(counts[0], MeetingFinalizer.windowSamples)
    XCTAssertGreaterThan(counts[1], 0)
    XCTAssertLessThan(counts[1], MeetingFinalizer.windowSamples)
    XCTAssertGreaterThan(counts[2], 0)
    XCTAssertTrue(counts.allSatisfy { $0 <= MeetingFinalizer.windowSamples })
    XCTAssertEqual(outcome.windowCount, 3)
    let row = outcome.row
    XCTAssertEqual(row.state, .final)
    XCTAssertEqual(row.passKind, .final)
    let descriptor = try XCTUnwrap(row.analysisDescriptor)
    XCTAssertEqual(descriptor.source, .decodedTracks)
    XCTAssertEqual(descriptor.stretches.map(\.sequence), [1, 2])
    XCTAssertEqual(descriptor.stretches.map(\.tracks), [.both, .both])
    XCTAssertTrue(descriptor.stretches.allSatisfy { $0.lengthMs > 0 })
    XCTAssertEqual(row.coveredMs, descriptor.stretches.reduce(0) { $0 + $1.lengthMs })
    XCTAssertEqual(row.progressSequence, 2)
    XCTAssertEqual(row.progressSample, Int64(counts[2]))
    XCTAssertNotNil(row.finalizedAt)
    XCTAssertEqual(row.vocabularyHash, VocabularySnapshot.empty.hash)
    let segments = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertEqual(segments.count, row.segmentCount)
    XCTAssertEqual(segments.map(\.ordinal), Array(0..<segments.count))
    XCTAssertTrue(segments.allSatisfy { $0.finality == .final && $0.passID == row.passID })
    XCTAssertTrue(
      segments.allSatisfy { $0.draft.pipelineVersion.contains(TranscriptSegmenter.version) })
    XCTAssertTrue(segments.allSatisfy { $0.startMs < $0.endMs && $0.endMs <= row.coveredMs })
    XCTAssertEqual(
      segments.filter { $0.draft.stretchSequence == 1 }.map(\.draft.windowIndex), [0, 1])
    XCTAssertEqual(segments.filter { $0.draft.stretchSequence == 2 }.map(\.draft.windowIndex), [0])
    let base = descriptor.stretches[0].lengthMs
    XCTAssertTrue(
      segments.filter { $0.draft.stretchSequence == 2 }.allSatisfy { $0.startMs >= base })
    XCTAssertEqual(try meeting.fileHashes(), hashesBefore)
    let leased = await lifecycle.snapshot()
    XCTAssertFalse(leased.leased)
    let samples = try await capture.samples()
    let metrics = Set(samples.compactMap { $0["metric"] as? String })
    XCTAssertTrue(metrics.contains("transcriptFinalizationDuration"))
    XCTAssertTrue(metrics.contains("transcriptRealTimeFactor"))
    XCTAssertTrue(metrics.contains("transcriptPersistenceBatchDuration"))
    XCTAssertTrue(metrics.contains("transcriptSegmentsFinal"))
    XCTAssertTrue(
      samples.contains {
        $0["phase"] as? String == "transcriptFinalizing" && $0["meetingKey"] as? String == "final"
      })
  }

  func testCancellationKeepsProgressAndResumeReproducesIdenticalWindows() async throws {
    let clock = FakeMeetingClock()
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init(), .init()])
    let runtime = FakeTranscriptionRuntime(delay: .seconds(1), clock: clock)
    let (finalizer, lifecycle) = makeFinalizer(runtime: runtime, clock: clock)
    let revision = try await revision(meeting.meetingID)
    let first = Task { try await finalizer.run(meetingID: meeting.meetingID, revision: revision) }
    await wait { await runtime.active == 1 }
    await clock.advance(by: .seconds(1))
    // The second stretch's inference is in flight when the pass is cancelled.
    await wait {
      let calls = await runtime.sampleCounts.count
      let active = await runtime.active
      return calls == 2 && active == 1
    }
    first.cancel()
    do {
      _ = try await first.value
      XCTFail("cancelled pass completed")
    } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    let interruptedValue = try await store.transcription(meetingID: meeting.meetingID)
    let interrupted = try XCTUnwrap(interruptedValue)
    XCTAssertEqual(interrupted.state, .finalizing)
    XCTAssertEqual(interrupted.progressSequence, 1)
    XCTAssertNotNil(interrupted.progressSample)
    let persisted = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertFalse(persisted.isEmpty)
    XCTAssertTrue(persisted.allSatisfy { $0.draft.stretchSequence == 1 })
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    let firstRunWindows = await runtime.received

    // A second run with the same identity resumes at stretch 2 and never
    // re-finalizes stretch 1: the same rows, the same pass, identical windows.
    let resumed = FakeTranscriptionRuntime(delay: .zero, clock: clock)
    let (again, _) = makeFinalizer(runtime: resumed, clock: clock)
    let outcome = try await again.run(meetingID: meeting.meetingID, revision: interrupted.revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.passID, interrupted.passID)
    let counts = await resumed.sampleCounts
    XCTAssertEqual(counts.count, 2, "stretches 2 and 3 only")
    let secondRunWindows = await resumed.received
    XCTAssertEqual(secondRunWindows[0], firstRunWindows[1], "byte-identical resumed window")
    let all = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertEqual(Array(all.prefix(persisted.count)), persisted, "stretch 1 rows untouched")
    XCTAssertEqual(all.map(\.ordinal), Array(0..<all.count))
    XCTAssertEqual(Set(all.map(\.draft.stretchSequence)), [1, 2, 3])
    XCTAssertEqual(outcome.row.analysisDescriptor?.stretches.count, 3)
  }

  func testIdentityMismatchDiscardsPartialPassAndRestarts() async throws {
    let clock = FakeMeetingClock()
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init()])
    let runtime = FakeTranscriptionRuntime(delay: .seconds(1), clock: clock)
    let (finalizer, _) = makeFinalizer(runtime: runtime, clock: clock)
    let revision = try await revision(meeting.meetingID)
    let first = Task { try await finalizer.run(meetingID: meeting.meetingID, revision: revision) }
    await wait { await runtime.active == 1 }
    await clock.advance(by: .seconds(1))
    await wait {
      let calls = await runtime.sampleCounts.count
      let active = await runtime.active
      return calls == 2 && active == 1
    }
    first.cancel()
    _ = try? await first.value
    let interruptedValue = try await store.transcription(meetingID: meeting.meetingID)
    let interrupted = try XCTUnwrap(interruptedValue)
    XCTAssertEqual(interrupted.state, .finalizing)
    let partial = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertFalse(partial.isEmpty)
    let changed = FakeTranscriptionRuntime()
    let (restarted, _) = makeFinalizer(
      runtime: changed, vocabulary: RevisionVocabulary(revision: 7), clock: clock)
    let outcome = try await restarted.run(
      meetingID: meeting.meetingID, revision: interrupted.revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertNotEqual(outcome.row.passID, interrupted.passID)
    XCTAssertEqual(outcome.row.vocabularyRevision, 7)
    let counts = await changed.sampleCounts
    XCTAssertEqual(counts.count, 2, "restarted from the first stretch")
    let rows = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertTrue(rows.allSatisfy { $0.passID == outcome.row.passID })
    XCTAssertFalse(rows.contains { partial.map(\.id).contains($0.id) })
    let usage = try await store.usage()
    XCTAssertEqual(usage.segmentRows, rows.count)
  }

  func testSingleTrackStretchesAndSkippedStretches() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture,
      stretches: [
        .init(microphone: .blocks(4), system: .unrecoverable),
        .init(microphone: .missing, system: .unrecoverable),
        .init(microphone: .missing, system: .blocks(4)),
      ])
    let runtime = FakeTranscriptionRuntime()
    let (finalizer, _) = makeFinalizer(runtime: runtime)
    let revision = try await revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    let descriptor = try XCTUnwrap(outcome.row.analysisDescriptor)
    XCTAssertEqual(descriptor.stretches.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(descriptor.stretches.map(\.tracks), [.mic, .both, .system])
    XCTAssertEqual(descriptor.stretches[1].lengthMs, 0)
    XCTAssertGreaterThan(descriptor.stretches[0].lengthMs, 0)
    XCTAssertGreaterThan(descriptor.stretches[2].lengthMs, 0)
    XCTAssertEqual(Set(descriptor.contributingTracks), [.mic, .system])
    let counts = await runtime.sampleCounts
    XCTAssertEqual(counts.count, 2)
    let rows = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertEqual(
      rows.map(\.draft.analysisTracks), rows.map { $0.draft.stretchSequence == 1 ? .mic : .system })
  }

  func testDecodeFailureAndConverterFailureMapToTheirCategories() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let url = try XCTUnwrap(meeting.files[1]?[.microphone])
    try Data(repeating: 0x55, count: 4_000).write(to: url)
    let (finalizer, lifecycle) = makeFinalizer()
    let revision = try await revision(meeting.meetingID)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
      XCTFail("decode failure not raised")
    } catch {
      XCTAssertEqual(
        error as? MeetingFinalizer.Error, .failed(.audioDecodeFailure, detail: "open"))
    }
    let rowValue = try await store.transcription(meetingID: meeting.meetingID)
    let row = try XCTUnwrap(rowValue)
    XCTAssertEqual(row.state, .failed)
    XCTAssertEqual(row.failureCategory, .audioDecodeFailure)
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    XCTAssertEqual(
      MeetingFinalizer.category(for: AnalysisStreamMixer.Failure.analysisStreamFailure).0,
      .analysisStreamFailure)
    XCTAssertEqual(
      MeetingFinalizer.category(for: TranscriptStore.Error.capacityExceeded(.meetingBytes)).0,
      .persistenceCapacity)
    XCTAssertEqual(
      MeetingFinalizer.category(for: TranscriptStore.Error.damagedDatabase).0,
      .persistenceFailure)
    XCTAssertEqual(
      MeetingFinalizer.category(for: DictationFailure.invalidResult).0, .runtimeFailure)
  }

  func testWorkListPagesByOneHundredAndRefusesTheTenThousandAndFirstStretch() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let realValue = try await fixture.store.detail(id: meeting.meetingID)
    let real = try XCTUnwrap(realValue)
    let mic = try XCTUnwrap(real.track(.microphone))
    var segments = mic.segments
    for sequence in 2...(MeetingFinalizer.workListCapacity + 1) {
      var segment = MeetingSegment(
        id: UUID(), trackID: mic.track.id, sequence: sequence,
        relativePath: SegmentHandle.relativePath(
          meetingID: meeting.meetingID, kind: .microphone, sequence: sequence, open: false),
        startOffsetMs: 0, startedAt: 0, hostStartNs: 0, openReason: .resume)
      segment.state = .finalized
      segment.durationMs = 100
      segments.append(segment)
    }
    let detail = MeetingDetail(
      meeting: real.meeting,
      tracks: [MeetingTrackDetail(track: mic.track, segments: segments)], pauses: [],
      notes: real.notes, outcomes: [])
    let stub = StubMeetingStore(detail: detail)
    let (finalizer, lifecycle) = makeFinalizer(meetings: stub)
    let revision = try await revision(meeting.meetingID)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
      XCTFail("capacity not enforced")
    } catch {
      XCTAssertEqual(
        error as? MeetingFinalizer.Error,
        .failed(.finalizationInterrupted, detail: "work_list_capacity"))
    }
    let rowValue = try await store.transcription(meetingID: meeting.meetingID)
    let row = try XCTUnwrap(rowValue)
    XCTAssertEqual(row.state, .failed)
    XCTAssertEqual(row.failureDetail, "work_list_capacity")
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    XCTAssertEqual(MeetingFinalizer.workListPage, 100)
    let items = MeetingFinalizer.workItems(detail: detail, page: 1)
    XCTAssertEqual(items.count, 100)
    XCTAssertEqual(items.first?.sequence, 101)
    XCTAssertEqual(MeetingFinalizer.stretchCount(detail: detail), 10_001)
  }

  func testCompletionReplacesProvisionalRowsAndReportsCoveredGaps() async throws {
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init()])
    // Seed a live pass: three provisional rows and two gaps, one inside the
    // recorded range and one past it.
    let livePass = UUID()
    try await store.transition(
      meetingID: meeting.meetingID, to: .live, now: 10,
      effects: [.setPass(id: livePass, kind: .live)])
    let drafts = (0..<3).map { ordinal in
      TranscriptSegmentDraft(
        ordinal: ordinal, stretchSequence: 1, startMs: Int64(ordinal) * 50,
        endMs: Int64(ordinal) * 50 + 40, coveredMs: 341, windowIndex: 0, timingBasis: .window,
        rawText: "live", assembledText: "live", normalizedText: "Live", analysisTracks: .both)
    }
    _ = try await store.appendSegments(
      meetingID: meeting.meetingID, passID: livePass, drafts: drafts, progress: nil, now: 11)
    try await store.appendGap(
      .init(
        meetingID: meeting.meetingID, passID: livePass, stretchSequence: 1, startMs: 100,
        endMs: 200, reason: .backpressure, createdAt: 12))
    try await store.appendGap(
      .init(
        meetingID: meeting.meetingID, passID: livePass, stretchSequence: 2, startMs: 90_000,
        endMs: 95_000, reason: .stopDrain, createdAt: 13))
    try await store.transition(meetingID: meeting.meetingID, to: .finalizing, now: 14, effects: [])
    let (finalizer, _) = makeFinalizer(recorder: capture.recorder)
    let revision = try await revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.replacedProvisionalCount, 3)
    XCTAssertEqual(outcome.totalGapCount, 2)
    XCTAssertEqual(outcome.coveredGapCount, 1)
    XCTAssertEqual(outcome.coveredGapMs, 100)
    let provisional = try await store.page(
      meetingID: meeting.meetingID, finality: .provisional, after: nil, limit: 200)
    XCTAssertTrue(provisional.isEmpty)
    let gaps = try await store.gaps(meetingID: meeting.meetingID)
    XCTAssertTrue(gaps.isEmpty)
    let usage = try await store.usage()
    XCTAssertEqual(usage.segmentRows, outcome.row.segmentCount)
    let samples = try await capture.samples()
    XCTAssertTrue(
      samples.contains {
        $0["metric"] as? String == "transcriptLiveGapMs"
          && $0["phase"] as? String == "transcriptFinalizing"
      })
  }

  // MARK: Retry (US6)

  func testRetryFromFailedAndInterruptedRunsTheSamePass() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await store.transition(
      meetingID: meeting.meetingID, to: .failed, now: 5,
      effects: [.setFailure(category: .modelLoadFailure, detail: nil)])
    let (finalizer, lifecycle) = makeFinalizer()
    var revision = try await revision(meeting.meetingID)
    var outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertNil(outcome.row.failureCategory)
    // Interrupted (found by reconciliation after a live pass) retries the same way.
    let other = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], startedAt: 1_800_000_000_000)
    try await store.transition(
      meetingID: other.meetingID, to: .live, now: 5, effects: [.setPass(id: UUID(), kind: .live)])
    try await store.transition(
      meetingID: other.meetingID, to: .interrupted, now: 6,
      effects: [.setFailure(category: .finalizationInterrupted, detail: nil)])
    revision = try await self.revision(other.meetingID)
    outcome = try await finalizer.run(meetingID: other.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    // A stale revision writes nothing.
    do {
      _ = try await finalizer.run(meetingID: other.meetingID, revision: revision)
      XCTFail("stale retry admitted")
    } catch { XCTAssertEqual(error as? MeetingFinalizer.Error, .staleRevision) }
    let after = try await store.transcription(meetingID: other.meetingID)
    XCTAssertEqual(after, outcome.row)
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
  }

  func testRuntimeFailureMidPassKeepsEarlierRowsAndStaysRetryable() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init(), .init()])
    for attempt in 1...3 {
      let runtime = FakeTranscriptionRuntime(failureOnCall: 2)
      let (finalizer, lifecycle) = makeFinalizer(runtime: runtime)
      let revision = try await revision(meeting.meetingID)
      do {
        _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
        XCTFail("attempt \(attempt) did not fail")
      } catch {
        XCTAssertEqual(error as? MeetingFinalizer.Error, .failed(.runtimeFailure, detail: nil))
      }
      let resident = await finalizer.residentWindowSamples
      XCTAssertEqual(resident, 0, "a failed pass releases its window")
      let rowValue = try await store.transcription(meetingID: meeting.meetingID)
      let row = try XCTUnwrap(rowValue)
      XCTAssertEqual(row.state, .failed)
      XCTAssertEqual(row.failureCategory, .runtimeFailure)
      let rows = try await store.page(
        meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
      XCTAssertFalse(rows.isEmpty, "rows before the failure are kept")
      XCTAssertTrue(rows.allSatisfy { $0.draft.stretchSequence == 1 })
      let released = await lifecycle.snapshot()
      XCTAssertFalse(released.leased)
    }
    let (finalizer, _) = makeFinalizer(runtime: FakeTranscriptionRuntime())
    let revision = try await revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.analysisDescriptor?.stretches.count, 3)
  }

  func testAcquisitionFailuresMapToModelCategoriesWithoutTouchingTheMeeting() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let logging = LoggingMeetingStore(fixture.store)
    let cases: [(Error, TranscriptFailureCategory)] = [
      (DictationFailure.modelUnavailable, .modelUnavailable),
      (ModelProvisioner.Error.hashMismatch("model.bin"), .modelProvisioning),
      (DictationFailure.invalidAudio, .modelLoadFailure),
    ]
    for (thrown, expected) in cases {
      let lifecycle = ModelLifecycleCoordinator { throw thrown }
      let (finalizer, _) = makeFinalizer(lifecycle: lifecycle, meetings: logging)
      let revision = try await revision(meeting.meetingID)
      do {
        _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
        XCTFail("acquire succeeded")
      } catch {
        XCTAssertEqual(error as? MeetingFinalizer.Error, .failed(expected, detail: nil))
      }
      let rowValue = try await store.transcription(meetingID: meeting.meetingID)
      let row = try XCTUnwrap(rowValue)
      XCTAssertEqual(row.state, .failed)
      XCTAssertEqual(row.failureCategory, expected)
      let released = await lifecycle.snapshot()
      XCTAssertFalse(released.leased)
    }
    XCTAssertEqual(
      Set(logging.calls), ["detail"], "only the detail is read; meetings.* never written")
    let detailValue = try await fixture.store.detail(id: meeting.meetingID)
    let detail = try XCTUnwrap(detailValue)
    XCTAssertEqual(detail.meeting.state, .completed)
  }

  func testVocabularySnapshotFailureIsRuntimeFailureWithDetail() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let (finalizer, lifecycle) = makeFinalizer(vocabulary: FailingVocabulary())
    let revision = try await revision(meeting.meetingID)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
      XCTFail()
    } catch {
      XCTAssertEqual(
        error as? MeetingFinalizer.Error,
        .failed(.runtimeFailure, detail: "vocabulary_unavailable"))
    }
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    XCTAssertFalse(released.loaded, "no lease is taken before the snapshot exists")
  }

  func testPersistenceFailuresRetryFourTimesThenFail() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let fake = FakeTranscriptStore()
    await fake.seed(meeting.meetingID)
    await fake.failBatches(4)
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let finalizer = MeetingFinalizer(
      store: fake, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      vocabulary: EmptyVocabularyProvider(), clock: FakeMeetingClock())
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: 0)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? MeetingFinalizer.Error, .failed(.persistenceFailure, detail: nil))
    }
    let attempts = await fake.calls.filter { $0 == "appendSegments" }.count
    XCTAssertEqual(attempts, 4)
    let row = await fake.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(row?.state, .failed)
    // Three transient failures succeed on the fourth attempt.
    await fake.failBatches(3)
    let revision = try XCTUnwrap(row?.revision)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
  }

  // MARK: Phase 12: Transcribe a meeting recorded without transcription (US9)

  func testTranscribeOnNotRequestedRunsTheSamePassWithLiveRequestedZero() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], liveRequested: false)
    let logging = LoggingTranscriptStore(store)
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let finalizer = MeetingFinalizer(
      store: logging, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      clock: FakeMeetingClock())
    let beforeValue = try await store.transcription(meetingID: meeting.meetingID)
    let before = try XCTUnwrap(beforeValue)
    XCTAssertEqual(before.state, .notRequested)
    XCTAssertFalse(before.liveRequested)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: before.revision)
    XCTAssertEqual(logging.transitions, ["pending", "finalizing", "final"])
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertFalse(outcome.row.liveRequested, "Transcribe never claims a live pass")
    XCTAssertEqual(outcome.row.passKind, .final)
    XCTAssertEqual(outcome.row.replacedProvisionalCount, 0)
    XCTAssertNil(outcome.row.liveStartedAt)
    XCTAssertGreaterThan(outcome.row.coveredMs, 0)
    XCTAssertGreaterThan(outcome.windowCount, 0)
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
  }

  func testPreFeatureMeetingGetsANotRequestedRowOnFirstReadAndCanBeTranscribed() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], insertTranscription: false)
    let missing = try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM meeting_transcriptions WHERE meeting_id=?",
        arguments: [meeting.meetingID.uuidString])
    }
    XCTAssertEqual(missing, 0, "a Feature 004 meeting has no transcription row")
    let rowValue = try await store.transcription(meetingID: meeting.meetingID)
    let row = try XCTUnwrap(rowValue)
    XCTAssertEqual(row.state, .notRequested)
    XCTAssertFalse(row.liveRequested)
    XCTAssertEqual(row.revision, 0)
    // The backfill is idempotent and an unknown meeting still reads nil.
    let again = try await store.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(again, row)
    let unknown = try await store.transcription(meetingID: UUID())
    XCTAssertNil(unknown)
    let (finalizer, _) = makeFinalizer()
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: row.revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertFalse(outcome.row.liveRequested)
  }

  func testMigrationBackfillsNotRequestedRowsForExistingMeetings() throws {
    let directory = try makeMeetingTestRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let database = try DatabaseQueue(path: path)
    try HistoryMigrations.migrator().migrate(database, upTo: "meetings-v5")
    let id = UUID()
    try database.write { db in
      try db.execute(
        sql: "INSERT INTO meetings(id,state,created_at,updated_at) VALUES(?,?,?,?)",
        arguments: [id.uuidString, "completed", 1, 2])
    }
    try HistoryMigrations.migrator().migrate(database)
    let row = try database.read { db in
      try Row.fetchOne(
        db,
        sql:
          "SELECT state,live_requested,updated_at FROM meeting_transcriptions WHERE meeting_id=?",
        arguments: [id.uuidString])
    }
    XCTAssertEqual(row?["state"] as String?, "not_requested")
    XCTAssertEqual(row?["live_requested"] as Int?, 0)
    XCTAssertEqual(row?["updated_at"] as Int64?, 2)
  }

  func testInterruptedMeetingWithOneRecoveredStretchCoversOnlyThatStretch() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture,
      stretches: [
        .init(microphone: .blocks(8), system: .blocks(8)),
        .init(microphone: .unrecoverable, system: .unrecoverable),
      ],
      liveRequested: false, finalState: .interrupted)
    let (finalizer, _) = makeFinalizer()
    let revision = try await revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    let descriptor = try XCTUnwrap(outcome.row.analysisDescriptor)
    let recovered = descriptor.stretches.filter { $0.lengthMs > 0 }
    XCTAssertEqual(recovered.map(\.sequence), [1], "only the recovered stretch contributes")
    XCTAssertEqual(outcome.row.coveredMs, recovered[0].lengthMs)
    XCTAssertEqual(descriptor.stretches.first { $0.sequence == 2 }?.lengthMs, 0)
    let detailValue = try await fixture.store.detail(id: meeting.meetingID)
    XCTAssertEqual(try XCTUnwrap(detailValue).meeting.state, .interrupted, "meeting untouched")
  }

  func testTranscribeWithoutAProvisionedModelFailsWithGuidanceAndNoProvisioning() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init()], liveRequested: false)
    let factoryCalls = CallCounter()
    let lifecycle = ModelLifecycleCoordinator {
      factoryCalls.increment()
      throw DictationFailure.modelUnavailable
    }
    let logging = LoggingMeetingStore(fixture.store)
    let (finalizer, _) = makeFinalizer(lifecycle: lifecycle, meetings: logging)
    let revision = try await revision(meeting.meetingID)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
      XCTFail("admitted without a model")
    } catch {
      XCTAssertEqual(
        error as? MeetingFinalizer.Error, .failed(.modelUnavailable, detail: nil))
    }
    let rowValue = try await store.transcription(meetingID: meeting.meetingID)
    let row = try XCTUnwrap(rowValue)
    XCTAssertEqual(row.state, .failed)
    XCTAssertEqual(row.failureCategory, .modelUnavailable)
    XCTAssertFalse(row.liveRequested)
    XCTAssertEqual(
      TranscriptErrorMessage.message(for: .modelUnavailable),
      "The speech model is not installed. Install it in Settings to transcribe.")
    XCTAssertEqual(factoryCalls.value, 1, "one local load attempt, nothing else")
    XCTAssertEqual(Set(logging.calls), ["detail"])
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
    // The finalizer never provisions or downloads: no provisioner or network symbol.
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { root.deleteLastPathComponent() }
    for file in [
      "LocalFlow/Core/Transcripts/MeetingFinalizer.swift",
      "LocalFlow/Core/Transcripts/TranscriptReconciler.swift",
      "LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift",
    ] {
      let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
      for symbol in ["ModelProvisioner", "URLSession", "URLRequest"] {
        XCTAssertFalse(text.contains(symbol), "\(file) references \(symbol)")
      }
    }
  }

  // MARK: Phase 14: track integrity (T085)

  func testTrackFilesAreByteIdenticalAcrossFinalFailedAndRetriedPasses() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(), .init(microphone: .blocks(6), system: .missing)])
    let before = try meeting.fileDigests()
    let listingBefore = fileListing(under: fixture.directory)
    XCTAssertEqual(before.count, 3)
    // A pass that fails on the second window, then a Retry that completes.
    let runtime = FakeTranscriptionRuntime(failureOnCall: 2)
    let (finalizer, lifecycle) = makeFinalizer(runtime: runtime)
    var revision = try await revision(meeting.meetingID)
    do {
      _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
      XCTFail("expected a runtime failure")
    } catch {
      XCTAssertEqual(error as? MeetingFinalizer.Error, .failed(.runtimeFailure, detail: nil))
    }
    XCTAssertEqual(try meeting.fileDigests(), before, "a failed pass leaves every track alone")
    XCTAssertEqual(fileListing(under: fixture.directory), listingBefore)
    revision = try await self.revision(meeting.meetingID)
    let outcome = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(try meeting.fileDigests(), before, "a final pass leaves every track alone")
    XCTAssertEqual(fileListing(under: fixture.directory), listingBefore)
    // Re-transcribe of a final transcript: same guarantee.
    revision = try await self.revision(meeting.meetingID)
    _ = try await finalizer.run(meetingID: meeting.meetingID, revision: revision)
    XCTAssertEqual(try meeting.fileDigests(), before)
    XCTAssertEqual(fileListing(under: fixture.directory), listingBefore)
    let released = await lifecycle.snapshot()
    XCTAssertFalse(released.leased)
  }

  func testTurboUsesMeetingFactoryAndLongerGeometry() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(180), system: .missing)])
    let runtime = FakeTranscriptionRuntime(windows: [.init(text: "Turbo výsledok.", tokens: [])])
    let speech = ProbeRuntime()
    let lifecycle = ModelLifecycleCoordinator(meetingFactory: { _ in runtime }, factory: { speech })
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      configuration: .turbo)
    let outcome = try await finalizer.run(
      meetingID: meeting.meetingID, revision: try await revision(meeting.meetingID))
    let counts = await runtime.sampleCounts
    let speechCalls = await speech.calls
    XCTAssertEqual(counts.count, 1)
    XCTAssertGreaterThan(counts[0], 239_360)
    XCTAssertEqual(speechCalls, 0)
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.plannerVersion, MeetingFinalizer.Configuration.turbo.geometry)
    XCTAssertGreaterThan(outcome.row.segmentCount, 0)
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
  }

  /// The language chosen in Settings is part of the pass identity, so a pass that
  /// stopped under one language is not resumed under another.
  func testTurboRecordsTheChosenLanguageInThePipelineVersion() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(4), system: .blocks(4))])
    let runtime = FakeTranscriptionRuntime(windows: [
      .init(text: "Ahoj.", tokens: []), .init(text: "Čau.", tokens: []),
    ])
    let lifecycle = ModelLifecycleCoordinator(
      meetingFactory: { _ in runtime }, factory: { ProbeRuntime() })
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      configuration: .turbo, defaultLanguage: { .slovak })
    let outcome = try await finalizer.run(
      meetingID: meeting.meetingID, revision: try await revision(meeting.meetingID))
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(
      outcome.row.pipelineVersion?.contains("+echo_lag1s_p20_k12_min300_v1+lang_sk_prompt_v1+"),
      true)
    let rows = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 10)
    XCTAssertFalse(rows.isEmpty)
    XCTAssertTrue(rows.allSatisfy { $0.draft.pipelineVersion.contains("+lang_sk_prompt_v1+") })
  }

  /// A language chosen on the meeting wins over the Settings default.
  func testTurboPrefersTheMeetingsOwnLanguageOverTheDefault() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(4), system: .blocks(4))])
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let currentRow = try await fixture.store.meeting(id: meeting.meetingID)
    let current = try XCTUnwrap(currentRow)
    _ = try await fixture.store.setLanguage(
      meetingID: meeting.meetingID, language: .english, revision: current.revision, now: now)
    let storedRow = try await fixture.store.meeting(id: meeting.meetingID)
    let stored = try XCTUnwrap(storedRow)
    XCTAssertEqual(stored.language, .english)
    let runtime = FakeTranscriptionRuntime(windows: [
      .init(text: "Hello.", tokens: []), .init(text: "Hi.", tokens: []),
    ])
    // The runtime decodes in the language the pass recorded, not a second read.
    let requested = FactoryLanguages()
    let lifecycle = ModelLifecycleCoordinator(
      meetingFactory: { language in
        requested.append(language)
        return runtime
      }, factory: { ProbeRuntime() })
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      configuration: .turbo, defaultLanguage: { .slovak })
    let outcome = try await finalizer.run(
      meetingID: meeting.meetingID, revision: try await revision(meeting.meetingID))
    XCTAssertEqual(outcome.row.pipelineVersion?.contains("+lang_en_prompt_v1+"), true)
    XCTAssertEqual(requested.values, [.english])
    // Clearing the choice returns the meeting to the default.
    _ = try await fixture.store.setLanguage(
      meetingID: meeting.meetingID, language: nil, revision: stored.revision, now: now)
    let clearedRow = try await fixture.store.meeting(id: meeting.meetingID)
    let cleared = try XCTUnwrap(clearedRow)
    XCTAssertNil(cleared.language)
  }

  func testTurboRecognizesEachTrackAloneLevelledAndMergesRowsByTime() async throws {
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(180), system: .blocks(180))])
    // The microphone lane is read first, so call 1 is the microphone window.
    let runtime = FakeTranscriptionRuntime(windows: [
      .init(
        text: "Ahoj. Dobre.",
        tokens: [.init(text: "Ahoj.", start: 0, end: 1), .init(text: "Dobre.", start: 4, end: 5)]),
      .init(
        text: "Čau. Fajn.",
        tokens: [.init(text: "Čau.", start: 2, end: 3), .init(text: "Fajn.", start: 6, end: 7)]),
    ])
    let lifecycle = ModelLifecycleCoordinator(
      meetingFactory: { _ in runtime }, factory: { ProbeRuntime() })
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      configuration: .turbo)
    let outcome = try await finalizer.run(
      meetingID: meeting.meetingID, revision: try await revision(meeting.meetingID))
    let counts = await runtime.sampleCounts
    XCTAssertEqual(counts.count, 2, "one request per track, nothing mixed")
    let resident = await finalizer.residentWindowSamples
    XCTAssertEqual(resident, 0, "both lane windows are released")
    XCTAssertEqual(counts[0], counts[1])
    // The 0.4 tone (−11 dBFS) arrives at the −20 dBFS speech level.
    let received = await runtime.received
    for samples in received {
      let rms = 10 * log10f(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
      XCTAssertEqual(rms, -20, accuracy: 1)
    }
    XCTAssertEqual(outcome.row.state, .final)
    XCTAssertEqual(outcome.row.plannerVersion, "per_track_fixed1920000_turbo_level_v2")
    XCTAssertEqual(
      outcome.row.pipelineVersion?.hasPrefix(
        "per_track_fixed1920000_turbo_level_v2+level_p90_m20_v1+echo_lag1s_p20_k12_min300_v1+lang_auto_prompt_v1+"
      ),
      true)
    XCTAssertEqual(outcome.row.analysisDescriptor?.version, "per_track_16k_v1")
    XCTAssertEqual(outcome.row.analysisDescriptor?.mixRule, "none")
    XCTAssertEqual(outcome.row.analysisDescriptor?.contributingTracks, [.mic, .system])
    XCTAssertEqual(outcome.row.analysisDescriptor?.stretches.map(\.tracks), [.both])
    let rows = try await store.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 10)
    XCTAssertEqual(rows.map(\.ordinal), [0, 1, 2, 3])
    XCTAssertEqual(rows.map(\.normalizedText), ["Ahoj.", "Čau.", "Dobre.", "Fajn."])
    XCTAssertEqual(rows.map(\.draft.analysisTracks), [.mic, .system, .mic, .system])
    XCTAssertEqual(rows.map(\.startMs), [0, 2_000, 4_000, 6_000])
    XCTAssertEqual(rows.map(\.draft.windowIndex), [0, 0, 0, 0])
  }

  func testMissingTurboPreservesPreviouslyFinalTranscript() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let runtime = FakeTranscriptionRuntime(windows: [
      .init(text: "Keep this transcript.", tokens: [])
    ])
    let (original, _) = makeFinalizer(runtime: runtime)
    let complete = try await original.run(
      meetingID: meeting.meetingID, revision: try await revision(meeting.meetingID))
    let lifecycle = ModelLifecycleCoordinator { ProbeRuntime() }
    let turbo = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root, lifecycle: lifecycle,
      configuration: .turbo)
    do {
      _ = try await turbo.run(meetingID: meeting.meetingID, revision: complete.row.revision)
      XCTFail("Unavailable Turbo must fail")
    } catch {
      XCTAssertEqual(error as? MeetingFinalizer.Error, .failed(.modelUnavailable, detail: nil))
    }
    let retained = try await store.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(retained, complete.row)
    let count = try await store.passSegmentCount(
      meetingID: meeting.meetingID, passID: try XCTUnwrap(complete.row.passID))
    XCTAssertEqual(count, complete.row.segmentCount)
  }

  // MARK: Helpers

  private func wait(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<1_000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Condition did not settle")
  }
}

struct RevisionVocabulary: VocabularyProviding {
  let revision: Int64
  func snapshot() async throws -> VocabularySnapshot {
    try VocabularySnapshot(revision: revision, hash: String(repeating: "a", count: 64), entries: [])
  }
}

struct FailingVocabulary: VocabularyProviding {
  func snapshot() async throws -> VocabularySnapshot { throw DictationFailure.invalidResult }
}

/// The languages a meeting runtime factory was asked for, in order.
private final class FactoryLanguages: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [MeetingLanguage] = []
  var values: [MeetingLanguage] { lock.withLock { stored } }
  func append(_ language: MeetingLanguage) { lock.withLock { stored.append(language) } }
}
