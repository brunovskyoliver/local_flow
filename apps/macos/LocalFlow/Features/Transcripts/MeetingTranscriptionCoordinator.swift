import Foundation
import OSLog
import Observation

/// The live session and the finalization queue. At most one live session and one
/// finalization exist at a time; the live session has priority, so a running pass
/// yields at its next window boundary when a meeting starts with transcription and
/// returns to the head of the queue.
@MainActor @Observable
final class MeetingTranscriptionCoordinator: MeetingTranscriptionObserving {
  static let finalizationQueueCapacity = 100
  /// RSS sampling cadence while a final pass runs (the meeting sampler has stopped by then).
  static let rssInterval: Duration = .seconds(10)
  private(set) var status: TranscriptStatus?
  let liveModel = LiveTranscriptModel()
  var isWindowInFlight: Bool { recognizer?.isWindowInFlight ?? false }
  var isFinalizing: Bool { finalizingMeetingID != nil }
  private(set) var finalizingMeetingID: UUID?
  private(set) var lastFinalization: MeetingFinalizer.Outcome?
  var queuedFinalizationCount: Int { finalizationQueue.count }
  var installedTapCount: Int { taps.count }
  /// One-line notices for the indicator panel ("Too many transcripts waiting", …).
  var noticePublished: (@MainActor (String) -> Void)?
  /// Feature 007: told once a final transcript is published and its lease finished.
  @ObservationIgnored weak var diarization: (any DiarizationObserving)?
  @ObservationIgnored weak var intelligence: (any IntelligenceObserving)?
  var analysisQueueHighWater: Int { recognizer?.queue.highWater ?? 0 }
  var pendingSegmentCount: Int { recognizer?.pendingCount ?? 0 }
  var analysisGapRangeCount: Int { recognizer?.gapRangeCount ?? 0 }

  private let store: any TranscriptStoring
  private let lifecycle: ModelLifecycleCoordinator
  private let vocabulary: any VocabularyProviding
  private let identity: TranscriptionPipelineIdentity
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let finalizer: MeetingFinalizer?
  private let logSink: @Sendable (String) -> Void
  private struct FinalizationRequest: Equatable {
    let meetingID: UUID
    /// Nil for automatic requests: the runner reads the current revision.
    let revision: Int64?
  }
  private var finalizationQueue: [FinalizationRequest] = []
  private var finalizationTask: Task<Void, Never>?
  private var rssTask: Task<Void, Never>?
  /// Stopped meetings whose drain finished before `meetingDidComplete` arrived.
  private var awaitingCompletion: Set<UUID> = []
  /// Completed meetings whose drain is still running.
  private var completedMeetings: Set<UUID> = []
  private var deletedMeetings: Set<UUID> = []
  /// Monotonic stamp of each in-session `meetingDidStop`, consumed when its final
  /// pass starts — the drain, live-pass and queue wait the user feels (FR-037).
  private var stopBeganAt: [UUID: UInt64] = [:]
  private var meetingID: UUID?
  private var requested = false
  private var passID = UUID()
  private var lease: ModelLease?
  private var snapshot = VocabularySnapshot.empty
  private var taps: [MeetingTrackKind: MeetingAnalysisTap] = [:]
  /// Resampling and mixing run on this actor, not the main actor.
  @ObservationIgnored private var mixer: AnalysisMixerHost?
  private var recognizer: LiveRecognizer?
  private var startTask: Task<Void, Never>?
  @ObservationIgnored private var pumpTask: Task<Void, Never>?
  @ObservationIgnored private var timer: Task<Void, Never>?
  private var boundaryTask: Task<Void, Never>?
  private var retentionTask: Task<Void, Never>?
  private var baseMs: Int64 = 0
  private var ordinal = 0
  @ObservationIgnored private var lastFlush: UInt64 = 0
  @ObservationIgnored private var flushing = false
  @ObservationIgnored private var ticking = false
  @ObservationIgnored private var degraded = false
  private var persistenceFailures = 0
  private var stopped = false
  private var paused = false
  private var latestSequence = 1
  private var loadTask: Task<(VocabularySnapshot, ModelLease), Error>?
  private var descriptor = AnalysisStreamDescriptor(source: .livePCMTee)
  private struct PendingStart {
    let id: UUID
    let options: MeetingStartOptions
    var sequence = 1
    var tracks: [MeetingTrackKind: MeetingSourceFormat] = [:]
    var taps: [MeetingTrackKind: MeetingAnalysisTap] = [:]
    var paused = false
  }
  private var pendingStart: PendingStart?
  private var admissionTask: Task<Void, Never>?
  private var displayedMeetingID: UUID?

