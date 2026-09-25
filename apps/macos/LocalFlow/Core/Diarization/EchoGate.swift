import Foundation

/// `echo_lag1s_p20_k12_min300_v1`. Removes remote speech that reached the microphone
/// through the speakers from the microphone track's turns.
///
/// The system track is the remote side's clean signal, so a microphone frame whose
/// energy sits a fixed gain below the (lagged) system frame is echo, not the local
/// speaker. The gain is measured per run from the meeting itself: with speakers it is
/// the acoustic path, with headphones no frame satisfies the rule and nothing is
/// removed. Frames are 100 ms of the 16 kHz analysis stream; the gate only ever
/// shortens or splits a microphone turn and never reads text (FR-001, FR-008).
enum EchoGate {
  static var version: String { DiarizationPipelineVersion.echoGate }

  static let frameSamples = 1_600
  static let frameMs: Int64 = 100
  /// The speaker-to-microphone path plus output and input latency: at most 1 s.
  static let maxLagFrames = 10
  /// Below this the system track is silent for gain and gating purposes.
  static let remoteFloorDB: Float = -60
  /// Microphone frames this far above the track's quiet level carry a signal.
  static let micFloorMarginDB: Float = 6
  /// Paired frames needed before the gain estimate is trusted: 30 s.
  static let minPairedFrames = 300
  /// The gain is the 20th percentile of mic − system over paired frames, which
  /// sits inside the echo cluster whenever echo is present.
  static let gainPercentile = 0.20
  /// Local speech must exceed the echo prediction by this much.
  static let marginDB: Float = 12
  /// Log-energy correlation at the best lag; headphone meetings sit near zero.
  static let minCorrelation = 0.10
  /// Turn pieces shorter than this are dropped, and gaps up to this are bridged.
  static let minPieceMs: Int64 = 300
  static let bridgeMs: Int64 = 300
  /// Frames kept per track per run: 8 h 20 min. Beyond it the gate is inactive.
  static let frameCapacity = 300_000

  /// One stretch's frame energies in dB, both tracks on the stretch's timeline.
  struct Stretch: Sendable, Equatable {
    let baseMs: Int64
    var microphone: [Float]
    var system: [Float]
  }

  struct Profile: Sendable, Equatable {
    var stretches: [Int: Stretch] = [:]
    var frames: Int {
      stretches.values.reduce(0) { $0 + max($1.microphone.count, $1.system.count) }
    }
  }

  struct Calibration: Sendable, Equatable {
    let lagFrames: Int
    let gainDB: Float
    let correlation: Double
    var thresholdDB: Float { gainDB + marginDB }
  }

  /// Accumulates one track's 16 kHz mono emissions into 100 ms frame energies.
  struct FrameAccumulator: Sendable {
    private(set) var frames: [Float] = []
    private var sum: Double = 0
    private var count = 0

    mutating func append(_ samples: [Float]) {
      for sample in samples {
        sum += Double(sample * sample)
        count += 1
        if count == frameSamples { flush() }
      }
    }

    /// A half-full trailing frame counts; anything shorter is dropped.
    mutating func finish() -> [Float] {
      if count >= frameSamples / 2 { flush() }
      sum = 0
      count = 0
      return frames
    }

    private mutating func flush() {
      frames.append(EchoGate.decibels(sum / Double(count)))
      sum = 0
      count = 0
    }
  }

  static func decibels(_ meanSquare: Double) -> Float {
    Float(10 * log10(meanSquare + 1e-10))
  }

  // MARK: Calibration

  /// nil when the profile cannot support a gate: too few paired frames, or the two
  /// tracks do not move together at any lag.
  /// True when no system frame in the profile rises above the silence floor: the
  /// remote side never spoke, or the system track has no audio at all.
  static func systemIsSilent(_ profile: Profile) -> Bool {
    profile.stretches.values.allSatisfy { stretch in
      stretch.system.allSatisfy { $0 <= remoteFloorDB }
    }
  }

  static func calibrate(_ profile: Profile) -> Calibration? {
    guard profile.frames <= frameCapacity else { return nil }
    let stretches = profile.stretches.values.filter {
      !$0.microphone.isEmpty && !$0.system.isEmpty
    }
    guard !stretches.isEmpty else { return nil }
    var best: (lag: Int, correlation: Double)?
    for lag in 0...maxLagFrames {
      var n = 0.0
      var sx = 0.0
      var sy = 0.0
      var sxx = 0.0
      var syy = 0.0
      var sxy = 0.0
      for stretch in stretches {
        let count = min(stretch.microphone.count - lag, stretch.system.count)
        guard count > 0 else { continue }
        for index in 0..<count {
          let x = Double(stretch.microphone[index + lag])
          let y = Double(stretch.system[index])
          n += 1
          sx += x
          sy += y
          sxx += x * x
          syy += y * y
          sxy += x * y
        }
      }
      guard n > 1 else { continue }
      let cov = sxy - sx * sy / n
      let vx = sxx - sx * sx / n
      let vy = syy - sy * sy / n
      guard vx > 0, vy > 0 else { continue }
      let correlation = cov / (vx * vy).squareRoot()
      if best == nil || correlation > best!.correlation { best = (lag, correlation) }
    }
    guard let best, best.correlation >= minCorrelation else { return nil }
    let micFloor = percentile(stretches.flatMap(\.microphone), gainPercentile) + micFloorMarginDB
    var ratios: [Float] = []
    for stretch in stretches {
      let system = laggedSystem(stretch, lag: best.lag)
      for index in 0..<min(stretch.microphone.count, system.count)
      where system[index] > remoteFloorDB && stretch.microphone[index] > micFloor {
        ratios.append(stretch.microphone[index] - system[index])
      }
    }
    guard ratios.count >= minPairedFrames else { return nil }
    return .init(
      lagFrames: best.lag, gainDB: percentile(ratios, gainPercentile),
      correlation: best.correlation)
  }

