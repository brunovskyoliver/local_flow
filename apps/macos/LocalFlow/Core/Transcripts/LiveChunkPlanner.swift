import Foundation

struct LiveWindow: Sendable, Equatable {
  let index: Int
  let sampleStart: Int
  let sampleCount: Int
  let stretchSequence: Int
  let isTail: Bool
  var windowIndex: Int { index }
  var startSample: Int64 { Int64(sampleStart) }

  init(
    index: Int, sampleStart: Int, sampleCount: Int, stretchSequence: Int = 1, isTail: Bool = false
  ) {
    self.index = index
    self.sampleStart = sampleStart
    self.sampleCount = sampleCount
    self.stretchSequence = stretchSequence
    self.isTail = isTail
  }
}

/// Counter-only planner. Each instance belongs to exactly one recording stretch.
struct LiveChunkPlanner: Sendable {
  enum Configuration: String, CaseIterable, Sendable {
    case sixSeconds = "live_contiguous_96000_v1"
    case fourSeconds = "live_contiguous_64000_v1"
    var windowSamples: Int { self == .sixSeconds ? 96_000 : 64_000 }
  }
  static let version = Configuration.sixSeconds.rawValue
  static let windowSamples = 96_000
  let configuration: Configuration
  let stretchSequence: Int
  var streamEnd = 0
  private(set) var nextStart = 0
  private var index = 0

  init(configuration: Configuration = .sixSeconds, stretchSequence: Int = 1) {
    self.configuration = configuration
    self.stretchSequence = stretchSequence
  }

  mutating func nextWindow(tail: Bool = false) -> LiveWindow? {
    let remaining = streamEnd - nextStart
    guard remaining > 0, tail || remaining >= configuration.windowSamples else { return nil }
    return consume(min(remaining, configuration.windowSamples))
  }

  /// A gap can terminate a short prefix window. The caller processes that returned prefix
  /// before discarding the gap; no audio preceding the gap silently disappears.
  @discardableResult
  mutating func skip(_ range: Range<Int>) -> LiveWindow? {
    guard !range.isEmpty, range.upperBound > nextStart else { return nil }
    precondition(
      range.lowerBound <= nextStart + configuration.windowSamples,
      "Plan full windows before skipping a later gap")
    let prefix = range.lowerBound > nextStart ? consume(range.lowerBound - nextStart) : nil
    nextStart = max(nextStart, range.upperBound)
    streamEnd = max(streamEnd, nextStart)
    return prefix
  }

  private mutating func consume(_ count: Int) -> LiveWindow {
    let window = LiveWindow(
      index: index, sampleStart: nextStart, sampleCount: count,
      stretchSequence: stretchSequence, isTail: count < configuration.windowSamples)
    nextStart += count
    index += 1
    return window
  }
}
