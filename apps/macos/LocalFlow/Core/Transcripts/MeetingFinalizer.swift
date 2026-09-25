import AVFoundation
import Foundation
import OSLog

/// One final pass over a meeting's durable tracks with the production geometry.
/// Every entry point (automatic after stop, Retry, Transcribe, launch resume) calls
/// `run`. Progress is persisted with every batch, so a pass that stops between
/// windows resumes at the next window and never re-finalizes a persisted row.
/// Decoding holds one 4,096-frame buffer per track, the mixer's stagings and one
/// bounded inference window. The runtime may use one bounded temporary WAV.
actor MeetingFinalizer {
  enum Error: Swift.Error, Equatable {
    case staleRevision, meetingActive, noSourceAudio
    case failed(TranscriptFailureCategory, detail: String?)
  }
  struct Outcome: Sendable, Equatable {
    let row: MeetingTranscription
    let windowCount: Int
    let totalGapCount: Int
    let coveredGapCount: Int
    let coveredGapMs: Int64
    /// The per-track echo energy profile this pass calibrated from, for the
    /// diarizer to reuse instead of decoding both tracks again. nil unless the
    /// layout profiled echo (per-track); the stretches keep a zero base.
    let echoProfile: EchoGate.Profile?

    /// The same outcome without its echo profile, for callers that keep it around.
    var withoutEchoProfile: Outcome {
      Outcome(
        row: row, windowCount: windowCount, totalGapCount: totalGapCount,
        coveredGapCount: coveredGapCount, coveredGapMs: coveredGapMs, echoProfile: nil)
    }
  }
  struct Configuration: Sendable {
    let windowSamples: Int
    let geometry: String
    let workload: ModelWorkload
    /// Per track: each track is decoded, levelled and recognized on its own, the
    /// microphone with speaker echo of the remote side muted; rows of a window are
    /// merged by time. Mixed: one `0.5·mic + 0.5·system` stream (Feature 005).
    let layout: AnalysisStreamDescriptor.Layout

    private init(
      windowSamples: Int, geometry: String, workload: ModelWorkload,
      layout: AnalysisStreamDescriptor.Layout
    ) {
      self.windowSamples = windowSamples
      self.geometry = geometry
      self.workload = workload
      self.layout = layout
    }

    static let parakeet = Configuration(
      windowSamples: 239_360, geometry: "contiguous_fixed239360_preserve_v1",
      workload: .speechRecognition, layout: .mixed)
    static let turbo = Configuration(
      windowSamples: 1_920_000, geometry: "per_track_fixed1920000_turbo_level_v2",
      workload: .meetingTranscription, layout: .perTrack)
  }

  static let geometry = "contiguous_fixed239360_preserve_v1"
  static let windowSamples = 239_360
  static let decodeFrames: AVAudioFrameCount = 4_096
  static let workListPage = 100
  static let workListCapacity = 10_000
  static let batchCapacity = 50
  static let batchIntervalNanoseconds: UInt64 = 2_000_000_000
  static let persistenceAttempts = 4

  private let store: any TranscriptStoring
  private let meetings: any MeetingStoring
  private let storageRoot: MeetingStorageRoot
  private let lifecycle: ModelLifecycleCoordinator
  private let vocabulary: any VocabularyProviding
  private let identity: TranscriptionPipelineIdentity
  private let configuration: Configuration
  /// The Settings language, for a meeting without its own; the pass's language is
  /// read once per run, recorded in the pipeline version (`lang_<code>_prompt_v1`) and
  /// handed to the lifecycle, so the runtime decodes in the recorded language.
  private let defaultLanguage: @Sendable () async -> MeetingLanguage
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let logSink: @Sendable (String) -> Void

  init(
    store: any TranscriptStoring, meetings: any MeetingStoring, storageRoot: MeetingStorageRoot,
    lifecycle: ModelLifecycleCoordinator,
    vocabulary: any VocabularyProviding = EmptyVocabularyProvider(),
    identity: TranscriptionPipelineIdentity = .init(),
    configuration: Configuration = .parakeet,
    defaultLanguage: @escaping @Sendable () async -> MeetingLanguage = {
      .defaultLanguage
    },
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil,
    logSink: @escaping @Sendable (String) -> Void = { message in
      Logger(subsystem: "org.localflow.LocalFlow", category: "transcript")
        .notice("\(message, privacy: .public)")
    }
  ) {
    self.store = store
    self.meetings = meetings
    self.storageRoot = storageRoot
    self.lifecycle = lifecycle
    self.vocabulary = vocabulary
    self.identity = identity
    self.configuration = configuration
    self.defaultLanguage = defaultLanguage
    self.clock = clock
    self.recorder = recorder
    self.logSink = logSink
  }

  // MARK: Work list

  /// Stretch sequences in order, from every track's segment rows.
  static func stretchCount(detail: MeetingDetail) -> Int { sequences(detail).count }

  static func workItems(detail: MeetingDetail, page: Int) -> [FinalizationWorkItem] {
    let all = sequences(detail)
    let start = page * workListPage
    guard start < all.count else { return [] }
    var base: Int64 = 0
    var items: [FinalizationWorkItem] = []
    for (index, sequence) in all.enumerated() {
      var tracks: [FinalizationWorkItem.Track] = []
      var longest: Int64 = 0
      for track in detail.tracks {
        guard let segment = track.segments.first(where: { $0.sequence == sequence }) else {
          continue
        }
        longest = max(longest, segment.durationMs)
        guard segment.state == .finalized else { continue }
        tracks.append(
          .init(
            kind: track.track.kind, relativePath: segment.relativePath,
            durationMs: segment.durationMs))
      }
      if index >= start, index < start + workListPage {
        items.append(.init(sequence: sequence, tracks: tracks, baseMs: base))
      }
      base += longest
    }
    return items
  }

  private static func sequences(_ detail: MeetingDetail) -> [Int] {
    Set(detail.tracks.flatMap { $0.segments.map(\.sequence) }).sorted()
  }

  private static func totalMs(_ detail: MeetingDetail) -> Int64 {
    var total: Int64 = 0
    for sequence in sequences(detail) {
      total +=
        detail.tracks.compactMap { track in
          track.segments.first { $0.sequence == sequence }?.durationMs
        }.max() ?? 0
    }
    return total
  }

  private func hasSourceAudio(_ detail: MeetingDetail) -> Bool {
    detail.tracks.contains { track in
      track.segments.contains { segment in
        segment.state == .finalized
          && storageRoot.resolve(relativePath: segment.relativePath).map {
            FileManager.default.fileExists(atPath: $0.path)
          } == true
      }
    }
  }

  // MARK: Failure mapping

  /// Category and content-free detail for an error raised inside the pass.
  static func category(for error: Swift.Error) -> (TranscriptFailureCategory, String?) {
    if let failure = error as? PassFailure { return (failure.category, failure.detail) }
    if let storeError = error as? TranscriptStore.Error {
      if case .capacityExceeded = storeError { return (.persistenceCapacity, nil) }
      return (.persistenceFailure, nil)
    }
    if error is AnalysisStreamMixer.Failure { return (.analysisStreamFailure, nil) }
    return (.runtimeFailure, nil)
  }

  private struct PassFailure: Swift.Error {
    let category: TranscriptFailureCategory
    let detail: String?
  }

  // MARK: Run

  private struct Admission {
    let passID: UUID
    let resume: FinalizationProgress?
    let row: MeetingTranscription
  }

  func run(
    meetingID: UUID, revision: Int64, progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> Outcome {
    guard let detail = try await meetings.detail(id: meetingID) else { throw Error.noSourceAudio }
    guard detail.meeting.state.isTerminal else { throw Error.meetingActive }
    guard hasSourceAudio(detail) else { throw Error.noSourceAudio }
    var snapshot: VocabularySnapshot?
    do { snapshot = try await vocabulary.snapshot() } catch is CancellationError {
      throw CancellationError()
    } catch {
      snapshot = nil
    }
    var language = MeetingLanguage.defaultLanguage
    if configuration.layout == .perTrack {
      if let chosen = detail.meeting.language {
        language = chosen
      } else {
        language = await defaultLanguage()
      }
    }
    var replacementLease: ModelLease?
    if let existing = try await store.transcription(meetingID: meetingID), existing.state == .final
    {
      guard existing.revision == revision else { throw Error.staleRevision }
      guard snapshot != nil else {
        throw Error.failed(.runtimeFailure, detail: "vocabulary_unavailable")
      }
      do {
        replacementLease = try await lifecycle.acquire(
          session: meetingID, workload: configuration.workload, meetingLanguage: language)
      } catch is CancellationError {
        throw CancellationError()
      } catch DictationFailure.cancelled {
        throw CancellationError()
      } catch {
        throw Error.failed(.acquisition(error), detail: nil)
      }
    }
    let admission: Admission
    do {
      try Task.checkCancellation()
      admission = try await admit(
        meetingID: meetingID, revision: revision, detail: detail, snapshot: snapshot,
        language: language)
    } catch {
      if let replacementLease { try? await lifecycle.finish(replacementLease) }
      throw error
    }
    publishTransition(admission.row)
    guard let snapshot else {
      throw await fail(meetingID, .runtimeFailure, detail: "vocabulary_unavailable", lease: nil)
    }
    let stretchCount = Self.stretchCount(detail: detail)
    guard stretchCount <= Self.workListCapacity else {
      throw await fail(
        meetingID, .finalizationInterrupted, detail: "work_list_capacity", lease: replacementLease)
    }
    let lease: ModelLease
    do {
      if let replacementLease {
        lease = replacementLease
      } else {
        lease = try await lifecycle.acquire(
          session: meetingID, workload: configuration.workload, meetingLanguage: language)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch DictationFailure.cancelled {
      throw CancellationError()
    } catch {
      throw await fail(meetingID, .acquisition(error), detail: nil, lease: nil)
    }
    // Only the lease holder gets here, so one pass owns `windows` at a time. The lanes
    // allocate their windows on first use and the pass releases them when it ends.
    defer { windows = [:] }
    var context = PassContext(
      meetingID: meetingID, passID: admission.passID, lease: lease,
      segmenter: TranscriptSegmenter(vocabulary: snapshot), resume: admission.resume,
      totalMs: Self.totalMs(detail), progress: progress, startedAt: clock.monotonicNanoseconds,
      descriptor: .init(source: .decodedTracks, layout: configuration.layout),
      pipelineVersion: pipelineVersion(language: language))
    context.lastFlush = context.startedAt
    do {
      context.ordinal =
        admission.resume == nil
        ? 0 : try await store.passSegmentCount(meetingID: meetingID, passID: admission.passID)
      let pages = (stretchCount + Self.workListPage - 1) / Self.workListPage
      if configuration.layout == .perTrack {
        try await profileEcho(detail: detail, pages: pages, context: &context)
      }
      for page in 0..<pages {
        for item in Self.workItems(detail: detail, page: page) {
          try Task.checkCancellation()
          try await processStretch(item, context: &context)
        }
      }
      try await flush(&context, force: true)
      return try await complete(&context)
    } catch is CancellationError {
      // Stop at the boundary: rows and progress stay for a later resume.
      try? await flush(&context, force: true)
      try? await lifecycle.finish(lease)
      throw CancellationError()
    } catch DictationFailure.cancelled {
      try? await flush(&context, force: true)
      try? await lifecycle.finish(lease)
      throw CancellationError()
    } catch {
      let (category, detail) = Self.category(for: error)
      throw await fail(meetingID, category, detail: detail, lease: lease)
    }
  }

  private func admit(
    meetingID: UUID, revision: Int64, detail: MeetingDetail, snapshot: VocabularySnapshot?,
    language: MeetingLanguage
  ) async throws -> Admission {
    let pipelineVersion = pipelineVersion(language: language)
    guard let row = try await store.transcription(meetingID: meetingID) else {
      throw Error.noSourceAudio
    }
    guard row.revision == revision else { throw Error.staleRevision }
    let now = clock.nowMilliseconds
    func identityEffects(expected: Int64) -> [TranscriptTransitionEffect] {
      [
        .setIdentity(
          engine: provenance.engine, model: modelIdentity, pipeline: pipelineVersion,
          planner: configuration.geometry, vocabulary: snapshot ?? .empty),
        .setTimestamps(
          startedAt: row.startedAt ?? now, finalizationStartedAt: now,
          recordedMsAtPass: detail.meeting.recordedMs, expectedRevision: expected),
      ]
    }
    do {
      switch row.state {
      case .live:
        throw Error.meetingActive
      case .finalizing:
        if row.passKind == .final, let existing = row.passID, let snapshot,
          matches(row, snapshot: snapshot, pipelineVersion: pipelineVersion)
        {
          let resume = row.progressSequence.map {
            FinalizationProgress(sequence: $0, sample: row.progressSample ?? 0)
          }
          return Admission(passID: existing, resume: resume, row: row)
        }
        let passID = UUID()
        let admitted = try await store.restartFinalPass(
          meetingID: meetingID, passID: passID, now: now,
          effects: identityEffects(expected: revision))
        return Admission(passID: passID, resume: nil, row: admitted)
      case .notRequested:
        let pending = try await store.transition(
          meetingID: meetingID, to: .pending, now: now,
          effects: [.setTimestamps(expectedRevision: revision)])
        let passID = UUID()
        let admitted = try await store.transition(
          meetingID: meetingID, to: .finalizing, now: now,
          effects: [.setPass(id: passID, kind: .final)]
            + identityEffects(expected: pending.revision))
        return Admission(passID: passID, resume: nil, row: admitted)
      case .final, .pending, .failed, .interrupted:
        let passID = UUID()
        var admitted = try await store.transition(
          meetingID: meetingID, to: .finalizing, now: now,
          effects: [.setPass(id: passID, kind: .final)] + identityEffects(expected: revision))
        if row.state == .final, let previous = row.passID {
          // Re-transcribe replaces the final transcript; the old pass's rows go first.
          try await store.discardPass(meetingID: meetingID, passID: previous)
          admitted = try await store.transcription(meetingID: meetingID) ?? admitted
        }
        return Admission(passID: passID, resume: nil, row: admitted)
      }
    } catch let error as TranscriptStore.Error {
      switch error {
      case .staleRevision: throw Error.staleRevision
      case .invalidTransition: throw Error.meetingActive
      default: throw Error.failed(.persistenceFailure, detail: nil)
      }
    }
  }

  private func matches(
    _ row: MeetingTranscription, snapshot: VocabularySnapshot, pipelineVersion: String
  ) -> Bool {
    row.engine == provenance.engine && row.modelID == modelIdentity.id
      && row.modelRevision == modelIdentity.revision
      && row.modelManifestHash == modelIdentity.manifestHash
      && row.pipelineVersion == pipelineVersion
      && row.plannerVersion == configuration.geometry && row.vocabularyRevision == snapshot.revision
      && row.vocabularyHash == snapshot.hash
  }

  private var provenance: TranscriptionProvenance {
    identity.provenance(sampleCount: 0, recognition: 0, assembly: 0)
  }
  private var modelIdentity: TranscriptModelIdentity {
    let provenance = provenance
    return .init(
      id: provenance.modelID ?? "unrecorded", revision: provenance.modelRevision ?? "unrecorded",
      manifestHash: provenance.modelManifestHash ?? String(repeating: "0", count: 64))
  }
  private func pipelineVersion(language: MeetingLanguage) -> String {
    let front =
      configuration.layout == .perTrack
      ? [
        configuration.geometry, TrackLevelNormalizer.version, EchoGate.version,
        language.pipelineTag,
      ]
      : [configuration.geometry]
    let back = [
      TranscriptAssembler.version, TranscriptSegmenter.version, TranscriptNormalizer.version,
    ]
    return (front + back).joined(separator: "+")
  }

  private func fail(
    _ meetingID: UUID, _ category: TranscriptFailureCategory, detail: String?,
    lease: ModelLease?
  ) async -> Error {
    if let row = try? await store.transition(
      meetingID: meetingID, to: .failed, now: clock.nowMilliseconds,
      effects: [.setFailure(category: category, detail: detail)])
    {
      publishTransition(row)
    }
    if let lease { try? await lifecycle.finish(lease) }
    recorder?.record(
      phase: .transcriptFinalizing, metric: .transcriptFailure, itemCount: 1,
      meetingKey: category.rawValue)
    logSink(
      "finalization failed category=\(category.rawValue) detail=\(detail ?? "-")"
    )
    return Error.failed(category, detail: detail)
  }

  private func publishTransition(_ row: MeetingTranscription) {
    recorder?.record(
      phase: .transcriptFinalizing, metric: .transcriptTransition, itemCount: 1,
      meetingKey: row.state.rawValue)
  }

  // MARK: Pass state

  private struct PassContext {
    let meetingID: UUID
    let passID: UUID
    let lease: ModelLease
    let segmenter: TranscriptSegmenter
    let resume: FinalizationProgress?
    let totalMs: Int64
    let progress: (@Sendable (Double) -> Void)?
    let startedAt: UInt64
    var descriptor: AnalysisStreamDescriptor
    let pipelineVersion: String
    var ordinal = 0
    var baseMs: Int64 = 0
    var contributing: Set<AnalysisTracks> = []
    /// Drafts waiting for a batch, each tagged with the progress its window completes.
    var pending: [(draft: TranscriptSegmentDraft, progress: FinalizationProgress)] = []
    var completedProgress: FinalizationProgress?
    var persistedProgress: FinalizationProgress?
    var lastFlush: UInt64 = 0
    var windowCount = 0
    var recognitionNanoseconds: UInt64 = 0
    var audioSamples = 0
    /// Per track: frame energies per stretch once the echo pass ran; the profile
    /// stays whole so the outcome can hand it to diarization for reuse. nil when
    /// the layout never profiles echo.
    var echoProfile: EchoGate.Profile?
    var echo: EchoGate.Calibration?
    var echoMutedMs: Int64 = 0
    var coveredMs: Int64 { descriptor.stretches.reduce(0) { $0 + $1.lengthMs } }
  }

  /// One window buffer per lane for the whole pass, refilled in place: `.both` for the
  /// mixed layout, `.mic` and `.system` per track. Empty between passes.
  private var windows: [AnalysisTracks: [Float]] = [:]
  /// Samples held in window buffers right now. For tests.
  var residentWindowSamples: Int { windows.values.reduce(0) { $0 + $1.count } }

  /// One recognizer input stream of a stretch: the mixed stream, or one track.
  private struct Lane {
    let tag: AnalysisTracks
    var stretch: StretchState
    var assembler: MeetingWindowAssembler
    /// Echo-explained spans on the stretch timeline, microphone lane only.
    var echo: [Range<Int64>] = []
    var ended = false
  }

  /// Per track: each window's drafts per lane until every lane has passed it, so rows
  /// of both tracks interleave by time and ordinals stay chronological.
  private struct WindowMerge {
    struct Entry {
      var drafts: [TranscriptSegmentDraft]
      var endSample: Int
    }
    var entries: [Int: [AnalysisTracks: Entry]] = [:]
  }

  // MARK: Echo profile

  /// Decodes both tracks of every stretch into 100 ms frame energies and calibrates
  /// the echo gate, so the microphone lane can mute the remote voice that reached it
  /// through speakers. Decode failures here are the failures the windows would hit.
  private func profileEcho(detail: MeetingDetail, pages: Int, context: inout PassContext)
    async throws
  {
    let began = clock.monotonicNanoseconds
    var profile = EchoGate.Profile()
    pagesLoop: for page in 0..<pages {
      for item in Self.workItems(detail: detail, page: page) {
        try Task.checkCancellation()
        // Stretch-relative timeline: the lanes mute by sample offset inside the stretch.
        var stretch = EchoGate.Stretch(baseMs: 0, microphone: [], system: [])
        for track in item.tracks {
          guard let url = storageRoot.resolve(relativePath: track.relativePath),
            FileManager.default.fileExists(atPath: url.path)
          else { continue }
          var accumulator = EchoGate.FrameAccumulator()
          do {
            try await MeetingTrackDecoder.decode(url: url, kind: track.kind) { emissions in
              for emission in emissions { accumulator.append(emission.samples) }
            }
          } catch let failure as MeetingTrackDecoder.Failure {
            throw PassFailure(category: .audioDecodeFailure, detail: failure.detail)
          }
          let energies = accumulator.finish()
          if track.kind == .microphone {
            stretch.microphone = energies
          } else {
            stretch.system = energies
          }
        }
        profile.stretches[item.sequence] = stretch
        guard profile.frames <= EchoGate.frameCapacity else { break pagesLoop }
      }
    }
    let frames = profile.frames
    context.echo = EchoGate.calibrate(profile)
    context.echoProfile = profile
    if let gate = context.echo {
      logSink(
        "final pass echo gate on lag=\(gate.lagFrames * Int(EchoGate.frameMs))ms gain=\(String(format: "%.1f", gate.gainDB))dB corr=\(String(format: "%.2f", gate.correlation))"
      )
    } else {
      logSink("final pass echo gate off frames=\(frames)")
    }
    recorder?.record(
      phase: .transcriptFinalizing,
      durationNanoseconds: clock.monotonicNanoseconds &- began,
      metric: .transcriptEchoProfileDuration)
  }

  // MARK: Stretches

  private func processStretch(_ item: FinalizationWorkItem, context: inout PassContext)
    async throws
  {
    var readers: [MeetingTrackKind: AVAudioFile] = [:]
    for track in item.tracks {
      guard let url = storageRoot.resolve(relativePath: track.relativePath),
        FileManager.default.fileExists(atPath: url.path)
      else { continue }
      do {
        readers[track.kind] = try AVAudioFile(forReading: url)
      } catch {
        throw PassFailure(category: .audioDecodeFailure, detail: "open")
      }
    }
    guard !readers.isEmpty else {
      // Neither track has audio for this stretch: reported, never invented.
      context.descriptor.appendStretch(.init(sequence: item.sequence, lengthMs: 0, tracks: .both))
      return
    }
    var formats: [MeetingTrackKind: MeetingSourceFormat] = [:]
    var buffers: [MeetingTrackKind: AVAudioPCMBuffer] = [:]
    for (kind, reader) in readers {
      let format = reader.processingFormat
      formats[kind] = .init(sampleRate: format.sampleRate, channels: Int(format.channelCount))
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.decodeFrames)
      else { throw PassFailure(category: .analysisStreamFailure, detail: "buffer") }
      buffers[kind] = buffer
    }
    // Mixed: one mixer over both tracks. Per track: one single-track mixer each, so
    // nothing is summed and each lane keeps its own timeline.
    var mixers: [AnalysisTracks: AnalysisStreamMixer] = [:]
    var lanes: [AnalysisTracks: Lane] = [:]
    let echo =
      context.echo.flatMap { calibration in
        context.echoProfile?.stretches[item.sequence].map {
          EchoGate.echoRanges($0, calibration: calibration)
        }
      } ?? []
    switch configuration.layout {
    case .mixed:
      mixers[.both] = try AnalysisStreamMixer(decoding: formats)
      lanes[.both] = makeLane(.both, sequence: item.sequence, context: context)
    case .perTrack:
      for (kind, format) in formats {
        let tag = Self.tag(kind)
        mixers[tag] = try AnalysisStreamMixer(decoding: [kind: format])
        var lane = makeLane(tag, sequence: item.sequence, context: context)
        if kind == .microphone { lane.echo = echo }
        lanes[tag] = lane
      }
    }
    var merge = WindowMerge()
    var ended: Set<MeetingTrackKind> = []
    while ended.count < readers.count {
      for kind in [MeetingTrackKind.microphone, .system] {
        guard let reader = readers[kind], let buffer = buffers[kind], !ended.contains(kind) else {
          continue
        }
        let tag = configuration.layout == .mixed ? AnalysisTracks.both : Self.tag(kind)
        guard let mixer = mixers[tag] else { continue }
        buffer.frameLength = 0
        // ADTS files report their length; a read at the end throws instead of
        // returning zero frames, so the position decides when a track has ended.
        if reader.framePosition < reader.length {
          do {
            try reader.read(into: buffer, frameCount: Self.decodeFrames)
          } catch {
            throw PassFailure(category: .audioDecodeFailure, detail: "read")
          }
        }
        guard buffer.frameLength > 0 else {
          ended.insert(kind)
          mixer.markEnded(kind)
          if configuration.layout == .perTrack {
            // This lane is done: its tail window goes now, and merged windows follow.
            try await pump(
              try mixer.flush(), tag: tag, lanes: &lanes, merge: &merge, context: &context)
            if lanes[tag]!.stretch.fill > 0 {
              try await transcribeWindow(&lanes[tag]!, merge: &merge, context: &context)
            }
            lanes[tag]!.ended = true
            try await emitMerged(&merge, lanes: lanes, context: &context)
          }
          continue
        }
        var attempts = 0
        while try !mixer.append(buffer, kind: kind) {
          attempts += 1
          guard attempts <= 4 else {
            throw PassFailure(category: .analysisStreamFailure, detail: "staging")
          }
          try await pump(
            try mixer.tick(), tag: tag, lanes: &lanes, merge: &merge, context: &context)
        }
        try await pump(try mixer.tick(), tag: tag, lanes: &lanes, merge: &merge, context: &context)
      }
    }
    if configuration.layout == .mixed, let mixer = mixers[.both] {
      try await pump(try mixer.flush(), tag: .both, lanes: &lanes, merge: &merge, context: &context)
      if lanes[.both]!.stretch.fill > 0 {
        try await transcribeWindow(&lanes[.both]!, merge: &merge, context: &context)
      }
    }
    var tracks: Set<AnalysisTracks> = []
    for mixer in mixers.values { tracks.formUnion(mixer.descriptor.contributingTracks) }
    let lengthMs = Int64(lanes.values.map(\.stretch.position).max() ?? 0) * 1_000 / 16_000
    context.descriptor.appendStretch(
      .init(
        sequence: item.sequence, lengthMs: lengthMs,
        tracks: tracks.count > 1 ? .both : tracks.first ?? .mic))
    context.contributing.formUnion(tracks)
    context.baseMs += lengthMs
    // A stretch end always leaves progress behind, even when it produced no text.
    try await flush(&context, force: true)
  }

  /// Feeds one lane and, per track, releases the windows every lane has passed.
  private func pump(
    _ emissions: [AnalysisStreamMixer.Emission], tag: AnalysisTracks,
    lanes: inout [AnalysisTracks: Lane], merge: inout WindowMerge, context: inout PassContext
  ) async throws {
    try await feed(emissions, lane: &lanes[tag]!, merge: &merge, context: &context)
    if configuration.layout == .perTrack {
      try await emitMerged(&merge, lanes: lanes, context: &context)
    }
  }

  private static func tag(_ kind: MeetingTrackKind) -> AnalysisTracks {
    kind == .microphone ? .mic : .system
  }

  private func makeLane(_ tag: AnalysisTracks, sequence: Int, context: PassContext) -> Lane {
    if windows[tag] == nil {
      windows[tag] = [Float](repeating: 0, count: configuration.windowSamples)
    }
    return Lane(
      tag: tag, stretch: StretchState(sequence: sequence, resume: context.resume),
      assembler: MeetingWindowAssembler(
        geometry: configuration.geometry, maximumWindowSamples: configuration.windowSamples))
  }

  private struct StretchState {
    let sequence: Int
    let resume: FinalizationProgress?
    var position = 0
    var fill = 0
    var windowStart = 0
    var windowIndex = 0
    var tracks: Set<AnalysisTracks> = []
    var skip: (Int) -> Bool {
      guard let resume else { return { _ in false } }
      if sequence < resume.sequence { return { _ in true } }
      if sequence == resume.sequence { return { $0 < Int(resume.sample) } }
      return { _ in false }
    }
  }

  private func feed(
    _ emissions: [AnalysisStreamMixer.Emission], lane: inout Lane, merge: inout WindowMerge,
    context: inout PassContext
  ) async throws {
    for emission in emissions {
      var offset = 0
      while offset < emission.samples.count {
        let room = configuration.windowSamples - lane.stretch.fill
        let count = min(room, emission.samples.count - offset)
        let fill = lane.stretch.fill
        windows[lane.tag]!.withUnsafeMutableBufferPointer { target in
          emission.samples.withUnsafeBufferPointer { source in
            (target.baseAddress! + fill).update(from: source.baseAddress! + offset, count: count)
          }
        }
        lane.stretch.fill += count
        lane.stretch.position += count
        lane.stretch.tracks.insert(emission.tracks)
        offset += count
        if lane.stretch.fill == configuration.windowSamples {
          try await transcribeWindow(&lane, merge: &merge, context: &context)
        }
      }
    }
  }

  private func transcribeWindow(
    _ lane: inout Lane, merge: inout WindowMerge, context: inout PassContext
  ) async throws {
    let count = lane.stretch.fill
    let start = lane.stretch.windowStart
    let index = lane.stretch.windowIndex
    defer {
      lane.stretch.fill = 0
      lane.stretch.windowStart = start + count
      lane.stretch.windowIndex += 1
      lane.stretch.tracks = []
      if context.totalMs > 0 {
        let covered = context.baseMs + Int64(lane.stretch.position) * 1_000 / 16_000
        context.progress?(min(1, Double(covered) / Double(context.totalMs)))
      }
    }
    guard !lane.stretch.skip(start) else { return }
    try Task.checkCancellation()
    // A full window goes to the runtime as the lane's buffer itself, levelled in place
    // (it is refilled before it is read again): no copy per inference. Only a
    // stretch's shorter tail window is copied out.
    let whole = count == configuration.windowSamples
    var samples =
      whole ? windows.removeValue(forKey: lane.tag) ?? [] : Array(windows[lane.tag]!.prefix(count))
    defer { if whole { windows[lane.tag] = samples } }
    if configuration.layout == .perTrack {
      if lane.tag == .mic, !lane.echo.isEmpty {
        context.echoMutedMs += EchoGate.mute(
          &samples, startMs: Int64(start) * 1_000 / 16_000, echo: lane.echo)
      }
      TrackLevelNormalizer.normalize(&samples)
    }
    let began = clock.monotonicNanoseconds
    let result: TranscriptionWindow
    let lifecycle = lifecycle
    let lease = context.lease
    let session = context.meetingID
    do {
      // Deletion and shutdown revoke the session so an in-flight inference is
      // joined by the lifecycle rather than awaited here.
      result = try await withTaskCancellationHandler {
        try await lifecycle.transcribe(lease, samples: samples)
      } onCancel: {
        Task { await lifecycle.cancelSessionAndJoin(session) }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch DictationFailure.cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw PassFailure(category: .runtimeFailure, detail: nil)
    }
    context.recognitionNanoseconds &+= clock.monotonicNanoseconds &- began
    context.audioSamples += count
    let tracks: AnalysisTracks
    if lane.tag == .both {
      tracks = lane.stretch.tracks.count > 1 ? .both : lane.stretch.tracks.first ?? .both
    } else {
      tracks = lane.tag
    }
    let assembled = lane.assembler.append(
      window: .init(
        sequence: index, sampleStart: start, sampleCount: count,
        paddedSampleCount: max(4_800, count), text: result.text,
        tokens: TranscriptSourceMapper.map(text: result.text, words: result.tokens)))
    var drafts = context.segmenter.segments(
      window: assembled,
      base: .init(
        stretchSequence: lane.stretch.sequence, stretchBaseMs: context.baseMs, tracks: tracks,
        ordinal: lane.tag == .both ? context.ordinal : 0))
    let model = modelIdentity
    for index in drafts.indices {
      drafts[index].finality = .final
      drafts[index].engine = provenance.engine
      drafts[index].modelID = model.id
      drafts[index].modelRevision = model.revision
      drafts[index].pipelineVersion = context.pipelineVersion
    }
    context.windowCount += 1
    if lane.tag == .both {
      context.ordinal += drafts.count
      let progress = FinalizationProgress(
        sequence: lane.stretch.sequence, sample: Int64(start + count))
      context.pending += drafts.map { ($0, progress) }
      context.completedProgress = progress
      try await flush(&context, force: false)
    } else {
      merge.entries[index, default: [:]][lane.tag] = .init(drafts: drafts, endSample: start + count)
    }
  }

  /// Emits every merged window all lanes have passed, in window order. A window's
  /// progress is the furthest lane's end, so a resume skips it on both tracks.
  private func emitMerged(
    _ merge: inout WindowMerge, lanes: [AnalysisTracks: Lane], context: inout PassContext
  ) async throws {
    for index in merge.entries.keys.sorted() {
      let passed = lanes.values.allSatisfy { $0.ended || $0.stretch.windowIndex > index }
      guard passed, let entries = merge.entries.removeValue(forKey: index) else { return }
      let sequence = lanes.values.first?.stretch.sequence ?? 0
      var drafts = entries.values.flatMap(\.drafts)
      drafts.sort {
        if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
        if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
        return $0.analysisTracks == .mic && $1.analysisTracks != .mic
      }
      for offset in drafts.indices { drafts[offset].ordinal = context.ordinal + offset }
      context.ordinal += drafts.count
      let progress = FinalizationProgress(
        sequence: sequence, sample: Int64(entries.values.map(\.endSample).max() ?? 0))
      context.pending += drafts.map { ($0, progress) }
      context.completedProgress = progress
      try await flush(&context, force: false)
    }
  }

  /// Batches of ≤ 50 drafts, or 2 s of clock time, one transaction each; progress
  /// names the last window whose drafts are all inside the batch.
  private func flush(_ context: inout PassContext, force: Bool) async throws {
    let elapsed = clock.monotonicNanoseconds &- context.lastFlush
    let due =
      context.pending.count >= Self.batchCapacity || elapsed >= Self.batchIntervalNanoseconds
    guard force || due else { return }
    repeat {
      let chunk = Array(context.pending.prefix(Self.batchCapacity))
      let rest = context.pending.dropFirst(chunk.count)
      var progress: FinalizationProgress?
      if let last = chunk.last?.progress, rest.first?.progress != last {
        progress = last
      } else if chunk.count >= 2 {
        for index in stride(from: chunk.count - 2, through: 0, by: -1)
        where chunk[index].progress != chunk[index + 1].progress {
          progress = chunk[index].progress
          break
        }
      }
      if chunk.isEmpty {
        // Silence still advances the resume point.
        guard let completed = context.completedProgress, completed != context.persistedProgress
        else { break }
        progress = completed
      }
      try await persist(chunk.map(\.draft), progress: progress, context: &context)
      context.pending.removeFirst(chunk.count)
      if let progress { context.persistedProgress = progress }
    } while context.pending.count >= Self.batchCapacity || (force && !context.pending.isEmpty)
  }

  private func persist(
    _ drafts: [TranscriptSegmentDraft], progress: FinalizationProgress?,
    context: inout PassContext
  ) async throws {
    var attempt = 0
    while true {
      attempt += 1
      let began = clock.monotonicNanoseconds
      do {
        _ = try await store.appendSegments(
          meetingID: context.meetingID, passID: context.passID, drafts: drafts,
          progress: progress, now: clock.nowMilliseconds)
        context.lastFlush = clock.monotonicNanoseconds
        recorder?.record(
          phase: .transcriptFinalizing, durationNanoseconds: clock.monotonicNanoseconds &- began,
          metric: .transcriptPersistenceBatchDuration)
        if !drafts.isEmpty {
          recorder?.record(
            phase: .transcriptFinalizing, metric: .transcriptSegmentsFinal,
            itemCount: UInt32(clamping: drafts.count))
        }
        return
      } catch let error as TranscriptStore.Error {
        if case .capacityExceeded = error {
          throw PassFailure(
            category: .persistenceCapacity,
            detail: "kept_\(context.ordinal - context.pending.count)")
        }
        if attempt >= Self.persistenceAttempts {
          throw PassFailure(category: .persistenceFailure, detail: nil)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if attempt >= Self.persistenceAttempts {
          throw PassFailure(category: .persistenceFailure, detail: nil)
        }
      }
      await Task.yield()
    }
  }

  private func complete(_ context: inout PassContext) async throws -> Outcome {
    let gaps = try await store.gaps(meetingID: context.meetingID)
    var bases: [Int: (base: Int64, length: Int64)] = [:]
    var base: Int64 = 0
    for stretch in context.descriptor.stretches {
      bases[stretch.sequence] = (base, stretch.lengthMs)
      base += stretch.lengthMs
    }
    var coveredCount = 0
    var coveredMs: Int64 = 0
    for gap in gaps {
      let covered =
        bases[gap.stretchSequence].map { entry in
          entry.length > 0 && gap.startMs >= entry.base && gap.endMs <= entry.base + entry.length
        } ?? false
      if covered {
        coveredCount += 1
        coveredMs += gap.endMs - gap.startMs
      }
      recorder?.record(
        phase: .transcriptFinalizing, metric: .transcriptLiveGapMs,
        itemCount: UInt32(clamping: gap.endMs - gap.startMs), meetingKey: gap.reason.rawValue)
    }
    var descriptor = context.descriptor
    descriptor.contributingTracks = [AnalysisTracks.mic, .system].filter {
      context.contributing.contains($0) || context.contributing.contains(.both)
    }
    let row = try await store.completeFinalPass(
      meetingID: context.meetingID, passID: context.passID, descriptor: descriptor,
      coveredMs: context.coveredMs, now: clock.nowMilliseconds)
    try? await lifecycle.finish(context.lease)
    publishTransition(row)
    let elapsed = clock.monotonicNanoseconds &- context.startedAt
    recorder?.record(
      phase: .transcriptFinalizing, durationNanoseconds: elapsed,
      metric: .transcriptFinalizationDuration)
    if context.audioSamples > 0 {
      let perSecond = Double(context.recognitionNanoseconds) * 16_000 / Double(context.audioSamples)
      recorder?.record(
        phase: .transcriptFinalizing, durationNanoseconds: UInt64(perSecond.rounded()),
        metric: .transcriptRealTimeFactor)
    }
    let windows = context.windowCount
    logSink(
      "finalization complete windows=\(windows) segments=\(row.segmentCount) replaced=\(row.replacedProvisionalCount) gaps=\(gaps.count) covered=\(coveredCount) coveredMs=\(coveredMs) echoMutedMs=\(context.echoMutedMs)"
    )
    return Outcome(
      row: row, windowCount: context.windowCount, totalGapCount: gaps.count,
      coveredGapCount: coveredCount, coveredGapMs: coveredMs,
      echoProfile: context.echoProfile)
  }
}