  init(
    store: any TranscriptStoring, lifecycle: ModelLifecycleCoordinator,
    vocabulary: any VocabularyProviding = EmptyVocabularyProvider(),
    identity: TranscriptionPipelineIdentity = .init(),
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil,
    finalizer: MeetingFinalizer? = nil,
    logSink: @escaping @Sendable (String) -> Void = { message in
      Logger(subsystem: "org.localflow.LocalFlow", category: "transcript")
        .notice("\(message, privacy: .public)")
    }
  ) {
    self.store = store
    self.lifecycle = lifecycle
    self.vocabulary = vocabulary
    self.identity = identity
    self.clock = clock
    self.recorder = recorder
    self.finalizer = finalizer
    self.logSink = logSink
  }

  func meetingWillStart(id: UUID, options: MeetingStartOptions) async -> TranscriptState {
    // Admission never waits for a previous inference or model load.
    displayedMeetingID = id
    liveModel.reset()
    status = nil
    if let previousID = meetingID, previousID != id {
      detach(pendingStart?.taps ?? [:])
      pendingStart = PendingStart(id: id, options: options)
      if !stopped { meetingDidStop(id: previousID) }
      if admissionTask == nil {
        let previousBoundary = boundaryTask
        let previousLoad = startTask
        let previousPump = pumpTask
        admissionTask = Task { [weak self] in
          await previousBoundary?.value
          await previousLoad?.value
          await previousPump?.value
          guard let self else { return }
          defer { self.admissionTask = nil }
          guard let pending = self.pendingStart else { return }
          self.pendingStart = nil
          self.beginMeeting(id: pending.id, options: pending.options)
          if !pending.tracks.isEmpty {
            _ = self.startStretch(
              meetingID: pending.id, sequence: pending.sequence,
              tracks: pending.tracks, suppliedTaps: pending.taps)
            if pending.paused { self.meetingDidPause(id: pending.id) }
          }
        }
      }
      return options.transcription ? .pending : .notRequested
    }
    beginMeeting(id: id, options: options)
    if !options.transcription, let row = try? await store.transcription(meetingID: id) {
      publish(row)
    }
    return options.transcription ? .pending : .notRequested
  }

  private func detach(_ taps: [MeetingTrackKind: MeetingAnalysisTap]) {
    for tap in taps.values { tap.detach() }
  }

  private func beginMeeting(id: UUID, options: MeetingStartOptions) {
    meetingID = id
    requested = options.transcription
    if requested { finalizationTask?.cancel() }
    stopped = false
    paused = false
    passID = UUID()
    baseMs = 0
    ordinal = 0
    persistenceFailures = 0
    degraded = false
    descriptor = .init(source: .livePCMTee)
    liveModel.reset()
    status = nil
    if !requested {
      Task { [weak self] in
        guard let self, let row = try? await self.store.transcription(meetingID: id) else { return }
        self.publish(row)
      }
    }
  }

  func stretchDidStart(
    meetingID id: UUID, sequence: Int,
    tracks: [MeetingTrackKind: MeetingSourceFormat]
  ) -> [MeetingTrackKind: MeetingAnalysisTap]? {
    if pendingStart?.id == id {
      guard pendingStart?.options.transcription == true else { return nil }
      let fresh = try? tracks.mapValuesWithKey { kind, format in
        try MeetingAnalysisTap(kind: kind, format: format)
      }
      detach(pendingStart?.taps ?? [:])
      pendingStart?.sequence = sequence
      pendingStart?.tracks = tracks
      pendingStart?.taps = fresh ?? [:]
      pendingStart?.paused = false
      return fresh
    }
    return startStretch(meetingID: id, sequence: sequence, tracks: tracks)
  }

