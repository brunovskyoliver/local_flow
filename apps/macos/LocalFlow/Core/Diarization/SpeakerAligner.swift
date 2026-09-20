import Foundation

/// `align_dom0.60_ratio2_ovl0.20_bytrack_v2` (research R6). Labels a transcript segment
/// from speaker turns and times only; it never sees text (FR-001, FR-013). The caller
/// passes only the turns of the segment's own track when the row came from one track.
enum SpeakerAligner {
  static var version: String { DiarizationPipelineVersion.aligner }

  /// `speaker` is the run cluster key; nil marks reconciliation overflow, which counts
  /// toward no speaker.
  struct Turn: Sendable, Equatable {
    let speaker: Int?
    var track: MeetingTrackKind = .microphone
    let startMs: Int64
    let endMs: Int64
  }

  struct Segment: Sendable, Equatable {
    let startMs: Int64
    let endMs: Int64
  }

  struct Assignment: Sendable, Equatable {
    let kind: SpeakerAssignmentKind
    let speaker: Int?
    let top: Int?
    let second: Int?
    let topCoverage: Double
    let secondCoverage: Double
  }

  /// Thresholds as whole percentages so the edges compare exactly in integer ms.
  private static let dominant = percent(DiarizationConstants.alignDominant)
  private static let overlap = percent(DiarizationConstants.alignOverlap)
  private static let ratio = percent(DiarizationConstants.alignRatio)

  // ponytail: O(segments × turns) per page; both are bounded by the 500-segment page
  // and its time span. Sweep with a moving start index if pages ever get denser.
  static func align(_ segments: [Segment], turns: [Turn]) -> [Assignment] {
    segments.map { assign($0, turns: turns) }
  }

  static func assign(_ segment: Segment, turns: [Turn]) -> Assignment {
    let duration = segment.endMs - segment.startMs
    guard duration > 0 else {
      return .init(
        kind: .unknown, speaker: nil, top: nil, second: nil, topCoverage: 0, secondCoverage: 0)
    }
    var clipped: [Int: [(Int64, Int64)]] = [:]
    for turn in turns {
      guard let speaker = turn.speaker else { continue }
      let start = max(turn.startMs, segment.startMs)
      let end = min(turn.endMs, segment.endMs)
      if start < end { clipped[speaker, default: []].append((start, end)) }
    }
    // Covered milliseconds per speaker: the union of that speaker's turns.
    let covered = clipped.map { speaker, spans -> (speaker: Int, ms: Int64) in
      var total: Int64 = 0
      var reach = Int64.min
      for (start, end) in spans.sorted(by: { $0.0 < $1.0 }) where end > reach {
        total += end - max(start, reach)
        reach = end
      }
      return (speaker, total)
    }.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.speaker < $1.speaker }
    let first = covered.first
    let second = covered.dropFirst().first
    let c1 = first?.ms ?? 0
    let c2 = second?.ms ?? 0
    let kind: SpeakerAssignmentKind
    if c1 > 0, c1 * 100 >= dominant * duration, c1 * 100 >= ratio * c2 {
      kind = .speaker
    } else if c2 * 100 >= overlap * duration, c2 > 0 {
      kind = .ambiguous
    } else {
      kind = .unknown
    }
    return .init(
      kind: kind, speaker: kind == .speaker ? first?.speaker : nil, top: first?.speaker,
      second: second?.speaker, topCoverage: Double(c1) / Double(duration),
      secondCoverage: Double(c2) / Double(duration))
  }

  private static func percent(_ value: Double) -> Int64 { Int64((value * 100).rounded()) }
}
