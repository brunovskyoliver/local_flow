import Foundation

/// Research R9: up to three representative quotes for one speaker, deterministic for
/// the same candidates. Prefers segments of at least 4 words, one from each third of
/// the meeting, then the longest of the rest. With only short segments it falls back
/// to the longest of those, so a speaker never shows none.
enum QuoteSelector {
  static let maximum = 3
  static let minimumWords = 4

  struct Candidate: Sendable, Equatable {
    let ordinal: Int
    /// 0, 1 or 2: the third of the meeting the segment starts in.
    let third: Int
    let text: String
  }

  /// The chosen candidates in transcript order.
  static func select(_ candidates: [Candidate]) -> [Candidate] {
    // Longest first, ties by ordinal. Length counts scalars, like the SQL ranking.
    let ranked = candidates.sorted {
      let (lhs, rhs) = ($0.text.unicodeScalars.count, $1.text.unicodeScalars.count)
      return lhs != rhs ? lhs > rhs : $0.ordinal < $1.ordinal
    }
    let long = ranked.filter {
      $0.text.split(whereSeparator: \.isWhitespace).count >= minimumWords
    }
    guard !long.isEmpty else { return Array(ranked.prefix(maximum)).sorted(by: ordinal) }
    var chosen = (0..<3).compactMap { third in long.first { $0.third == third } }
    for candidate in long where chosen.count < maximum && !chosen.contains(candidate) {
      chosen.append(candidate)
    }
    return chosen.sorted(by: ordinal)
  }

  private static func ordinal(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    lhs.ordinal < rhs.ordinal
  }
}