  /// The system track shifted onto the microphone's timeline, each frame the maximum
  /// over its neighbours so a lag that is off by one frame still lines up.
  private static func laggedSystem(_ stretch: Stretch, lag: Int) -> [Float] {
    let count = stretch.microphone.count
    var shifted = [Float](repeating: -100, count: count)
    for index in 0..<count where index >= lag && index - lag < stretch.system.count {
      shifted[index] = stretch.system[index - lag]
    }
    return shifted.indices.map { index in
      var value = shifted[index]
      if index > 0 { value = max(value, shifted[index - 1]) }
      if index + 1 < count { value = max(value, shifted[index + 1]) }
      return value
    }
  }

  private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
    guard !values.isEmpty else { return -100 }
    let sorted = values.sorted()
    let position = min(
      sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
    return sorted[position]
  }

  // MARK: Gating

  /// Echo-explained spans of one stretch on the recorded timeline, merged and sorted.
  static func echoRanges(_ stretch: Stretch, calibration: Calibration) -> [Range<Int64>] {
    let system = laggedSystem(stretch, lag: calibration.lagFrames)
    var ranges: [Range<Int64>] = []
    for index in 0..<min(stretch.microphone.count, system.count)
    where system[index] > remoteFloorDB
      && stretch.microphone[index] - system[index] <= calibration.thresholdDB
    {
      let start = stretch.baseMs + Int64(index) * frameMs
      let end = start + frameMs
      if let last = ranges.last, last.upperBound == start {
        ranges[ranges.count - 1] = last.lowerBound..<end
      } else {
        ranges.append(start..<end)
      }
    }
    return ranges
  }

  /// Silences the echo-explained spans of one microphone window before recognition,
  /// so the remote voice is transcribed from the system track alone. `startMs` is the
  /// window's start on the same timeline as `echo`; edges get a 10 ms fade.
  static let fadeSamples = 160
  static func mute(_ samples: inout [Float], startMs: Int64, echo: [Range<Int64>]) -> Int64 {
    guard !echo.isEmpty, !samples.isEmpty else { return 0 }
    let endMs = startMs + Int64(samples.count) * 1_000 / 16_000
    var muted: Int64 = 0
    samples.withUnsafeMutableBufferPointer { buffer in
      for range in echo where range.upperBound > startMs && range.lowerBound < endMs {
        let lower = Int(max(0, (range.lowerBound - startMs) * 16))
        let upper = Int(min(Int64(buffer.count), (range.upperBound - startMs) * 16))
        guard lower < upper else { continue }
        muted += Int64(upper - lower) / 16
        // Fades only where the span really starts or ends; a span cut by the window
        // edge continues in the neighbouring window.
        let fade = min(fadeSamples, (upper - lower) / 2)
        let fadeIn = range.lowerBound >= startMs ? fade : 0
        let fadeOut = range.upperBound <= endMs ? fade : 0
        for index in lower..<upper {
          var factor: Float = 0
          if index - lower < fadeIn {
            factor = 1 - Float(index - lower + 1) / Float(fadeIn + 1)
          } else if upper - 1 - index < fadeOut {
            factor = 1 - Float(upper - index) / Float(fadeOut + 1)
          }
          buffer[index] *= factor
        }
      }
    }
    return muted
  }

  /// Subtracts `echo` from every microphone turn. Pieces separated by at most
  /// `bridgeMs` rejoin; pieces under `minPieceMs` go. Other tracks pass through.
  static func apply(_ turns: [TurnDraft], echo: [Range<Int64>]) -> [TurnDraft] {
    guard !echo.isEmpty else { return turns }
    var result: [TurnDraft] = []
    for turn in turns {
      guard turn.track == .microphone else {
        result.append(turn)
        continue
      }
      var pieces: [Range<Int64>] = []
      var cursor = turn.startMs
      for range in echo where range.upperBound > turn.startMs && range.lowerBound < turn.endMs {
        if range.lowerBound > cursor { pieces.append(cursor..<range.lowerBound) }
        cursor = max(cursor, range.upperBound)
      }
      if cursor < turn.endMs { pieces.append(cursor..<turn.endMs) }
      var bridged: [Range<Int64>] = []
      for piece in pieces {
        if let last = bridged.last, piece.lowerBound - last.upperBound <= bridgeMs {
          bridged[bridged.count - 1] = last.lowerBound..<piece.upperBound
        } else {
          bridged.append(piece)
        }
      }
      for piece in bridged where piece.upperBound - piece.lowerBound >= minPieceMs {
        result.append(
          .init(
            speakerID: turn.speakerID, track: turn.track, startMs: piece.lowerBound,
            endMs: piece.upperBound, quality: turn.quality))
      }
    }
    return result
  }
}
