import AVFoundation
import Foundation

@testable import LocalFlow

actor FakeTranscriptionRuntime: TranscriptionRuntime {
  var windows: [TranscriptionWindow]
  var failureOnCall: Int?
  var delay: Duration
  let clock: any DictationClock
  private(set) var sampleCounts: [Int] = []
  /// The newest windows as received, bounded so a long fake run stays small.
  private(set) var received: [[Float]] = []
  static let retainedWindows = 64
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var shutdownCount = 0
  private(set) var cancellationCount = 0

  init(
    windows: [TranscriptionWindow] = [.init(text: " hello , world ", tokens: [])],
    failureOnCall: Int? = nil, delay: Duration = .zero,
    clock: any DictationClock = SystemDictationClock()
  ) {
    self.windows = windows
    self.failureOnCall = failureOnCall
    self.delay = delay
    self.clock = clock
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    sampleCounts.append(samples.count)
    received.append(samples)
    if received.count > Self.retainedWindows { received.removeFirst() }
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    do {
      if delay > .zero { try await clock.sleep(for: delay) }
      try Task.checkCancellation()
    } catch {
      cancellationCount += 1
      throw error
    }
    if sampleCounts.count == failureOnCall { throw DictationFailure.invalidResult }
    return windows.isEmpty
      ? .init(text: "", tokens: []) : windows[min(sampleCounts.count - 1, windows.count - 1)]
  }

  func shutdown() { shutdownCount += 1 }
  func setDelay(_ value: Duration) { delay = value }
}

struct FakeAnalysisTap {
  let tap: MeetingAnalysisTap
  let format: AVAudioFormat

  init(kind: MeetingTrackKind = .microphone, sampleRate: Double = 48_000) throws {
    let source = MeetingSourceFormat(sampleRate: sampleRate, channels: 1)
    tap = try MeetingAnalysisTap(kind: kind, format: source)
    format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  }

  func push(frames: Int = 4_096, value: Float = 0.25) {
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    block.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { block.floatChannelData![0][index] = value }
    tap.push(block)
  }
}

