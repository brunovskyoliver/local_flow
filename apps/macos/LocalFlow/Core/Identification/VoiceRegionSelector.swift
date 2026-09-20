import Foundation

/// `regions_v1` (research R4): which single-speaker stretches of one display root are
/// clean enough to embed, and in what order. Pure and deterministic for equal input.
/// Every number is a named constant; changing one bumps `version`.
enum VoiceRegionSelector {
  static let version = "regions_v1"
  static let sampleRate = 16_000
  /// Trimmed from each end of a turn before it is measured.
  static let trimMs: Int64 = 200
  /// Provisional (T014 may raise it if short regions hurt calibration).
  static let minDurationMs: Int64 = 3_000
  static let maxDurationMs: Int64 = 20_000
  /// Turns with an engine quality below this are skipped; absent quality is allowed.
  static let minEngineQuality = 0.5
  /// `good` needs this much speech and this quality (or none reported).
  static let goodDurationMs: Int64 = 6_000
  static let goodQuality = 0.7
  /// Clipped: more than this fraction of samples at or above the threshold.
  static let clippingThreshold: Float = 0.99
  static let clippingRatio = 0.001
  /// Too quiet: RMS below this level.
  static let quietDBFS = -45.0
  /// The meeting is split into this many equal spans for the spread rule.
  static let spans = 5

  struct Limits: Sendable, Equatable {
    let maxRegions: Int
    let maxTotalMs: Int64
    static let enroll = Limits(maxRegions: 5, maxTotalMs: 100_000)
    static let query = Limits(maxRegions: 4, maxTotalMs: 60_000)
  }

  /// Eligible regions of the root, longest per span first, then the remaining longest,
  /// up to the limits; returned in start order.
  static func select(
    rootTurns: [SpeakerTurn], otherTurns: [SpeakerTurn], meetingLengthMs: Int64, limits: Limits
  ) -> [VoiceRegion] {
    let others = otherTurns.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
    var candidates: [VoiceRegion] = []
    for turn in rootTurns.sorted(by: { ($0.startMs, $0.id) < ($1.startMs, $1.id) }) {
      guard turn.speakerID != nil, !turn.overlapped else { continue }
      if let quality = turn.engineQuality, quality < minEngineQuality { continue }
      // Intersecting another speaker's turn on either track disqualifies the turn.
      let clashes = others.contains { other in
        other.speakerID != turn.speakerID && other.startMs < turn.endMs
          && other.endMs > turn.startMs
      }
      if clashes { continue }
      let start = turn.startMs + trimMs
      let end = min(turn.endMs - trimMs, start + maxDurationMs)
      guard end - start >= minDurationMs else { continue }
      candidates.append(
        VoiceRegion(
          track: turn.track, startMs: start, endMs: end, engineQuality: turn.engineQuality)
      )
    }
    guard !candidates.isEmpty, limits.maxRegions > 0 else { return [] }
    let length = max(meetingLengthMs, candidates.map(\.endMs).max() ?? 1, 1)
    func span(_ region: VoiceRegion) -> Int {
      min(spans - 1, Int(region.startMs * Int64(spans) / length))
    }
    // Longest first, ties by start, within each span; then across the rest.
    let byLength: (VoiceRegion, VoiceRegion) -> Bool = {
      $0.durationMs != $1.durationMs ? $0.durationMs > $1.durationMs : $0.startMs < $1.startMs
    }
    var ordered: [VoiceRegion] = []
    var remaining = candidates
    for index in 0..<spans {
      guard let best = remaining.filter({ span($0) == index }).sorted(by: byLength).first else {
        continue
      }
      ordered.append(best)
      remaining.removeAll { $0 == best }
    }
    ordered += remaining.sorted(by: byLength)
    var chosen: [VoiceRegion] = []
    var budget = limits.maxTotalMs
    for region in ordered where chosen.count < limits.maxRegions {
      guard budget >= minDurationMs else { break }
      if region.durationMs <= budget {
        chosen.append(region)
        budget -= region.durationMs
      } else {
        // The last region is cut to the remaining budget rather than dropped.
        chosen.append(
          VoiceRegion(
            track: region.track, startMs: region.startMs, endMs: region.startMs + budget,
            engineQuality: region.engineQuality))
        budget = 0
      }
    }
    return chosen.sorted { ($0.startMs, $0.track.rawValue) < ($1.startMs, $1.track.rawValue) }
  }

  /// After decoding: clipped or too quiet regions are rejected and counted, never used.
  static func audioCheck(_ samples: [Float]) -> RegionRejection? {
    guard !samples.isEmpty else { return .tooQuiet }
    var clipped = 0
    var energy = 0.0
    for sample in samples {
      if abs(sample) >= clippingThreshold { clipped += 1 }
      energy += Double(sample) * Double(sample)
    }
    if Double(clipped) > clippingRatio * Double(samples.count) { return .clipped }
    let rms = (energy / Double(samples.count)).squareRoot()
    if rms <= 0 || 20 * log10(rms) < quietDBFS { return .tooQuiet }
    return nil
  }

  static func qualityLabel(durationMs: Int64, engineQuality: Double?) -> VoiceQualityLabel {
    durationMs >= goodDurationMs && (engineQuality ?? goodQuality) >= goodQuality ? .good : .fair
  }

  /// 0…1: half from length (full at 2 × the `good` length), half from engine quality.
  static func qualityScore(durationMs: Int64, engineQuality: Double?) -> Double {
    let length = min(1, max(0, Double(durationMs) / Double(goodDurationMs * 2)))
    let quality = min(1, max(0, engineQuality ?? goodQuality))
    return 0.5 * length + 0.5 * quality
  }
}
