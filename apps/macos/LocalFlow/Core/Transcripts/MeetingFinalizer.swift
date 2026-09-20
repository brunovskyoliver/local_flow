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
  }
  struct Configuration: Sendable {
    let windowSamples: Int
    let geometry: String
    let workload: ModelWorkload

    private init(windowSamples: Int, geometry: String, workload: ModelWorkload) {
      self.windowSamples = windowSamples
      self.geometry = geometry
      self.workload = workload
    }

    static let parakeet = Configuration(
      windowSamples: 239_360, geometry: "contiguous_fixed239360_preserve_v1",
      workload: .speechRecognition)
    static let turbo = Configuration(
      windowSamples: 1_920_000, geometry: "contiguous_fixed1920000_turbo_preserve_v1",
      workload: .meetingTranscription)
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
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let logSink: @Sendable (String) -> Void

  init(
    store: any TranscriptStoring, meetings: any MeetingStoring, storageRoot: MeetingStorageRoot,
    lifecycle: ModelLifecycleCoordinator,
    vocabulary: any VocabularyProviding = EmptyVocabularyProvider(),
    identity: TranscriptionPipelineIdentity = .init(),
    configuration: Configuration = .parakeet,
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
    self.window = [Float](repeating: 0, count: configuration.windowSamples)
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
    var replacementLease: ModelLease?
    if let existing = try await store.transcription(meetingID: meetingID), existing.state == .final
    {
      guard existing.revision == revision else { throw Error.staleRevision }
      guard snapshot != nil else {
        throw Error.failed(.runtimeFailure, detail: "vocabulary_unavailable")
      }
      do {
        replacementLease = try await lifecycle.acquire(
          session: meetingID, workload: configuration.workload)
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
        meetingID: meetingID, revision: revision, detail: detail, snapshot: snapshot)
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
        lease = try await lifecycle.acquire(session: meetingID, workload: configuration.workload)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch DictationFailure.cancelled {
      throw CancellationError()
    } catch {
      throw await fail(meetingID, .acquisition(error), detail: nil, lease: nil)
    }
    var context = PassContext(
      meetingID: meetingID, passID: admission.passID, lease: lease,
      segmenter: TranscriptSegmenter(vocabulary: snapshot), resume: admission.resume,
      totalMs: Self.totalMs(detail), progress: progress, startedAt: clock.monotonicNanoseconds)
    context.lastFlush = context.startedAt
    do {
      context.ordinal =
        admission.resume == nil
        ? 0 : try await store.passSegmentCount(meetingID: meetingID, passID: admission.passID)
      let pages = (stretchCount + Self.workListPage - 1) / Self.workListPage
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
    meetingID: UUID, revision: Int64, detail: MeetingDetail, snapshot: VocabularySnapshot?
  ) async throws -> Admission {
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
          matches(row, snapshot: snapshot)
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

  private func matches(_ row: MeetingTranscription, snapshot: VocabularySnapshot) -> Bool {
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
  private var pipelineVersion: String {
    [
      configuration.geometry, TranscriptAssembler.version, TranscriptSegmenter.version,
      TranscriptNormalizer.version,
    ].joined(separator: "+")
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
    var ordinal = 0
    var baseMs: Int64 = 0
    var descriptor = AnalysisStreamDescriptor(source: .decodedTracks)
    var contributing: Set<AnalysisTracks> = []
    /// Drafts waiting for a batch, each tagged with the progress its window completes.
    var pending: [(draft: TranscriptSegmentDraft, progress: FinalizationProgress)] = []
    var completedProgress: FinalizationProgress?
    var persistedProgress: FinalizationProgress?
    var lastFlush: UInt64 = 0
    var windowCount = 0
    var recognitionNanoseconds: UInt64 = 0
    var audioSamples = 0
    var coveredMs: Int64 { descriptor.stretches.reduce(0) { $0 + $1.lengthMs } }
  }

  /// One window buffer for the whole pass; refilled in place.
  private var window: [Float]

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
    let mixer = try AnalysisStreamMixer(decoding: formats)
    var stretch = StretchState(sequence: item.sequence, resume: context.resume)
    var assembler = MeetingWindowAssembler(
      geometry: configuration.geometry, maximumWindowSamples: configuration.windowSamples)
    var ended: Set<MeetingTrackKind> = []
    while ended.count < readers.count {
      for kind in [MeetingTrackKind.microphone, .system] {
        guard let reader = readers[kind], let buffer = buffers[kind], !ended.contains(kind) else {
          continue
        }
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
          continue
        }
        var attempts = 0
        while try !mixer.append(buffer, kind: kind) {
          attempts += 1
          guard attempts <= 4 else {
            throw PassFailure(category: .analysisStreamFailure, detail: "staging")
          }
          try await feed(
            try mixer.tick(), stretch: &stretch, assembler: &assembler, context: &context)
        }
      }
      try await feed(try mixer.tick(), stretch: &stretch, assembler: &assembler, context: &context)
    }
    try await feed(try mixer.flush(), stretch: &stretch, assembler: &assembler, context: &context)
    if stretch.fill > 0 {
      try await transcribeWindow(&stretch, assembler: &assembler, context: &context)
    }
    let tracks = mixer.descriptor.contributingTracks
    let lengthMs = Int64(stretch.position) * 1_000 / 16_000
    context.descriptor.appendStretch(
      .init(
        sequence: item.sequence, lengthMs: lengthMs,
        tracks: tracks.count > 1 ? .both : tracks.first ?? .mic))
    context.contributing.formUnion(tracks)
    context.baseMs += lengthMs
    // A stretch end always leaves progress behind, even when it produced no text.
    try await flush(&context, force: true)
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
    _ emissions: [AnalysisStreamMixer.Emission], stretch: inout StretchState,
    assembler: inout MeetingWindowAssembler, context: inout PassContext
  ) async throws {
    for emission in emissions {
      var offset = 0
      while offset < emission.samples.count {
        let room = configuration.windowSamples - stretch.fill
        let count = min(room, emission.samples.count - offset)
        window.withUnsafeMutableBufferPointer { target in
          emission.samples.withUnsafeBufferPointer { source in
            for index in 0..<count { target[stretch.fill + index] = source[offset + index] }
          }
        }
        stretch.fill += count
        stretch.position += count
        stretch.tracks.insert(emission.tracks)
        offset += count
        if stretch.fill == configuration.windowSamples {
          try await transcribeWindow(&stretch, assembler: &assembler, context: &context)
        }
      }
    }
  }

  private func transcribeWindow(
    _ stretch: inout StretchState, assembler: inout MeetingWindowAssembler,
    context: inout PassContext
  ) async throws {
    let count = stretch.fill
    let start = stretch.windowStart
    defer {
      stretch.fill = 0
      stretch.windowStart = start + count
      stretch.windowIndex += 1
      stretch.tracks = []
      if context.totalMs > 0 {
        let covered = context.baseMs + Int64(stretch.position) * 1_000 / 16_000
        context.progress?(min(1, Double(covered) / Double(context.totalMs)))
      }
    }
    guard !stretch.skip(start) else { return }
    try Task.checkCancellation()
    let samples = count == window.count ? window : Array(window.prefix(count))
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
    let tracks: AnalysisTracks =
      stretch.tracks.count > 1 ? .both : stretch.tracks.first ?? .both
    let assembled = assembler.append(
      window: .init(
        sequence: stretch.windowIndex, sampleStart: start, sampleCount: count,
        paddedSampleCount: max(4_800, count), text: result.text,
        tokens: TranscriptSourceMapper.map(text: result.text, words: result.tokens)))
    var drafts = context.segmenter.segments(
      window: assembled,
      base: .init(
        stretchSequence: stretch.sequence, stretchBaseMs: context.baseMs, tracks: tracks,
        ordinal: context.ordinal))
    let model = modelIdentity
    for index in drafts.indices {
      drafts[index].finality = .final
      drafts[index].engine = provenance.engine
      drafts[index].modelID = model.id
      drafts[index].modelRevision = model.revision
      drafts[index].pipelineVersion = pipelineVersion
    }
    context.ordinal += drafts.count
    let progress = FinalizationProgress(sequence: stretch.sequence, sample: Int64(start + count))
    context.pending += drafts.map { ($0, progress) }
    context.completedProgress = progress
    context.windowCount += 1
    try await flush(&context, force: false)
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
      "finalization complete windows=\(windows) segments=\(row.segmentCount) replaced=\(row.replacedProvisionalCount) gaps=\(gaps.count) covered=\(coveredCount) coveredMs=\(coveredMs)"
    )
    return Outcome(
      row: row, windowCount: context.windowCount, totalGapCount: gaps.count,
      coveredGapCount: coveredCount, coveredGapMs: coveredMs)
  }
}
