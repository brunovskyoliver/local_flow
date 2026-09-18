import Foundation
import Observation

/// One in-flight window and a bounded set of drafts waiting for a committed batch.
@MainActor @Observable
final class LiveRecognizer {
  enum Failure: Error, Equatable { case runtimeFailure, persistenceFailure, analysisStreamFailure }
  static let provisionalCapacity = 200
  let queue = AnalysisQueue()
  private(set) var isWindowInFlight = false
  private(set) var lastLatencyNanoseconds: UInt64 = 0
  let windowBufferAllocationCount = 1
  private(set) var refusedSamples = 0
  private(set) var consumedEnd = 0
  private var planner = LiveChunkPlanner()
  // Holes contain no PCM. At the metadata bound, refuse incoming PCM until
  // the consumer advances, extending the last hole instead of allocating.
  static let maximumGapRanges = 64
  private var holes: [Range<Int>] = []
  var gapRangeCount: Int { holes.count }
  var stretchSequence: Int { sequence }
  var stretchBaseMs: Int64 { baseMs }
  var lag: Int { max(0, streamEnd - consumedEnd) }

  private var assembler = MeetingWindowAssembler()
  private let lifecycle: ModelLifecycleCoordinator
  private let lease: ModelLease
  private let sequence: Int
  private let baseMs: Int64
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let segmenter: TranscriptSegmenter
  private let engine: String
  private let model: TranscriptModelIdentity
  private let pipelineVersion: String
  private var nextOrdinal: Int
  private var samples = [Float](repeating: 0, count: LiveChunkPlanner.windowSamples)
  private var drafts: [TranscriptSegmentDraft] = []
  private struct Stamp {
    var emittedAt: UInt64
    var tracks: AnalysisTracks
  }
  // At most six windows overlap the 30-second queue, plus the in-flight window.
  private var stamps: [Int: Stamp] = [:]

  var pendingCount: Int { drafts.count }
  var streamEnd: Int { planner.streamEnd }
  var nextSegmentOrdinal: Int { nextOrdinal }

  init(
    lifecycle: ModelLifecycleCoordinator, lease: ModelLease, sequence: Int,
    baseMs: Int64 = 0, ordinal: Int = 0, vocabulary: VocabularySnapshot = .empty,
    engine: String = "FluidAudio",
    model: TranscriptModelIdentity = .init(
      id: "unrecorded", revision: "unrecorded", manifestHash: ""),
    pipelineVersion: String = "", clock: any MeetingClock = SystemMeetingClock(),
    recorder: ResourceRecorder? = nil
  ) {
    self.lifecycle = lifecycle
    self.lease = lease
    self.sequence = sequence
    self.planner = LiveChunkPlanner(stretchSequence: sequence)
    self.baseMs = baseMs
    self.nextOrdinal = ordinal
    self.segmenter = TranscriptSegmenter(vocabulary: vocabulary)
    self.engine = engine
    self.model = model
    self.pipelineVersion = pipelineVersion
    self.clock = clock
    self.recorder = recorder
    drafts.reserveCapacity(Self.provisionalCapacity)
  }

  @discardableResult
  func accept(_ incoming: [Float], tracks: AnalysisTracks, emittedAt: UInt64) -> Int {
    let start = planner.streamEnd
    let accepted = holes.count >= Self.maximumGapRanges ? 0 : queue.write(incoming)
    refusedSamples += incoming.count - accepted
    planner.streamEnd += accepted
    if accepted < incoming.count { insertGap((start + accepted)..<(start + incoming.count)) }
    guard accepted > 0 else { return 0 }
    for key
      in (start / LiveChunkPlanner.windowSamples)...((start + accepted - 1)
      / LiveChunkPlanner.windowSamples)
    {
      let old = stamps[key]
      stamps[key] = Stamp(
        emittedAt: emittedAt, tracks: old.map { $0.tracks == tracks ? tracks : .both } ?? tracks)
    }
    return accepted
  }

  func insertGap(_ range: Range<Int>) {
    guard !range.isEmpty else { return }
    precondition(range.lowerBound == planner.streamEnd)
    if let last = holes.last, last.upperBound == range.lowerBound {
      holes[holes.count - 1] = last.lowerBound..<range.upperBound
    } else {
      precondition(holes.count < Self.maximumGapRanges)
      holes.append(range)
    }
    planner.streamEnd = range.upperBound
  }

  private func skipLeadingHoles() {
    while let hole = holes.first, hole.lowerBound <= planner.nextStart {
      planner.skip(hole)
      consumedEnd = max(consumedEnd, hole.upperBound)
      holes.removeFirst()
      assembler = MeetingWindowAssembler()
    }
    stamps = stamps.filter { $0.key >= planner.nextStart / LiveChunkPlanner.windowSamples }
  }