actor FakeTranscriptStore: TranscriptStoring {
  private(set) var rows: [UUID: MeetingTranscription] = [:]
  private(set) var segments: [TranscriptSegment] = []
  private(set) var liveGaps: [LiveGap] = []
  private(set) var batchSizes: [Int] = []
  var failuresRemaining = 0
  private var batchGate: TranscriptBatchGate?
  func holdNextBatch(_ gate: TranscriptBatchGate) { batchGate = gate }
  private var transitionGate: TranscriptBatchGate?
  func holdNextTransition(_ gate: TranscriptBatchGate) { transitionGate = gate }
  private(set) var calls: [String] = []
  private var segmentCapacity = 20_000
  func setSegmentCapacity(_ value: Int) { segmentCapacity = value }
  private func log(_ call: String) { if calls.count < 10_000 { calls.append(call) } }

  func seed(_ id: UUID, requested: Bool = true, now: Int64 = 0) {
    rows[id] = MeetingTranscription(
      meetingID: id, state: requested ? .pending : .notRequested,
      liveRequested: requested, updatedAt: now)
  }
  func failBatches(_ count: Int) { failuresRemaining = count }
  func transcription(meetingID: UUID) -> MeetingTranscription? { rows[meetingID] }
  func transition(
    meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription {
    log("transition:" + to.rawValue)
    if let gate = transitionGate {
      transitionGate = nil
      await gate.wait()
    }
    guard var row = rows[meetingID] else { throw TranscriptStore.Error.missingRow }
    try TranscriptLifecycle.transition(from: row.state, to: to)
    row.state = to
    row.updatedAt = now
    row.revision += 1
    if to != .live { row.liveState = nil }
    for effect in effects {
      switch effect {
      case .setIdentity(let engine, let model, let pipeline, let planner, let vocabulary):
        row.engine = engine
        row.modelID = model.id
        row.modelRevision = model.revision
        row.modelManifestHash = model.manifestHash
        row.pipelineVersion = pipeline
        row.plannerVersion = planner
        row.vocabularyRevision = vocabulary.revision
        row.vocabularyHash = vocabulary.hash
      case .setPass(let id, let kind):
        if row.passID != id {
          row.progressSequence = nil
          row.progressSample = nil
        }
        row.passID = id
        row.passKind = kind
      case .setDescriptor(let descriptor): row.analysisDescriptor = descriptor
      case .setFailure(let category, let detail):
        row.failureCategory = category
        row.failureDetail = detail
      case .clearFailure:
        row.failureCategory = nil
        row.failureDetail = nil
      case .setProgress(let progress):
        row.progressSequence = progress.sequence
        row.progressSample = progress.sample
      case .incrementModelReloads: row.modelReloadCount += 1
      case .setTimestamps(let started, let live, let finalizing, let final, let recorded, _):
        row.startedAt = started ?? row.startedAt
        row.liveStartedAt = live ?? row.liveStartedAt
        row.finalizationStartedAt = finalizing ?? row.finalizationStartedAt
        row.finalizedAt = final ?? row.finalizedAt
        row.recordedMsAtPass = recorded ?? row.recordedMsAtPass
      }
    }
    rows[meetingID] = row
    return row
  }
  func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) {
    log("liveState:" + (liveState?.rawValue ?? "nil"))
    rows[meetingID]?.liveState = liveState
    rows[meetingID]?.revision += 1
  }
  func updateLiveMetadata(
    meetingID: UUID, descriptor: AnalysisStreamDescriptor,
    incrementModelReloads: Bool, now: Int64
  ) throws -> MeetingTranscription {
    guard var row = rows[meetingID], row.state == .live else {
      throw TranscriptStore.Error.missingRow
    }
    row.analysisDescriptor = descriptor
    if incrementModelReloads { row.modelReloadCount += 1 }
    row.updatedAt = now
    row.revision += 1
    rows[meetingID] = row
    return row
  }
  func appendSegments(
    meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft],
    progress: FinalizationProgress?, now: Int64
  ) async throws -> Int {
    log("appendSegments")
    if let gate = batchGate {
      batchGate = nil
      await gate.wait()
    }
    guard let row = rows[meetingID], row.passID == passID,
      row.state == .live || row.state == .finalizing
    else { throw TranscriptStore.Error.passMismatch }
    guard segments.count + drafts.count <= segmentCapacity else {
      throw TranscriptStore.Error.capacityExceeded(.meetingSegments)
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw DictationFailure.invalidResult
    }
    guard drafts.count <= 50 else { throw DictationFailure.invalidResult }
    batchSizes.append(drafts.count)
    segments += drafts.map {
      TranscriptSegment(id: UUID(), meetingID: meetingID, passID: passID, draft: $0, createdAt: now)
    }
    rows[meetingID]?.segmentCount += drafts.count
    if let progress {
      rows[meetingID]?.progressSequence = progress.sequence
      rows[meetingID]?.progressSample = progress.sample
    }
    rows[meetingID]?.revision += 1
    return drafts.count
  }
  func appendGap(_ gap: LiveGap) {
    if let last = liveGaps.last, last.meetingID == gap.meetingID,
      last.passID == gap.passID, last.stretchSequence == gap.stretchSequence,
      last.reason == gap.reason, last.endMs == gap.startMs
    {
      liveGaps[liveGaps.count - 1] = .init(
        id: last.id, meetingID: last.meetingID,
        passID: last.passID, stretchSequence: last.stretchSequence,
        startMs: last.startMs, endMs: gap.endMs, reason: last.reason, createdAt: last.createdAt)
    } else {
      liveGaps.append(gap)
    }
  }
  func completeFinalPass(
    meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64,
    now: Int64
  ) async throws -> MeetingTranscription {
    guard rows[meetingID]?.passID == passID, rows[meetingID]?.passKind == .final else {
      throw TranscriptStore.Error.passMismatch
    }
    let replaced = segments.filter { $0.meetingID == meetingID && $0.finality == .provisional }
    segments.removeAll { $0.meetingID == meetingID && $0.passID != passID }
    for index in liveGaps.indices where liveGaps[index].meetingID == meetingID {
      liveGaps[index].coveredByFinal = liveGaps[index].endMs <= coveredMs
    }
    liveGaps.removeAll { $0.meetingID == meetingID }
    var row = try await transition(
      meetingID: meetingID, to: .final, now: now, effects: [.setDescriptor(descriptor)])
    row.replacedProvisionalCount = replaced.count
    row.coveredMs = coveredMs
    row.finalizedAt = now
    row.segmentCount = segments.filter { $0.meetingID == meetingID }.count
    rows[meetingID] = row
    return row
  }
  func restartFinalPass(
    meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription {
    log("restartFinalPass")
    guard var row = rows[meetingID], row.state == .finalizing else {
      throw TranscriptStore.Error.passMismatch
    }
    segments.removeAll { $0.meetingID == meetingID && $0.finality == .final }
    row.state = .interrupted
    rows[meetingID] = row
    row = try await transition(
      meetingID: meetingID, to: .finalizing, now: now,
      effects: [.setPass(id: passID, kind: .final)] + effects)
    row.progressSequence = nil
    row.progressSample = nil
    row.segmentCount = segments.filter { $0.meetingID == meetingID }.count
    rows[meetingID] = row
    return row
  }
  func passSegmentCount(meetingID: UUID, passID: UUID) -> Int {
    segments.filter { $0.meetingID == meetingID && $0.passID == passID }.count
  }
  func discardPass(meetingID: UUID, passID: UUID) {
    segments.removeAll { $0.passID == passID }
    rows[meetingID]?.segmentCount = segments.filter { $0.meetingID == meetingID }.count
  }
  func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    -> [TranscriptSegment]
  {
    log("page")
    return Array(
      segments.filter {
        $0.meetingID == meetingID && $0.finality == finality && $0.ordinal > (ordinal ?? -1)
      }.sorted { $0.ordinal < $1.ordinal }.prefix(min(200, limit)))
  }
  /// Seeds committed rows directly for paging tests; counts follow the row.
  func seedSegments(_ meetingID: UUID, passID: UUID, finality: SegmentFinality, count: Int) {
    for ordinal in 0..<count {
      let draft = TranscriptSegmentDraft(
        finality: finality, ordinal: ordinal, stretchSequence: 1, startMs: Int64(ordinal) * 1_000,
        endMs: Int64(ordinal) * 1_000 + 900, coveredMs: Int64(count) * 1_000, windowIndex: 0,
        timingBasis: .word, rawText: "seg \(ordinal)", assembledText: "seg \(ordinal)",
        normalizedText: "Seg \(ordinal)", analysisTracks: .both)
      segments.append(
        TranscriptSegment(
          id: UUID(), meetingID: meetingID, passID: passID, draft: draft, createdAt: 0)
      )
    }
    rows[meetingID]?.segmentCount = segments.filter { $0.meetingID == meetingID }.count
  }
  func setRow(_ row: MeetingTranscription) { rows[row.meetingID] = row }
  func gaps(meetingID: UUID) -> [LiveGap] { liveGaps.filter { $0.meetingID == meetingID } }
  func activeRows(limit: Int) -> [MeetingTranscription] { Array(rows.values.prefix(limit)) }
  func recordOutcome(_ outcome: RecoveryOutcome) {}
  func usage() -> TranscriptUsage {
    .init(
      textBytes: Int64(segments.reduce(0) { $0 + $1.draft.textBytes }), segmentRows: segments.count)
  }
}