  private func startStretch(
    meetingID id: UUID, sequence: Int,
    tracks: [MeetingTrackKind: MeetingSourceFormat],
    suppliedTaps: [MeetingTrackKind: MeetingAnalysisTap]? = nil
  ) -> [MeetingTrackKind: MeetingAnalysisTap]? {
    guard meetingID == id else { return nil }
    guard requested else {
      Task { [weak self] in
        guard let self, let row = try? await self.store.transcription(meetingID: id) else { return }
        self.publish(row)
      }
      return nil
    }
    guard !stopped, status?.state != .failed else { return nil }
    guard !tracks.isEmpty else {
      Task { [weak self] in await self?.fail(.analysisStreamFailure) }
      return nil
    }
    do {
      retentionTask?.cancel()
      let retention = retentionTask
      retentionTask = nil
      let fresh =
        try suppliedTaps
        ?? tracks.mapValuesWithKey { kind, format in
          try MeetingAnalysisTap(kind: kind, format: format)
        }
      let nextMixer = try AnalysisMixerHost(
        microphone: fresh[.microphone], system: fresh[.system])
      detach(taps)
      timer?.cancel()
      timer = nil
      taps = fresh
      latestSequence = sequence
      paused = false
      descriptor.contributingTracks = tracks.keys.map { $0 == .microphone ? .mic : .system }
      if lease == nil, startTask == nil {
        mixer = nextMixer
        let preceding = boundaryTask
        let reload = status?.state == .live
        let retainedSnapshot = snapshot
        let lifecycle = lifecycle
        let vocabulary = vocabulary
        let yielding = finalizationTask
        let loading = Task.detached {
          await preceding?.value
          await retention?.value
          await yielding?.value
          let snapshot: VocabularySnapshot
          do {
            snapshot = try await (reload ? retainedSnapshot : vocabulary.snapshot())
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw LoadError.vocabulary
          }
          try Task.checkCancellation()
          let lease = try await lifecycle.acquire(session: id)
          return (snapshot, lease)
        }
        loadTask = loading
        startTask = Task { [weak self] in
          defer {
            self?.startTask = nil
            self?.loadTask = nil
          }
          do {
            let acquired = try await loading.value
            guard let self, self.meetingID == id, !self.stopped else {
              try? await lifecycle.finish(acquired.1)
              return
            }
            self.snapshot = acquired.0
            self.lease = acquired.1
            if reload { self.mixer = nextMixer }
            if reload {
              let row = try await self.store.updateLiveMetadata(
                meetingID: id,
                descriptor: self.descriptor, incrementModelReloads: true,
                now: self.clock.nowMilliseconds)
              self.publish(row)
              self.recorder?.record(
                phase: .transcriptLive, metric: .transcriptModelReload, itemCount: 1)
              try await self.persistLiveState(self.paused ? .stopped : .live)
            } else {
              try await self.publishLive(id: id)
            }
            self.installRecognizer(sequence: sequence)
            if !self.paused, self.latestSequence == sequence {
              if reload, let recognizer = self.recognizer {
                // Buffered PCM predates the completed reload. Preserve its duration
                // as one gap; recording has continued throughout model acquisition.
                let range = 0..<(try await nextMixer.discardBuffered())
                recognizer.insertGap(range)
                try await self.recordGap(range, reason: .modelReload, recognizer: recognizer)
              }
              self.startTimer()
            }
          } catch {
            guard let self, self.meetingID == id else { return }
            self.startTask = nil
            self.loadTask = nil
            guard !self.stopped else { return }
            if error is LoadError {
              await self.fail(.runtimeFailure, detail: "vocabulary_unavailable")
            } else {
              await self.fail(.acquisition(error))
            }
          }
        }
      } else {
        let preceding = boundaryTask
        boundaryTask = Task { [weak self] in
          await preceding?.value
          guard let self, self.meetingID == id else { return }
          await self.startTask?.value
          await self.finishStretch()
          guard !self.stopped, self.status?.state == .live else { return }
          self.mixer = nextMixer
          self.installRecognizer(sequence: sequence)
          do { try await self.persistLiveState(.live) } catch {
            await self.fail(.persistenceFailure)
            return
          }
          self.startTimer()
        }
      }
      return fresh
    } catch {
      Task { [weak self] in await self?.fail(.analysisStreamFailure) }
      return nil
    }
  }

  private enum LoadError: Error { case vocabulary }

  private func publishLive(id: UUID) async throws {
    let provenance = identity.provenance(sampleCount: 0, recognition: 0, assembly: 0)
    let model = modelIdentity
    var row = try await store.transition(
      meetingID: id, to: .live, now: clock.nowMilliseconds,
      effects: [
        .setPass(id: passID, kind: .live),
        .setIdentity(
          engine: provenance.engine, model: model, pipeline: pipelineVersion,
          planner: LiveChunkPlanner.version, vocabulary: snapshot),
        .setDescriptor(descriptor),
        .setTimestamps(startedAt: clock.nowMilliseconds, liveStartedAt: clock.nowMilliseconds),
      ])
    try await store.setLiveState(
      meetingID: id, liveState: paused ? .stopped : .live, now: clock.nowMilliseconds)
    row = try await store.transcription(meetingID: id) ?? row
    publish(row)
    lastFlush = clock.monotonicNanoseconds
  }

