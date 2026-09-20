import AVFoundation
import Foundation
import OSLog

/// One diarization run over a finalized meeting (contracts/diarization-pipeline.md "Run
/// pipeline"). Each track is decoded on its own through the Feature 005 mixer into one
/// reusable 10-minute window, diarized, reconciled and persisted window by window. The
/// lease is finished before alignment. Transcript rows, notes and audio are only read.
actor MeetingDiarizer {
  enum AdmissionError: Swift.Error, Equatable {
    case meetingActive, transcriptNotFinal, missingMeeting
  }

  enum Outcome: Sendable, Equatable {
    case succeeded(DiarizationRun)
    case failed(DiarizationFailureCategory)
    /// Speech recognition revoked the lease; the run is `pending` again.
    case preempted
    /// The task was cancelled (user Cancel or meeting deletion); the run row is gone.
    case cancelled
    /// Another lease or an installation holds the model; the run stays `pending`.
    case busy
    /// No pending run for the meeting.
    case nothingToRun
  }

  static let decodeFrames: AVAudioFrameCount = 4_096
  /// Segments aligned per page. The page API returns at most 200 rows, inside the
  /// contract's 500-segment bound.
  static let alignmentPage = 200
  static let turnPage = 1_000

  private let speakers: any SpeakerStoring
  private let transcripts: any TranscriptStoring
  private let meetings: any MeetingStoring
  private let storageRoot: MeetingStorageRoot
  private let lifecycle: ModelLifecycleCoordinator
  private let identity: DiarizationIdentity
  private let clock: any MeetingClock
  /// FR-037: content-free run metrics; nil in tests that do not measure.
  private let recorder: ResourceRecorder?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "speakers")

  private var shuttingDown = false
  /// One window buffer for every run; refilled in place.
  private var window = [Float](repeating: 0, count: DiarizationConstants.windowSamples)

  init(
    speakers: any SpeakerStoring, transcripts: any TranscriptStoring,
    meetings: any MeetingStoring, storageRoot: MeetingStorageRoot,
    lifecycle: ModelLifecycleCoordinator, identity: DiarizationIdentity,
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil
  ) {
    self.speakers = speakers
    self.transcripts = transcripts
    self.meetings = meetings
    self.storageRoot = storageRoot
    self.lifecycle = lifecycle
    self.identity = identity
    self.clock = clock
    self.recorder = recorder
  }

  // MARK: Admission

  /// A terminal meeting with a `final` transcript gets a `pending` run against the
  /// transcript's current pass.
  func admit(meetingID: UUID, trigger: DiarizationTrigger, expectedRevision: Int64?)
    async throws -> DiarizationRun
  {
    guard let meeting = try await meetings.meeting(id: meetingID) else {
      throw AdmissionError.missingMeeting
    }
    guard meeting.state.isTerminal else { throw AdmissionError.meetingActive }
    guard let row = try await transcripts.transcription(meetingID: meetingID),
      row.state == .final, let passID = row.passID
    else { throw AdmissionError.transcriptNotFinal }
    return try await speakers.admit(
      meetingID: meetingID, transcriptPassID: passID, trigger: trigger, identity: identity,
      expectedRevision: expectedRevision, now: clock.nowMilliseconds)
  }

  // MARK: Run

  private struct Failure: Swift.Error {
    let category: DiarizationFailureCategory
    let detail: String?
    init(_ category: DiarizationFailureCategory, _ detail: String? = nil) {
      self.category = category
      self.detail = detail
    }
  }
  private struct Preempted: Swift.Error {}

  private struct Context {
    let run: DiarizationRun
    let lease: ModelLease
    let progress: (@Sendable (Int, Int) -> Void)?
    let planned: Int
    var done = 0
    var nextKey = 0
    /// Speaker row id per run cluster key, and back.
    var ids: [Int: UUID] = [:]
    var keys: [UUID: Int] = [:]
    /// Reconciliation tallies for the run metrics.
    var matched = 0
    var created = 0
    var uncertain = 0
    let startedNs: UInt64
  }

  /// Runs the meeting's pending run to a terminal state. `progress` gets
  /// (windows done, windows planned).
  func run(meetingID: UUID, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Outcome {
    let pending: DiarizationRun
    do {
      guard let row = try await speakers.diarization(meetingID: meetingID),
        let current = row.currentRunID, let run = try await speakers.run(id: current),
        run.state == .pending
      else { return .nothingToRun }
      pending = run
    } catch {
      return .nothingToRun
    }
    let detail: MeetingDetail
    do {
      guard let loaded = try await meetings.detail(id: meetingID) else {
        return await fail(pending.id, Failure(.audioMissing))
      }
      detail = loaded
      guard let row = try await transcripts.transcription(meetingID: meetingID),
        row.state == .final, row.passID == pending.transcriptPassID
      else { return await fail(pending.id, Failure(.transcriptChanged)) }
    } catch {
      return await fail(pending.id, Failure(.persistenceFailure))
    }
    guard hasTrackAudio(detail) else { return await fail(pending.id, Failure(.audioMissing)) }
    // Acquire before `start`, so a busy model leaves the run pending with no progress.
    let lease: ModelLease
    do {
      lease = try await lifecycle.acquire(session: meetingID, workload: .diarization)
    } catch {
      if Task.isCancelled { return await cancel(pending.id) }
      if let category = error as? DiarizationFailureCategory {
        return await fail(pending.id, Failure(category))
      }
      switch error as? DictationFailure {
      case .busy: return .busy
      case .cancelled: return .preempted
      case .modelUnavailable: return await fail(pending.id, Failure(.modelUnavailable))
      default: return await fail(pending.id, Failure(.modelLoadFailure))
      }
    }
    var context: Context
    do {
      let started = try await speakers.start(runID: pending.id, now: clock.nowMilliseconds)
      context = Context(
        run: started, lease: lease, progress: progress, planned: Self.plannedWindows(detail),
        startedNs: clock.monotonicNanoseconds)
      // "Labeling speakers… 0%" from the first window on, not after it.
      progress?(0, max(context.planned, 1))
    } catch {
      try? await lifecycle.finish(lease)
      return await fail(pending.id, Failure(.persistenceFailure))
    }
    do {
      let base = try await transcriptBases(meetingID: meetingID)
      let pages =
        (MeetingFinalizer.stretchCount(detail: detail) + MeetingFinalizer.workListPage - 1)
        / MeetingFinalizer.workListPage
      // System first, then microphone (research R5).
      for kind in [MeetingTrackKind.system, .microphone] {
        var reconciler = WindowClusterReconciler()
        let numSpeakers = kind == .microphone && !context.run.inRoom ? 1 : nil
        for page in 0..<pages {
          for item in MeetingFinalizer.workItems(detail: detail, page: page) {
            guard let track = item.tracks.first(where: { $0.kind == kind }) else { continue }
            let stretch = base[item.sequence] ?? (item.baseMs, nil)
            try await diarizeStretch(
              track, baseMs: stretch.0, lengthMs: stretch.1, numSpeakers: numSpeakers,
              reconciler: &reconciler, context: &context)
          }
        }
      }
      try await lifecycle.finish(lease)
    } catch {
      return await end(context.run.id, lease: lease, error: error)
    }
    // After `finish` there is no lease to revoke; only Cancel and deletion stop the run.
    do {
      let assignments = try await align(meetingID: meetingID, context: context)
      try Task.checkCancellation()
      guard
        try await transcripts.transcription(meetingID: meetingID)?.passID
          == context.run.transcriptPassID
      else { throw Failure(.transcriptChanged) }
      let completed = try await speakers.complete(
        runID: context.run.id, assignments: assignments, now: clock.nowMilliseconds)
      logger.notice(
        "diarization complete windows=\(completed.windowCount) speakers=\(completed.inferredSpeakerCount) turns=\(completed.turnCount)"
      )
      record(completed, context: context)
      return .succeeded(completed)
    } catch {
      return await end(context.run.id, lease: nil, error: error)
    }
  }

  /// FR-037: the run's numbers, never its names, text or ids.
  private func record(_ run: DiarizationRun, context: Context) {
    guard let recorder else { return }
    let elapsed = clock.monotonicNanoseconds &- context.startedNs
    recorder.record(phase: .diarizing, durationNanoseconds: elapsed, metric: .diarizationDuration)
    if run.audioMs > 0 {
      // RTF in nanoseconds of processing per second of audio, like the transcript metric.
      recorder.record(
        phase: .diarizing, durationNanoseconds: elapsed / UInt64(max(1, run.audioMs / 1_000)),
        metric: .diarizationRealTimeFactor)
    }
    let counts: [(ResourceRecorder.Metric, Int)] = [
      (.diarizationAudioMs, Int(clamping: run.audioMs)), (.diarizationWindowCount, run.windowCount),
      (.diarizationSpeakerCount, run.inferredSpeakerCount),
      (.diarizationTurnCount, run.turnCount),
      (.diarizationOverlapTurnCount, run.overlapTurnCount),
      (.diarizationUnknownCount, run.unknownCount),
      (.diarizationAmbiguousCount, run.ambiguousCount),
      (.diarizationReconciledMatches, context.matched),
      (.diarizationReconciledNew, context.created),
      (.diarizationReconciledUncertain, context.uncertain),
      (.diarizationOverflowTurns, run.overflowTurns),
    ]
    for (metric, value) in counts {
      recorder.record(phase: .diarizing, metric: metric, itemCount: UInt32(clamping: max(0, value)))
    }
  }

  // MARK: Windows

  private func diarizeStretch(
    _ track: FinalizationWorkItem.Track, baseMs: Int64, lengthMs: Int64?, numSpeakers: Int?,
    reconciler: inout WindowClusterReconciler, context: inout Context
  ) async throws {
    guard let url = storageRoot.resolve(relativePath: track.relativePath),
      FileManager.default.fileExists(atPath: url.path)
    else { return }
    let reader: AVAudioFile
    do { reader = try AVAudioFile(forReading: url) } catch {
      throw Failure(.audioDecodeFailure, "open")
    }
    let format = reader.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.decodeFrames) else {
      throw Failure(.audioDecodeFailure, "buffer")
    }
    let mixer: AnalysisStreamMixer
    do {
      mixer = try AnalysisStreamMixer(
        decoding: [
          track.kind: .init(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        ])
    } catch { throw Failure(.audioDecodeFailure, "format") }
    var stretch = StretchWindow(baseMs: baseMs, lengthMs: lengthMs, numSpeakers: numSpeakers)
    do {
      while true {
        buffer.frameLength = 0
        // ADTS files report their length; a read at the end throws.
        if reader.framePosition < reader.length {
          do {
            try reader.read(into: buffer, frameCount: Self.decodeFrames)
          } catch { throw Failure(.audioDecodeFailure, "read") }
        }
        guard buffer.frameLength > 0 else { break }
        var attempts = 0
        while try !mixer.append(buffer, kind: track.kind) {
          attempts += 1
          guard attempts <= 4 else { throw Failure(.audioDecodeFailure, "staging") }
          try await feed(
            try mixer.tick(), stretch: &stretch, track: track.kind,
            reconciler: &reconciler, context: &context)
        }
        try await feed(
          try mixer.tick(), stretch: &stretch, track: track.kind,
          reconciler: &reconciler, context: &context)
      }
      mixer.markEnded(track.kind)
      try await feed(
        try mixer.flush(), stretch: &stretch, track: track.kind,
        reconciler: &reconciler, context: &context)
    } catch is AnalysisStreamMixer.Failure {
      throw Failure(.audioDecodeFailure, "convert")
    }
    if stretch.fill > 0 {
      try await diarizeWindow(
        &stretch, track: track.kind, reconciler: &reconciler, context: &context)
    }
  }

  private struct StretchWindow {
    let baseMs: Int64
    /// The transcript's length for this stretch; nil clamps to the decoded length.
    let lengthMs: Int64?
    let numSpeakers: Int?
    var fill = 0
    var windowStart = 0
  }

  private func feed(
    _ emissions: [AnalysisStreamMixer.Emission], stretch: inout StretchWindow,
    track: MeetingTrackKind, reconciler: inout WindowClusterReconciler, context: inout Context
  ) async throws {
    for emission in emissions {
      var offset = 0
      while offset < emission.samples.count {
        let count = min(window.count - stretch.fill, emission.samples.count - offset)
        let fill = stretch.fill
        window.withUnsafeMutableBufferPointer { target in
          emission.samples.withUnsafeBufferPointer { source in
            for index in 0..<count { target[fill + index] = source[offset + index] }
          }
        }
        stretch.fill += count
        offset += count
        if stretch.fill == window.count {
          try await diarizeWindow(
            &stretch, track: track, reconciler: &reconciler, context: &context)
        }
      }
    }
  }

  private func diarizeWindow(
    _ stretch: inout StretchWindow, track: MeetingTrackKind,
    reconciler: inout WindowClusterReconciler, context: inout Context
  ) async throws {
    try Task.checkCancellation()
    let count = stretch.fill
    let samples = count == window.count ? window : Array(window.prefix(count))
    // Turns are clipped to the window and to the transcript's stretch.
    let offsetMs = stretch.baseMs + Int64(stretch.windowStart) * 1_000 / 16_000
    var endMs = stretch.baseMs + Int64(stretch.windowStart + count) * 1_000 / 16_000
    if let lengthMs = stretch.lengthMs { endMs = min(endMs, stretch.baseMs + lengthMs) }
    stretch.windowStart += count
    stretch.fill = 0
    let result: DiarizationWindowResult
    let lifecycle = lifecycle
    let lease = context.lease
    do {
      result = try await withTaskCancellationHandler {
        try await lifecycle.diarize(
          lease, window: .init(samples: samples, numSpeakers: stretch.numSpeakers))
      } onCancel: {
        // Cancel and deletion revoke the lease; the lifecycle joins the window.
        Task { await lifecycle.cancelAndJoin(lease) }
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if error is CancellationError { throw Preempted() }
      switch error as? DictationFailure {
      case .cancelled, .staleLease: throw Preempted()
      default: throw Failure(.runtimeFailure, "window")
      }
    }
    let mapping = reconciler.reconcile(result, nextKey: &context.nextKey)
    context.created += mapping.created.count
    context.uncertain += mapping.created.filter { $0.reconciliation == .uncertain }.count
    context.matched += mapping.keys.count - mapping.created.count
    var drafts: [SpeakerDraft] = []
    for created in mapping.created {
      let id = UUID()
      context.ids[created.key] = id
      context.keys[id] = created.key
      drafts.append(
        .init(id: id, clusterKey: created.key, track: track, reconciliation: created.reconciliation)
      )
    }
    let turns = result.turns.compactMap { turn -> TurnDraft? in
      let start = min(max(offsetMs + Int64((turn.startSeconds * 1_000).rounded()), offsetMs), endMs)
      let end = min(max(offsetMs + Int64((turn.endSeconds * 1_000).rounded()), offsetMs), endMs)
      guard start < end else { return nil }
      return TurnDraft(
        speakerID: mapping.keys[turn.cluster].flatMap { context.ids[$0] }, track: track,
        startMs: start, endMs: end, quality: turn.quality)
    }
    do {
      try await speakers.appendWindow(
        runID: context.run.id, speakers: drafts, turns: turns,
        audioMs: Int64(count) * 1_000 / 16_000)
    } catch let error as SpeakerStore.Error where error == .capacityExceeded {
      throw Failure(.persistenceCapacity)
    } catch {
      throw Failure(.persistenceFailure)
    }
    context.done += 1
    context.progress?(context.done, max(context.planned, context.done))
    try Task.checkCancellation()
    guard
      try await transcripts.transcription(meetingID: context.run.meetingID)?.passID
        == context.run.transcriptPassID
    else { throw Failure(.transcriptChanged) }
  }

  // MARK: Alignment

  private func align(meetingID: UUID, context: Context) async throws -> [AssignmentDraft] {
    var assignments: [AssignmentDraft] = []
    var after: Int?
    while true {
      try Task.checkCancellation()
      let page = try await transcripts.page(
        meetingID: meetingID, finality: .final, after: after, limit: Self.alignmentPage)
      guard let first = page.first, let last = page.last else { break }
      after = last.ordinal
      let segments = page.filter { $0.passID == context.run.transcriptPassID }
      let range = first.startMs..<max(page.map(\.endMs).max() ?? first.endMs, first.startMs + 1)
      var turns: [SpeakerAligner.Turn] = []
      var cursor: TurnCursor?
      // The turn API pages at 1,000; a dense span needs every page or segments go Unknown.
      while true {
        let batch = try await speakers.turns(
          runID: context.run.id, overlapping: range, after: cursor, limit: Self.turnPage)
        turns += batch.map {
          .init(
            speaker: $0.speakerID.flatMap { context.keys[$0] }, startMs: $0.startMs, endMs: $0.endMs
          )
        }
        guard batch.count == Self.turnPage, let tail = batch.last else { break }
        cursor = TurnCursor(startMs: tail.startMs, id: tail.id)
      }
      let aligned = SpeakerAligner.align(
        segments.map { .init(startMs: $0.startMs, endMs: $0.endMs) }, turns: turns)
      for (segment, result) in zip(segments, aligned) {
        assignments.append(
          .init(
            segmentID: segment.id, kind: result.kind,
            speakerID: result.speaker.flatMap { context.ids[$0] },
            topSpeakerID: result.top.flatMap { context.ids[$0] },
            secondSpeakerID: result.second.flatMap { context.ids[$0] },
            topCoverage: min(1, result.topCoverage), secondCoverage: min(1, result.secondCoverage)))
      }
      if page.count < Self.alignmentPage { break }
    }
    return assignments
  }

  // MARK: Endings

  private func end(_ runID: UUID, lease: ModelLease?, error: Swift.Error) async -> Outcome {
    if let lease {
      // `finish` keeps the Keep model ready re-prepare; a revoked lease just joins.
      do { try await lifecycle.finish(lease) } catch { await lifecycle.cancelAndJoin(lease) }
    }
    if Task.isCancelled || error is CancellationError { return await cancel(runID) }
    let revoked =
      error as? DictationFailure == .cancelled || error as? DictationFailure == .staleLease
    if error is Preempted || revoked {
      do {
        try await speakers.requeue(runID: runID)
        recorder?.record(phase: .diarizing, metric: .diarizationPreemption, itemCount: 1)
        return .preempted
      } catch {
        return await fail(runID, Failure(.persistenceFailure))
      }
    }
    if let failure = error as? Failure { return await fail(runID, failure) }
    if let error = error as? SpeakerStore.Error, error == .capacityExceeded {
      return await fail(runID, Failure(.persistenceCapacity))
    }
    return await fail(runID, Failure(.persistenceFailure))
  }

  private func cancel(_ runID: UUID) async -> Outcome {
    if shuttingDown {
      // Quit is not Cancel: a started run is interrupted, a pending one resumes next launch.
      if (try? await speakers.run(id: runID))??.state == .running {
        try? await speakers.interrupt(runID: runID, now: clock.nowMilliseconds)
      }
    } else {
      try? await speakers.cancel(runID: runID)
    }
    return .cancelled
  }

  /// Application quit: the next cancellation keeps the run for launch reconciliation.
  func prepareForShutdown() { shuttingDown = true }

  private func fail(_ runID: UUID, _ failure: Failure) async -> Outcome {
    try? await speakers.fail(
      runID: runID, category: failure.category, detail: failure.detail,
      now: clock.nowMilliseconds)
    logger.notice(
      "diarization failed category=\(failure.category.rawValue, privacy: .public) detail=\(failure.detail ?? "-", privacy: .public)"
    )
    recorder?.record(
      phase: .diarizing, metric: .diarizationFailure, itemCount: 1,
      meetingKey: failure.category.rawValue)
    return .failed(failure.category)
  }

  // MARK: Work list

  private func hasTrackAudio(_ detail: MeetingDetail) -> Bool {
    detail.tracks.contains { track in
      track.segments.contains { segment in
        segment.state == .finalized
          && storageRoot.resolve(relativePath: segment.relativePath).map {
            FileManager.default.fileExists(atPath: $0.path)
          } == true
      }
    }
  }

  /// The final pass's stretch bases and lengths, when its descriptor recorded them all.
  /// The finalizer advanced its base by each stretch's decoded length, so this is the
  /// base the transcript's segment times use.
  private func transcriptBases(meetingID: UUID) async throws -> [Int: (Int64, Int64?)] {
    guard
      let descriptor = try await transcripts.transcription(meetingID: meetingID)?
        .analysisDescriptor, !descriptor.stretchesTruncated
    else { return [:] }
    var bases: [Int: (Int64, Int64?)] = [:]
    var base: Int64 = 0
    for stretch in descriptor.stretches {
      bases[stretch.sequence] = (base, stretch.lengthMs)
      base += stretch.lengthMs
    }
    return bases
  }

  /// Windows the run expects: per track and stretch, the stretch length over the window.
  static func plannedWindows(_ detail: MeetingDetail) -> Int {
    let windowMs = Int64(DiarizationConstants.windowSamples / 16)
    return detail.tracks.reduce(0) { total, track in
      total
        + track.segments.filter { $0.state == .finalized && $0.durationMs > 0 }.reduce(0) {
          $0 + Int(($1.durationMs + windowMs - 1) / windowMs)
        }
    }
  }
}