/// Small, real AAC files for decode tests. The caller owns and removes the directory.
struct TranscriptAudioFixture {
  let directory: URL
  let stretches: [[MeetingTrackKind: URL]]

  static func make(stretchCount: Int = 2, blocksPerTrack: Int = 4) throws -> Self {
    precondition((1...20).contains(stretchCount) && (1...32).contains(blocksPerTrack))
    let directory = try makeMeetingTestRoot()
    do {
      var stretches: [[MeetingTrackKind: URL]] = []
      for sequence in 1...stretchCount {
        var tracks: [MeetingTrackKind: URL] = [:]
        for kind in MeetingTrackKind.allCases {
          let url = directory.appendingPathComponent("\(kind.rawValue)-\(sequence).aac")
          try ADTSFixtures.write(
            ADTSFixtures.encodedTone(blocks: blocksPerTrack, kind: kind), to: url)
          tracks[kind] = url
        }
        stretches.append(tracks)
      }
      return Self(directory: directory, stretches: stretches)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

actor TranscriptBatchGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    continuation?.resume()
    continuation = nil
  }
}

extension FakeMeetingClock: DictationClock {}

/// A completed Feature 004 meeting in a real store with encoded tone files per stretch,
/// for finalization tests. `.missing` writes no segment; `.unrecoverable` writes a
/// segment row marked unrecoverable and no file.
struct TranscriptMeetingFixture {
  enum TrackSource: Equatable {
    case blocks(Int)
    /// The same tone at alternating amplitude so the echo gate can calibrate.
    case wavyBlocks(Int)
    case missing, unrecoverable
  }
  struct Stretch {
    var microphone: TrackSource
    var system: TrackSource
    init(microphone: TrackSource = .blocks(4), system: TrackSource = .blocks(4)) {
      self.microphone = microphone
      self.system = system
    }
  }
  let store: MeetingTestStore
  let meetingID: UUID
  let tracks: [MeetingTrackKind: MeetingTrack]
  let files: [Int: [MeetingTrackKind: URL]]
  let startedAt: Int64