  private var modelIdentity: TranscriptModelIdentity {
    let provenance = identity.provenance(sampleCount: 0, recognition: 0, assembly: 0)
    return .init(
      id: provenance.modelID ?? "unrecorded", revision: provenance.modelRevision ?? "unrecorded",
      manifestHash: provenance.modelManifestHash ?? String(repeating: "0", count: 64))
  }
  private var pipelineVersion: String {
    [
      LiveChunkPlanner.version, TranscriptAssembler.version, TranscriptSegmenter.version,
      TranscriptNormalizer.version,
    ].joined(separator: "+")
  }
  private func installRecognizer(sequence: Int) {
    guard let lease else { return }
    degraded = false
    recognizer = LiveRecognizer(
      lifecycle: lifecycle, lease: lease, sequence: sequence,
      baseMs: baseMs, ordinal: ordinal, vocabulary: snapshot,
      engine: identity.provenance(sampleCount: 0, recognition: 0, assembly: 0).engine,
      model: modelIdentity, pipelineVersion: pipelineVersion, clock: clock, recorder: recorder)
  }
  private func startTimer() {
    timer?.cancel()
    let clock = clock
    timer = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: .milliseconds(100)) } catch { return }
        guard !Task.isCancelled, let self else { return }
        await self.tick()
      }
    }
  }

  /// Exposed internally for deterministic PCM/clock tests; real capture uses the timer.
  func tick() async {
    guard !ticking, !stopped, !paused, status?.state == .live,
      let recognizer, let mixer
    else { return }
    ticking = true
    defer { ticking = false }
    do {
      try await ingest(try await mixer.tick(), recognizer: recognizer)
      try await updateLag(recognizer, discard: false)
      if pumpTask == nil {
        pumpTask = Task { [weak self, weak recognizer] in
          guard let self, let recognizer else { return }
          defer { self.pumpTask = nil }
          do {
            while self.recognizer === recognizer, !self.stopped, !self.paused {
              try await self.updateLag(recognizer, discard: true)
              guard !self.stopped, !self.paused,
                try await recognizer.processNext()
              else { break }
              try await self.flush(force: false)
            }
          } catch is CancellationError {} catch {
            await self.fail(Self.category(error))
          }
        }
      }
      try await flush(force: false)
    } catch { await fail(Self.category(error)) }
  }

  private func ingest(_ output: AnalysisMixerHost.Output, recognizer: LiveRecognizer) async throws {
    for emission in output.emissions {
      if emission.sampleStart > recognizer.streamEnd {
        let gap = recognizer.streamEnd..<emission.sampleStart
        recognizer.insertGap(gap)
        try await recordGap(gap, reason: .tapOverflow, recognizer: recognizer)
      }
      let start = recognizer.streamEnd
      let accepted = recognizer.accept(
        emission.samples, tracks: emission.tracks, emittedAt: clock.monotonicNanoseconds)
      if accepted < emission.samples.count {
        try await recordGap(
          (start + accepted)..<recognizer.streamEnd,
          reason: .suspended, recognizer: recognizer)
      }
    }
    for gap in output.gaps where gap.upperBound > recognizer.streamEnd {
      let missing = recognizer.streamEnd..<gap.upperBound
      recognizer.insertGap(missing)
      try await recordGap(missing, reason: .tapOverflow, recognizer: recognizer)
    }
  }

  private func recordGap(
    _ range: Range<Int>, reason: LiveGapReason, recognizer: LiveRecognizer
  ) async throws {
    guard let id = meetingID, !range.isEmpty else { return }
    let start = recognizer.stretchBaseMs + Int64(range.lowerBound) * 1_000 / 16_000
    let end = recognizer.stretchBaseMs + Int64(range.upperBound) * 1_000 / 16_000
    guard end > start else { return }
    do {
      try await store.appendGap(
        .init(
          meetingID: id, passID: passID,
          stretchSequence: recognizer.stretchSequence, startMs: start, endMs: end,
          reason: reason, createdAt: clock.nowMilliseconds))
    } catch { throw LiveRecognizer.Failure.persistenceFailure }
    recorder?.record(
      phase: .transcriptLive, metric: .transcriptLiveGapMs,
      itemCount: UInt32(clamping: end - start), meetingKey: reason.rawValue)
  }

  private func updateLag(_ recognizer: LiveRecognizer, discard: Bool) async throws {
    let wasSuspended = recognizer.queue.suspended
    var state = AnalysisQueue.lagPolicy(lag: recognizer.lag, occupancy: recognizer.queue.occupancy)
    if state == .degraded { degraded = true }
    if discard {
      for range in recognizer.applyBackpressure() {
        degraded = true
        try await recordGap(range, reason: .backpressure, recognizer: recognizer)
      }
      if !wasSuspended {
        state = AnalysisQueue.lagPolicy(lag: recognizer.lag, occupancy: recognizer.queue.occupancy)
      }
    }
    if recognizer.lag <= AnalysisQueue.catchingUpLagSamples { degraded = false }
    if degraded, state != .suspended { state = .degraded }
    if status?.liveState != state {
      try await persistLiveState(state)
      recorder?.record(
        phase: .transcriptLive, metric: .transcriptBackpressureEvent,
        itemCount: 1, meetingKey: state.rawValue)
    }
    recorder?.record(
      phase: .transcriptLive, metric: .transcriptAnalysisQueueDepth,
      itemCount: UInt32(recognizer.queue.occupancy))
  }

  private func flush(force: Bool) async throws {
    guard !flushing, let id = meetingID, let recognizer else { return }
    let elapsed = clock.monotonicNanoseconds &- lastFlush
    guard recognizer.pendingCount > 0,
      force || recognizer.pendingCount >= 50 || elapsed >= 2_000_000_000
    else { return }
    flushing = true
    defer { flushing = false }
    repeat {
      let batch = recognizer.pendingBatch()
      guard !batch.isEmpty else { break }
      let started = clock.monotonicNanoseconds
      do {
        _ = try await store.appendSegments(
          meetingID: id, passID: passID, drafts: batch,
          progress: nil, now: clock.nowMilliseconds)
        persistenceFailures = 0
      } catch let error as TranscriptStore.Error {
        if case .capacityExceeded = error { throw error }
        persistenceFailures += 1
        if persistenceFailures >= 4 { throw LiveRecognizer.Failure.persistenceFailure }
        if force { continue }
        return
      } catch {
        persistenceFailures += 1
        if persistenceFailures >= 4 { throw LiveRecognizer.Failure.persistenceFailure }
        if force { continue }
        return
      }
      recognizer.acknowledgeBatch(count: batch.count)
      lastFlush = clock.monotonicNanoseconds
      let committed = batch.map {
        TranscriptSegment(
          id: UUID(), meetingID: id, passID: passID,
          draft: $0, createdAt: clock.nowMilliseconds)
      }
      if displayedMeetingID == id {
        liveModel.append(committed)
        status?.provisionalCount += batch.count
      }
      recorder?.record(
        phase: .transcriptLive, durationNanoseconds: clock.monotonicNanoseconds &- started,
        metric: .transcriptPersistenceBatchDuration)
      recorder?.record(
        phase: .transcriptLive, metric: .transcriptSegmentsProvisional,
        itemCount: UInt32(batch.count))
    } while force || recognizer.pendingCount >= 50
  }

  func meetingDidPause(id: UUID) {
    if pendingStart?.id == id {
      pendingStart?.paused = true
      detach(pendingStart?.taps ?? [:])
      return
    }
    guard meetingID == id, requested else { return }
    paused = true
    detach(taps)
    timer?.cancel()
    timer = nil
    let previous = boundaryTask
    boundaryTask = Task { [weak self] in
      await previous?.value
      await self?.startTask?.value
      await self?.finishStretch()
    }
    retentionTask?.cancel()
    let clock = clock
    let pendingLoad = startTask
    let pauseBoundary = boundaryTask
    retentionTask = Task { [weak self] in
      do { try await clock.sleep(for: .seconds(600)) } catch { return }
      guard let self else { return }
      await pauseBoundary?.value
      await pendingLoad?.value
      guard !Task.isCancelled, self.meetingID == id, self.paused, !self.stopped,
        let lease = self.lease
      else { return }
      self.lease = nil
      try? await self.lifecycle.finish(lease)
    }
  }
  private func finishStretch() async {
    let id = meetingID
    await pumpTask?.value
    guard meetingID == id else { return }
    while flushing || ticking { await Task.yield() }
    guard meetingID == id else { return }
    guard let recognizer else { return }
    do {
      if let mixer {
        while await mixer.hasPendingBlocks {
          try await ingest(try await mixer.tick(), recognizer: recognizer)
        }
        try await ingest(try await mixer.flush(), recognizer: recognizer)
      }
      // A pause permits one final inference. Everything else remains represented
      // by a gap so a slow model cannot prolong a pause indefinitely.
      if !stopped { _ = try await recognizer.processNext(tail: true) }
      for range in recognizer.discardRemaining() {
        try await recordGap(
          range, reason: stopped ? .stopDrain : .pauseDrain, recognizer: recognizer)
      }
      try await flush(force: true)
      let tracks = await mixer?.descriptor.contributingTracks ?? []
      guard meetingID == id, self.recognizer === recognizer, let id else { return }
      let length = Int64(recognizer.streamEnd) * 1_000 / 16_000
      descriptor.appendStretch(
        .init(
          sequence: recognizer.stretchSequence, lengthMs: length,
          tracks: tracks.count > 1 ? .both : tracks.first ?? .mic))
      let row = try await store.updateLiveMetadata(
        meetingID: id, descriptor: descriptor,
        incrementModelReloads: false, now: clock.nowMilliseconds)
      publish(row)
      baseMs += length
      ordinal = recognizer.nextSegmentOrdinal
      self.recognizer = nil
      mixer = nil
      try await persistLiveState(.stopped)
    } catch { await fail(Self.category(error)) }
  }

  func meetingDidStop(id: UUID) {
    if pendingStart?.id == id {
      detach(pendingStart?.taps ?? [:])
      pendingStart = nil
      return
    }
    guard meetingID == id else { return }
    stopped = true
    stopBeganAt[id] = clock.monotonicNanoseconds
    retentionTask?.cancel()
    retentionTask = nil
    detach(taps)
    timer?.cancel()
    timer = nil
    let previous = boundaryTask
    boundaryTask = Task { [weak self] in
      guard let self, self.meetingID == id else { return }
      // A watchdog revokes and joins inference only when the specified 30 seconds expire.
      let lifecycle = self.lifecycle
      let clock = self.clock
      let watchdog = Task {
        do { try await clock.sleep(for: .seconds(30)) } catch { return }
        await lifecycle.cancelSessionAndJoin(id)
      }
      await previous?.value
      await self.startTask?.value
      guard self.meetingID == id else {
        watchdog.cancel()
        return
      }
      await self.finishStretch()
      watchdog.cancel()
      guard self.meetingID == id else { return }
      if let lease = self.lease { try? await lifecycle.finish(lease) }
      guard self.meetingID == id else { return }
      self.lease = nil
      self.meetingID = nil
      self.startTask = nil
      self.loadTask = nil
      self.pumpTask = nil
      self.recognizer = nil
      self.mixer = nil
      self.taps = [:]
      await self.finishLivePass(id: id)
    }
  }

  /// `live → finalizing` once the drain is done; the final pass starts when the
  /// meeting reports completion (or now, if it already did).
  private func finishLivePass(id: UUID) async {
    guard requested, !deletedMeetings.contains(id) else {
      pumpFinalizations()
      return
    }
    guard let row = try? await store.transcription(meetingID: id) else { return }
    var current = row
    if row.state == .live,
      let transitioned = try? await store.transition(
        meetingID: id, to: .finalizing, now: clock.nowMilliseconds, effects: [])
    {
      current = transitioned
      publish(current)
    }
    guard current.state == .finalizing || current.state == .pending else {
      pumpFinalizations()
      return
    }
    if completedMeetings.remove(id) != nil {
      enqueueFinalization(.init(meetingID: id, revision: nil))
    } else {
      awaitingCompletion.insert(id)
    }
    pumpFinalizations()
  }
  /// Quit joins the same bounded stop drain so committed and pending text survive shutdown.
  func shutdown() async {
    detach(pendingStart?.taps ?? [:])
    pendingStart = nil
    finalizationQueue.removeAll()
    finalizationTask?.cancel()
    await finalizationTask?.value
    await admissionTask?.value
    if let id = meetingID, !stopped { meetingDidStop(id: id) }
    await boundaryTask?.value
    await startTask?.value
    await pumpTask?.value
    finalizationQueue.removeAll()
    finalizationTask?.cancel()
    await finalizationTask?.value
    if let lease { try? await lifecycle.finish(lease) }
    lease = nil
    timer?.cancel()
    timer = nil
    detach(taps)
    taps = [:]
    mixer = nil
    recognizer = nil
    meetingID = nil
    startTask = nil
    loadTask = nil
    pumpTask = nil
    boundaryTask = nil
  }

  func meetingDidComplete(id: UUID, detail: MeetingDetail) {
    if detail.meeting.state == .failed, meetingID == id { meetingDidStop(id: id) }
    if meetingID == id || pendingStart?.id == id {
      completedMeetings.insert(id)
      return
    }
    if awaitingCompletion.remove(id) != nil {
      enqueueFinalization(.init(meetingID: id, revision: nil))
      return
    }
    // Completed without a live session (stopped during the model load, or a
    // finalization interrupted by an earlier launch): the row decides.
    Task { [weak self] in
      guard let self, let row = try? await self.store.transcription(meetingID: id),
        row.state == .finalizing || row.state == .pending
      else { return }
      self.enqueueFinalization(.init(meetingID: id, revision: nil))
    }
  }

  /// Retry, Transcribe and Re-transcribe: one queue, one finalizer. The revision
  /// from the row the user saw makes a stale request a notice, never a write.
  func requestFinalization(meetingID id: UUID, revision: Int64) {
    enqueueFinalization(.init(meetingID: id, revision: revision))
  }

  /// Launch resume for `finalizing` rows found by reconciliation.
  func resumeFinalizations(_ ids: [UUID]) {
    for id in ids { enqueueFinalization(.init(meetingID: id, revision: nil)) }
  }

  private func enqueueFinalization(_ request: FinalizationRequest, atHead: Bool = false) {
    guard finalizer != nil else { return }
    guard !finalizationQueue.contains(where: { $0.meetingID == request.meetingID }),
      finalizingMeetingID != request.meetingID
    else { return }
    guard finalizationQueue.count < Self.finalizationQueueCapacity else {
      noticePublished?(TranscriptErrorMessage.tooManyWaiting)
      return
    }
    if atHead {
      finalizationQueue.insert(request, at: 0)
    } else {
      finalizationQueue.append(request)
    }
    pumpFinalizations()
  }

  private func pumpFinalizations() {
    // A meeting recorded without transcription holds no session and no lease.
    guard let finalizer, finalizationTask == nil, meetingID == nil || !requested,
      pendingStart == nil, admissionTask == nil, !finalizationQueue.isEmpty
    else { return }
    let request = finalizationQueue.removeFirst()
    let id = request.meetingID
    finalizingMeetingID = id
    if meetingID == nil {
      displayedMeetingID = id
      liveModel.reset()
    }
    let store = store
    let clock = clock
    startRSSSampler()
    finalizationTask = Task { [weak self] in
      defer {
        self?.finalizingMeetingID = nil
        self?.finalizationTask = nil
        self?.rssTask?.cancel()
        self?.rssTask = nil
        self?.pumpFinalizations()
      }
      guard let self else { return }
      do {
        guard let row = try await store.transcription(meetingID: id) else { return }
        self.publish(row, phase: .transcriptFinalizing)
        if self.status?.meetingID == id { self.status?.progress = 0 }
        if let stopBegan = self.stopBeganAt.removeValue(forKey: id) {
          self.recorder?.record(
            phase: .transcriptFinalizing,
            durationNanoseconds: clock.monotonicNanoseconds &- stopBegan,
            metric: .transcriptFinalizationWaitDuration)
        }
        let outcome = try await finalizer.run(
          meetingID: id, revision: request.revision ?? row.revision,
          progress: { [weak self] fraction in
            Task { @MainActor in
              guard let self, self.status?.meetingID == id else { return }
              self.status?.progress = fraction
            }
          })
        // Kept for inspection only; the echo profile goes to diarization below and
        // is not retained here.
        self.lastFinalization = outcome.withoutEchoProfile
        self.publish(outcome.row, phase: .transcriptFinalizing)
        if self.status?.meetingID == id { self.status?.progress = 1 }
        // `MeetingFinalizer.run` finished the lease before returning the outcome.
        if outcome.row.state == .final {
          if let diarization = self.diarization {
            // The pass's echo profile rides along so diarization does not decode
            // both tracks again; the automatic summary waits for speaker work to
            // settle (FR-002, settle instead of transcript-final).
            diarization.meetingTranscriptDidFinalize(
              id: id, echoProfile: outcome.echoProfile)
          } else {
            self.intelligence?.meetingSpeakersDidSettle(id: id)
          }
        }
      } catch is CancellationError {
        // The pass advanced the row, so the user's revision no longer applies.
        self.finalizingMeetingID = nil
        if !self.deletedMeetings.contains(id) {
          self.enqueueFinalization(.init(meetingID: id, revision: nil), atHead: true)
        }
      } catch let error as MeetingFinalizer.Error {
        switch error {
        case .staleRevision:
          self.noticePublished?(TranscriptErrorMessage.changed)
        case .noSourceAudio:
          // Nothing to transcribe. An automatic request marks the row so the
          // library stops waiting; a user request only explains.
          if request.revision == nil,
            let row = try? await store.transcription(meetingID: id),
            row.state == .finalizing || row.state == .pending,
            let failed = try? await store.transition(
              meetingID: id, to: .failed, now: clock.nowMilliseconds,
              effects: [
                .setFailure(category: .finalizationInterrupted, detail: "no_source_audio")
              ])
          {
            self.publish(failed, phase: .transcriptFinalizing)
          } else {
            self.noticePublished?(TranscriptErrorMessage.noSourceAudio)
          }
        case .meetingActive:
          self.logSink("finalization skipped: meeting not terminal")
        case .failed(let category, _):
          self.noticePublished?(TranscriptErrorMessage.message(for: category, finalMeeting: true))
          if let row = try? await store.transcription(meetingID: id) {
            self.publish(row, phase: .transcriptFinalizing)
          }
        }
      } catch {
        if let row = try? await store.transcription(meetingID: id) {
          self.publish(row, phase: .transcriptFinalizing)
        }
      }
    }
  }

  private func startRSSSampler() {
    guard rssTask == nil, let recorder else { return }
    let clock = clock
    rssTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: Self.rssInterval) } catch { return }
        guard let self, self.finalizingMeetingID != nil else { return }
        recorder.record(phase: .transcriptFinalizing, rssBytes: ResourceRecorder.residentBytes())
      }
    }
  }

  func meetingWillDelete(id: UUID) async {
    if deletedMeetings.count >= 1_000 { deletedMeetings.removeAll() }
    deletedMeetings.insert(id)
    finalizationQueue.removeAll { $0.meetingID == id }
    awaitingCompletion.remove(id)
    completedMeetings.remove(id)
    stopBeganAt.removeValue(forKey: id)
    if finalizingMeetingID == id {
      finalizationTask?.cancel()
      await finalizationTask?.value
    }
    if pendingStart?.id == id {
      detach(pendingStart?.taps ?? [:])
      pendingStart = nil
      return
    }
    guard meetingID == id else { return }
    stopped = true
    retentionTask?.cancel()
    retentionTask = nil
    timer?.cancel()
    timer = nil
    detach(taps)
    loadTask?.cancel()
    let oldStart = startTask
    let oldPump = pumpTask
    let oldBoundary = boundaryTask
    await lifecycle.cancelSessionAndJoin(id)
    await oldStart?.value
    await oldPump?.value
    await oldBoundary?.value
    guard meetingID == id else { return }
    recognizer = nil
    mixer = nil
    taps = [:]
    lease = nil
    meetingID = nil
  }
  private func fail(_ category: TranscriptFailureCategory, detail: String? = nil) async {
    guard let id = meetingID, status?.state != .failed else { return }
    stopped = true
    retentionTask?.cancel()
    retentionTask = nil
    timer?.cancel()
    timer = nil
    detach(taps)
    taps = [:]
    if let row = try? await store.transition(
      meetingID: id, to: .failed, now: clock.nowMilliseconds,
      effects: [.setFailure(category: category, detail: detail)])
    {
      publish(row)
    }
    guard meetingID == id else { return }
    loadTask?.cancel()
    await lifecycle.cancelSessionAndJoin(id)
    guard meetingID == id else { return }
    lease = nil
    recognizer = nil
    mixer = nil
    taps = [:]
    recorder?.record(
      phase: .transcriptLive, metric: .transcriptFailure, itemCount: 1,
      meetingKey: category.rawValue)
  }
  private func persistLiveState(_ state: LiveState) async throws {
    guard let id = meetingID, status?.state == .live else { return }
    do {
      try await store.setLiveState(meetingID: id, liveState: state, now: clock.nowMilliseconds)
      if let row = try await store.transcription(meetingID: id) { publish(row) }
    } catch { throw LiveRecognizer.Failure.persistenceFailure }
  }

  private func publish(_ row: MeetingTranscription, phase: ResourceRecorder.Phase = .transcriptLive)
  {
    guard row.meetingID == displayedMeetingID else { return }
    let previous = status?.meetingID == row.meetingID ? status : nil
    var next = TranscriptStatus(
      meetingID: row.meetingID, state: row.state, liveState: row.liveState,
      failure: row.failureCategory, metadata: row)
    switch row.state {
    case .final:
      next.finalCount = row.segmentCount
    case .finalizing:
      next.provisionalCount = previous?.provisionalCount ?? 0
      next.finalCount = max(0, row.segmentCount - next.provisionalCount)
      next.progress = previous?.progress ?? 0
    case .failed, .interrupted:
      if row.passKind == .final {
        next.provisionalCount = previous?.provisionalCount ?? 0
        next.finalCount = max(0, row.segmentCount - next.provisionalCount)
      } else {
        next.provisionalCount = row.segmentCount
      }
    default:
      next.provisionalCount = row.segmentCount
    }
    status = next
    // The finalizer records its own transitions; the live path records here.
    guard row.state != .notRequested, phase == .transcriptLive else { return }
    recorder?.record(
      phase: phase, metric: .transcriptTransition, itemCount: 1,
      meetingKey: row.state.rawValue)
  }
  private static func category(_ error: Error) -> TranscriptFailureCategory {
    if let error = error as? TranscriptStore.Error, case .capacityExceeded = error {
      return .persistenceCapacity
    }
    if error is AnalysisStreamMixer.Failure { return .analysisStreamFailure }
    return switch error as? LiveRecognizer.Failure {
    case .persistenceFailure: .persistenceFailure
    case .analysisStreamFailure: .analysisStreamFailure
    default: .runtimeFailure
    }
  }
}

extension Dictionary {
  fileprivate func mapValuesWithKey<T>(_ transform: (Key, Value) throws -> T) rethrows -> [Key: T] {
    try [Key: T](uniqueKeysWithValues: map { (key, value) in (key, try transform(key, value)) })
  }
}
