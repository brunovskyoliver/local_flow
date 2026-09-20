import Foundation

/// `carry_ovl0.50_ratio2_v1` (research R7): which speakers of a superseded run map to
/// clusters of the run being adopted, from turn overlap alone. Pure; the store streams
/// turns through `OverlapSweep` and applies the effects inside the completion
/// transaction. A name, merge or correction that does not map safely is never guessed.
enum CorrectionCarryOver {
  static let version = "carry_ovl0.50_ratio2_v1"
  /// Turns per sweep page.
  static let page = 1_000

  struct Turn: Sendable, Equatable {
    let speaker: UUID
    let track: MeetingTrackKind
    let startMs: Int64
    let endMs: Int64
  }

  /// A speaker of either run: its track and, for the old run, its total speech.
  struct Speaker: Sendable, Equatable {
    let id: UUID
    let track: MeetingTrackKind
    var speechMs: Int64 = 0
  }

  /// Overlap milliseconds per (old speaker, new speaker) on the same track, accumulated
  /// over pages of turns in any order. Cross-track pairs are never counted.
  struct OverlapSweep: Sendable, Equatable {
    private(set) var overlaps: [UUID: [UUID: Int64]] = [:]

    mutating func add(old: [Turn], new: [Turn]) {
      // Both pages are bounded by the store's time-span read, so the product is small.
      for turn in old {
        for other in new where other.track == turn.track {
          let ms = min(turn.endMs, other.endMs) - max(turn.startMs, other.startMs)
          if ms > 0 { overlaps[turn.speaker, default: [:]][other.speaker, default: 0] += ms }
        }
      }
    }

    func overlap(_ old: UUID, _ new: UUID) -> Int64 { overlaps[old]?[new] ?? 0 }
  }

  /// Thresholds as whole percentages, so the edges compare exactly in integer ms.
  private static let coverage = Int64((DiarizationConstants.carryOverlap * 100).rounded())
  private static let ratio = Int64((DiarizationConstants.carryRatio * 100).rounded())

  /// Old speaker → new speaker, for every old speaker that maps. S maps to N when
  /// overlap ≥ 0.50 × speech(S), overlap ≥ 2 × S's next-best, N's best old speaker is S
  /// (strictly, so a tie maps nobody) and no other old speaker maps to N.
  static func map(old: [Speaker], new: [Speaker], sweep: OverlapSweep) -> [UUID: UUID] {
    let olds = old.sorted { $0.id.uuidString < $1.id.uuidString }
    let news = new.sorted { $0.id.uuidString < $1.id.uuidString }
    var proposed: [UUID: UUID] = [:]
    for speaker in olds where speaker.speechMs > 0 {
      let candidates = news.filter { $0.track == speaker.track }
        .map { ($0.id, sweep.overlap(speaker.id, $0.id)) }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.uuidString < $1.0.uuidString }
      guard let best = candidates.first, best.1 > 0 else { continue }
      let next = candidates.dropFirst().first?.1 ?? 0
      guard best.1 * 100 >= coverage * speaker.speechMs, best.1 * 100 >= ratio * next else {
        continue
      }
      // Reciprocal: among every old speaker on the track, S alone overlaps N the most.
      let rivals = olds.filter { $0.track == speaker.track && $0.id != speaker.id }
        .map { sweep.overlap($0.id, best.0) }
      guard rivals.allSatisfy({ $0 < best.1 }) else { continue }
      proposed[speaker.id] = best.0
    }
    // Unique: a new speaker claimed twice maps to nobody.
    var claims: [UUID: Int] = [:]
    for target in proposed.values { claims[target, default: 0] += 1 }
    return proposed.filter { claims[$0.value] == 1 }
  }
}