  static let blockMs: Int64 = 4_096 * 1_000 / 48_000

  static func make(
    in store: MeetingTestStore, stretches: [Stretch] = [Stretch(), Stretch()],
    liveRequested: Bool = true, startedAt: Int64 = 1_700_000_000_000,
    finalState: MeetingState = .completed, insertTranscription: Bool = true
  ) async throws -> Self {
    precondition(!stretches.isEmpty)
    let created = try await store.store.create(now: startedAt)
    let mic = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .microphone, channelCount: 1,
      bitrate: MeetingTrackKind.microphone.bitrate)
    let sys = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .system, channelCount: 1,
      bitrate: MeetingTrackKind.system.bitrate)
    // A pre-005 (Feature 004) meeting has no transcription row at all.
    let transcriptionEffects: [MeetingTransitionEffect] =
      insertTranscription ? [.insertTranscription(liveRequested: liveRequested)] : []
    try await store.store.transition(
      id: created.id, to: .preparing, now: startedAt,
      effects: [.insertTracks([mic, sys])] + transcriptionEffects)
    var files: [Int: [MeetingTrackKind: URL]] = [:]
    var clock = startedAt
    var opened: [(MeetingSegment, MeetingTrack, TrackSource)] = []
    for (index, stretch) in stretches.enumerated() {
      let sequence = index + 1
      var effects: [MeetingTransitionEffect] = []
      var current: [(MeetingSegment, MeetingTrack, TrackSource)] = []
      for (track, source) in [(mic, stretch.microphone), (sys, stretch.system)]
      where source != .missing {
        let segment = MeetingSegment(
          id: UUID(), trackID: track.id, sequence: sequence,
          relativePath: SegmentHandle.relativePath(
            meetingID: created.id, kind: track.kind, sequence: sequence, open: true),
          startOffsetMs: 0, startedAt: clock, hostStartNs: 1,
          openReason: sequence == 1 ? .start : .resume)
        effects.append(.openSegment(segment))
        current.append((segment, track, source))
      }
      if sequence == 1 {
        try await store.store.transition(
          id: created.id, to: .recording, now: clock, effects: [.setStartedAt(clock)] + effects)
      } else {
        try await store.store.transition(
          id: created.id, to: .paused, now: clock,
          effects: [
            .openPause(.init(id: UUID(), meetingID: created.id, startedAt: clock, reason: .user))
          ])
        clock += 30_000
        try await store.store.transition(
          id: created.id, to: .recording, now: clock,
          effects: [.closeOpenPause(at: clock, closedBy: .resume)] + effects)
      }
      var longest: Int64 = 0
      for (segment, track, source) in current {
        let final = String(segment.relativePath.dropLast(5))
        switch source {
        case .blocks(let blocks), .wavyBlocks(let blocks):
          let url = store.root.resolve(relativePath: final)!
          if case .wavyBlocks = source {
            try ADTSFixtures.write(
              try ADTSFixtures.encodedWavyTone(blocks: blocks, kind: track.kind), to: url)
          } else {
            try ADTSFixtures.write(
              try ADTSFixtures.encodedTone(blocks: blocks, kind: track.kind), to: url)
          }
          files[sequence, default: [:]][track.kind] = url
          let duration = Int64(blocks) * blockMs
          longest = max(longest, duration)
          try await store.store.finalizeSegment(
            id: segment.id, durationMs: duration, byteSize: 1_000, relativePath: final,
            closeReason: index == stretches.count - 1 ? .stop : .pause, droppedFrames: 0,
            now: clock + duration)
        case .unrecoverable:
          try await store.store.markSegmentUnrecoverable(
            id: segment.id, reason: .unrecoverableMedia, note: nil, now: clock)
        case .missing: break
        }
        opened.append((segment, track, source))
      }
      clock += max(longest, 1)
    }
    try await store.store.transition(
      id: created.id, to: .finalizing, now: clock, effects: [.setStoppedAt(clock)])
    for track in [mic, sys] { try await store.store.markTrackFinalized(id: track.id, now: clock) }
    try await store.store.transition(
      id: created.id, to: finalState, now: clock,
      effects: [.setCompletedAt(clock), .finalizationStage(.both), .computeDurationWarnings])
    return Self(
      store: store, meetingID: created.id, tracks: [.microphone: mic, .system: sys], files: files,
      startedAt: startedAt)
  }

  func fileHashes() throws -> [String: Int] {
    var hashes: [String: Int] = [:]
    for (sequence, tracks) in files {
      for (kind, url) in tracks {
        hashes["\(sequence)-\(kind.rawValue)"] = try Data(contentsOf: url).hashValue
      }
    }
    return hashes
  }
}