  /// Called only between inferences, so in-flight audio remains unconsumed in lag.
  /// Return only newly discarded PCM ranges; existing holes already have gap rows.
  func applyBackpressure() -> [Range<Int>] {
    guard !isWindowInFlight else { return [] }
    skipLeadingHoles()
    let excess = lag - AnalysisQueue.toleratedLagSamples
    guard excess > 0 else { return [] }
    let count = min(
      (excess + LiveChunkPlanner.windowSamples - 1) / LiveChunkPlanner.windowSamples,
      (streamEnd - planner.nextStart) / LiveChunkPlanner.windowSamples)
    return discard(through: planner.nextStart + count * LiveChunkPlanner.windowSamples)
  }

  func discardRemaining() -> [Range<Int>] {
    precondition(!isWindowInFlight)
    return discard(through: streamEnd)
  }

  private func discard(through end: Int) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    while planner.nextStart < end {
      skipLeadingHoles()
      guard planner.nextStart < end else { break }
      let boundary = min(end, holes.first?.lowerBound ?? end)
      let range = planner.nextStart..<boundary
      queue.discardOldest(count: range.count)
      // skip() is designed for one window at a time.
      while planner.nextStart < boundary {
        planner.skip(
          planner.nextStart..<min(boundary, planner.nextStart + LiveChunkPlanner.windowSamples))
      }
      if let last = ranges.last, last.upperBound == range.lowerBound {
        ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
      } else {
        ranges.append(range)
      }
      consumedEnd = planner.nextStart
    }
    skipLeadingHoles()
    assembler = MeetingWindowAssembler()
    return ranges
  }

  /// The caller runs a single serial pump. Concurrent ticks only append to the ring.
  @discardableResult
  func processNext(tail: Bool = false) async throws -> Bool {
    guard !isWindowInFlight else { return false }
    skipLeadingHoles()
    let end = planner.streamEnd
    if let hole = holes.first { planner.streamEnd = hole.lowerBound }
    let window = planner.nextWindow(tail: tail || !holes.isEmpty)
    planner.streamEnd = end
    guard let window else { return false }
    guard queue.occupancy >= window.sampleCount else { throw Failure.analysisStreamFailure }
    isWindowInFlight = true
    defer { isWindowInFlight = false }
    let count = samples.withUnsafeMutableBufferPointer {
      queue.read(into: $0, count: window.sampleCount)
    }
    guard count == window.sampleCount else { throw Failure.analysisStreamFailure }
    let firstKey = window.sampleStart / LiveChunkPlanner.windowSamples
    let lastKey = (window.sampleStart + count - 1) / LiveChunkPlanner.windowSamples
    let coveredStamps = (firstKey...lastKey).compactMap { stamps[$0] }
    let stamp = Stamp(
      emittedAt: coveredStamps.map(\.emittedAt).max() ?? clock.monotonicNanoseconds,
      tracks: Set(coveredStamps.map(\.tracks)).count > 1
        ? .both : coveredStamps.first?.tracks ?? .mic)
    // Keep a partial bucket: the next window can start inside it after a gap.
    let firstRemainingKey = (window.sampleStart + count) / LiveChunkPlanner.windowSamples
    stamps = stamps.filter { $0.key >= firstRemainingKey }
    let result: TranscriptionWindow
    do {
      result = try await lifecycle.transcribe(
        lease, samples: count == samples.count ? samples : Array(samples.prefix(count)))
    } catch is CancellationError { throw CancellationError() } catch DictationFailure.cancelled {
      throw CancellationError()
    } catch { throw Failure.runtimeFailure }
    let assembled = assembler.append(
      window: .init(
        sequence: window.index, sampleStart: window.sampleStart, sampleCount: count,
        paddedSampleCount: max(4_800, count), text: result.text, tokens: Self.mapTokens(result)))
    var produced = segmenter.segments(
      window: assembled,
      base: .init(
        stretchSequence: sequence, stretchBaseMs: baseMs, tracks: stamp.tracks, ordinal: nextOrdinal
      ))
    guard drafts.count + produced.count <= Self.provisionalCapacity else {
      throw Failure.persistenceFailure
    }
    for index in produced.indices {
      produced[index].engine = engine
      produced[index].modelID = model.id
      produced[index].modelRevision = model.revision
      produced[index].pipelineVersion = pipelineVersion
    }
    drafts.append(contentsOf: produced)
    nextOrdinal += produced.count
    consumedEnd = window.sampleStart + count
    lastLatencyNanoseconds =
      clock.monotonicNanoseconds >= stamp.emittedAt
      ? clock.monotonicNanoseconds - stamp.emittedAt : 0
    recorder?.record(
      phase: .transcriptLive, durationNanoseconds: lastLatencyNanoseconds,
      metric: .transcriptLiveLatency)
    return true
  }

  func pendingBatch() -> [TranscriptSegmentDraft] { Array(drafts.prefix(50)) }
  func acknowledgeBatch(count: Int) {
    precondition(count >= 0 && count <= min(50, drafts.count))
    drafts.removeFirst(count)
  }

  private static func mapTokens(_ result: TranscriptionWindow) -> [TranscriptAssembler.Token]? {
    TranscriptSourceMapper.map(text: result.text, words: result.tokens)
  }
}
