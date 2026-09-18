import CryptoKit
import Foundation

/// Session-only LRU of digests, never correction text. Oldest observation is evicted at capacity.
struct CorrectionCandidateHistory {
  static let maximumEntries = 128
  private struct Observation {
    let digest: Data
    var count: Int
  }
  private var observations: [Observation] = []
  var count: Int { observations.count }

  mutating func observe(_ candidate: CorrectionCandidate) -> Int {
    guard candidate.sourceText.utf8.count <= 256, candidate.replacementText.utf8.count <= 256 else {
      return 0
    }
    // Length framing avoids ambiguous pairs. Preserve casing: canonical case is meaningful.
    let source = candidate.sourceText.precomposedStringWithCanonicalMapping
    let replacement = candidate.replacementText.precomposedStringWithCanonicalMapping
    let digest = Data(SHA256.hash(data: Data("\(source.utf8.count):\(source)\(replacement)".utf8)))
    let index = observations.firstIndex { $0.digest == digest }
    let previous = index.map { observations.remove(at: $0).count } ?? 0
    if observations.count == Self.maximumEntries { observations.removeFirst() }
    observations.append(Observation(digest: digest, count: min(previous + 1, 3)))
    return previous
  }
}