/// Forwards to a real store while logging every call, so a test can prove which
/// meeting-store methods a transcript type touches.
final class LoggingMeetingStore: MeetingStoring, @unchecked Sendable {
  let base: any MeetingStoring
  private let lock = NSLock()
  private var log: [String] = []
  var calls: [String] { lock.withLock { log } }
  init(_ base: any MeetingStoring) { self.base = base }
  private func note(_ name: String) { lock.withLock { if log.count < 10_000 { log.append(name) } } }
  func activeMeeting() async throws -> Meeting? {
    note("activeMeeting")
    return try await base.activeMeeting()
  }
  func meeting(id: UUID) async throws -> Meeting? {
    note("meeting")
    return try await base.meeting(id: id)
  }
  func create(now: Int64) async throws -> Meeting {
    note("create")
    return try await base.create(now: now)
  }
  @discardableResult
  func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
    async throws -> Meeting
  {
    note("transition:" + to.rawValue)
    return try await base.transition(id: id, to: to, now: now, effects: effects)
  }
  func openSegment(_ segment: MeetingSegment, now: Int64) async throws -> MeetingSegment {
    note("openSegment")
    return try await base.openSegment(segment, now: now)
  }
  func progressSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64
  ) async throws {
    note("progressSegment")
    try await base.progressSegment(
      id: id, durationMs: durationMs, byteSize: byteSize, droppedFrames: droppedFrames, now: now)
  }
  func finalizeSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
    closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64
  ) async throws {
    note("finalizeSegment")
    try await base.finalizeSegment(
      id: id, durationMs: durationMs, byteSize: byteSize, relativePath: relativePath,
      closeReason: closeReason, droppedFrames: droppedFrames, now: now)
  }
  func markSegmentUnrecoverable(
    id: UUID, reason: MeetingFailureReason, note: String?, now: Int64
  ) async throws {
    self.note("markSegmentUnrecoverable")
    try await base.markSegmentUnrecoverable(id: id, reason: reason, note: note, now: now)
  }
  func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) async throws {
    note("markTrackFailed")
    try await base.markTrackFailed(id: id, reason: reason, at: at)
  }
  func markTrackFinalized(id: UUID, now: Int64) async throws {
    note("markTrackFinalized")
    try await base.markTrackFinalized(id: id, now: now)
  }
  func openPause(meetingID: UUID, reason: PauseReason, at: Int64) async throws -> PauseInterval {
    note("openPause")
    return try await base.openPause(meetingID: meetingID, reason: reason, at: at)
  }
  func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) async throws {
    note("closePause")
    try await base.closePause(id: id, at: at, closedBy: closedBy)
  }
  func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) async throws -> Int64 {
    note("saveNotes")
    return try await base.saveNotes(meetingID: meetingID, text: text, revision: revision, now: now)
  }
  func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) async throws -> Int64
  {
    note("setTitle")
    return try await base.setTitle(meetingID: meetingID, title: title, revision: revision, now: now)
  }
  func setLanguage(meetingID: UUID, language: MeetingLanguage?, revision: Int64, now: Int64)
    async throws -> Int64
  {
    note("setLanguage")
    return try await base.setLanguage(
      meetingID: meetingID, language: language, revision: revision, now: now)
  }
  func notes(meetingID: UUID) async throws -> MeetingNotes? {
    note("notes")
    return try await base.notes(meetingID: meetingID)
  }
  func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) async throws {
    note("setFinalizationStage")
    try await base.setFinalizationStage(meetingID: meetingID, stage: stage, now: now)
  }
  func page(before: MeetingCursor?, limit: Int) async throws -> [MeetingSummary] {
    note("page")
    return try await base.page(before: before, limit: limit)
  }
  func detail(id: UUID) async throws -> MeetingDetail? {
    note("detail")
    return try await base.detail(id: id)
  }
  func activeStateRows() async throws -> [Meeting] {
    note("activeStateRows")
    return try await base.activeStateRows()
  }
  func recordOutcome(_ outcome: RecoveryOutcome) async throws {
    note("recordOutcome")
    try await base.recordOutcome(outcome)
  }
  func deleteConfirmed(id: UUID, revision: Int64) async throws -> DeletionOutcome {
    note("deleteConfirmed")
    return try await base.deleteConfirmed(id: id, revision: revision)
  }
}

/// Returns one synthetic detail; used where the work list must exceed what a
/// real store would sensibly hold.
final class StubMeetingStore: MeetingStoring, @unchecked Sendable {
  var detailValue: MeetingDetail?
  private let lock = NSLock()
  private var requested: [UUID] = []
  /// Meeting ids in the order `detail(id:)` was called.
  var detailCalls: [UUID] { lock.withLock { requested } }
  init(detail: MeetingDetail?) { detailValue = detail }
  private func unsupported() -> Error { DictationFailure.invalidResult }
  func activeMeeting() async throws -> Meeting? { nil }
  func meeting(id: UUID) async throws -> Meeting? { detailValue?.meeting }
  func create(now: Int64) async throws -> Meeting { throw unsupported() }
  func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
    async throws -> Meeting
  { throw unsupported() }
  func openSegment(_ segment: MeetingSegment, now: Int64) async throws -> MeetingSegment {
    throw unsupported()
  }
  func progressSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64
  ) async throws { throw unsupported() }
  func finalizeSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
    closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64
  ) async throws { throw unsupported() }
  func markSegmentUnrecoverable(
    id: UUID, reason: MeetingFailureReason, note: String?, now: Int64
  ) async throws { throw unsupported() }
  func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) async throws {
    throw unsupported()
  }
  func markTrackFinalized(id: UUID, now: Int64) async throws { throw unsupported() }
  func openPause(meetingID: UUID, reason: PauseReason, at: Int64) async throws -> PauseInterval {
    throw unsupported()
  }
  func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) async throws { throw unsupported() }
  func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) async throws -> Int64 {
    throw unsupported()
  }
  func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) async throws -> Int64
  { throw unsupported() }
  func setLanguage(meetingID: UUID, language: MeetingLanguage?, revision: Int64, now: Int64)
    async throws -> Int64
  { throw unsupported() }
  func notes(meetingID: UUID) async throws -> MeetingNotes? { detailValue?.notes }
  func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) async throws {
    throw unsupported()
  }
  func page(before: MeetingCursor?, limit: Int) async throws -> [MeetingSummary] { [] }
  func detail(id: UUID) async throws -> MeetingDetail? {
    lock.withLock { if requested.count < 1_000 { requested.append(id) } }
    return detailValue
  }
  func activeStateRows() async throws -> [Meeting] { [] }
  func recordOutcome(_ outcome: RecoveryOutcome) async throws {}
  func deleteConfirmed(id: UUID, revision: Int64) async throws -> DeletionOutcome {
    throw unsupported()
  }
}

/// Forwards to a real transcript store while logging each transition, so a test
/// can prove which states a pass moved through (Transcribe: not_requested →
/// pending → finalizing) without racing the pass.
final class LoggingTranscriptStore: TranscriptStoring, @unchecked Sendable {
  let base: any TranscriptStoring
  private let lock = NSLock()
  private var log: [String] = []
  var transitions: [String] { lock.withLock { log } }
  init(_ base: any TranscriptStoring) { self.base = base }
  private func note(_ name: String) { lock.withLock { if log.count < 10_000 { log.append(name) } } }
  func transcription(meetingID: UUID) async throws -> MeetingTranscription? {
    try await base.transcription(meetingID: meetingID)
  }
  func transition(
    meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription {
    let row = try await base.transition(meetingID: meetingID, to: to, now: now, effects: effects)
    note(to.rawValue)
    return row
  }
  func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) async throws {
    try await base.setLiveState(meetingID: meetingID, liveState: liveState, now: now)
  }
  func updateLiveMetadata(
    meetingID: UUID, descriptor: AnalysisStreamDescriptor, incrementModelReloads: Bool, now: Int64
  ) async throws -> MeetingTranscription {
    try await base.updateLiveMetadata(
      meetingID: meetingID, descriptor: descriptor, incrementModelReloads: incrementModelReloads,
      now: now)
  }
  func appendSegments(
    meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft],
    progress: FinalizationProgress?, now: Int64
  ) async throws -> Int {
    try await base.appendSegments(
      meetingID: meetingID, passID: passID, drafts: drafts, progress: progress, now: now)
  }
  func appendGap(_ gap: LiveGap) async throws { try await base.appendGap(gap) }
  func completeFinalPass(
    meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64,
    now: Int64
  ) async throws -> MeetingTranscription {
    let row = try await base.completeFinalPass(
      meetingID: meetingID, passID: passID, descriptor: descriptor, coveredMs: coveredMs, now: now)
    note(row.state.rawValue)
    return row
  }
  func discardPass(meetingID: UUID, passID: UUID) async throws {
    try await base.discardPass(meetingID: meetingID, passID: passID)
  }
  func restartFinalPass(
    meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription {
    try await base.restartFinalPass(
      meetingID: meetingID, passID: passID, now: now, effects: effects)
  }
  func passSegmentCount(meetingID: UUID, passID: UUID) async throws -> Int {
    try await base.passSegmentCount(meetingID: meetingID, passID: passID)
  }
  /// Runs before every `page` read, so a test can observe state at read time.
  var beforePage: (@Sendable () async -> Void)?
  func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [TranscriptSegment]
  {
    await beforePage?()
    return try await base.page(
      meetingID: meetingID, finality: finality, after: ordinal, limit: limit)
  }
  // Forwarded, or the protocol's no-label defaults would hide the base store's labels.
  func labeledPage(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [LabeledSegment]
  {
    try await base.labeledPage(
      meetingID: meetingID, finality: finality, after: ordinal, limit: limit)
  }
  func acceptedSpeakers(meetingID: UUID) async throws -> AcceptedSpeakers? {
    try await base.acceptedSpeakers(meetingID: meetingID)
  }
  func gaps(meetingID: UUID) async throws -> [LiveGap] { try await base.gaps(meetingID: meetingID) }
  func activeRows(limit: Int) async throws -> [MeetingTranscription] {
    try await base.activeRows(limit: limit)
  }
  func recordOutcome(_ outcome: RecoveryOutcome) async throws {
    try await base.recordOutcome(outcome)
  }
  func usage() async throws -> TranscriptUsage { try await base.usage() }
}

/// SHA-256 of every stretch file of a fixture meeting, keyed by `sequence-kind`.
extension TranscriptMeetingFixture {
  func fileDigests() throws -> [String: String] {
    var digests: [String: String] = [:]
    for (sequence, tracks) in files {
      for (kind, url) in tracks { digests["\(sequence)-\(kind.rawValue)"] = try sha256(of: url) }
    }
    return digests
  }
}

/// Sorted relative listing of a directory tree, excluding the SQLite file and its
/// journal so a test can prove no other file appeared or changed.
func fileListing(under root: URL, excludingDatabase: Bool = true) -> [String] {
  var names: [String] = []
  if let enumerator = FileManager.default.enumerator(atPath: root.path) {
    for case let name as String in enumerator {
      if excludingDatabase, name.hasPrefix("history.sqlite") { continue }
      names.append(name)
    }
  }
  return names.sorted()
}

/// A thread-safe counter for closures the lifecycle or a fake invokes off the test actor.
final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  init(_ initial: Int = 0) { count = initial }
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
