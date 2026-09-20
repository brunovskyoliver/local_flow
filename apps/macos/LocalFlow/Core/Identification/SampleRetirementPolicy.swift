import Foundation

/// `retire_qd_v1` (research R5): when a known speaker's active samples would exceed the
/// cap, the lowest-scoring are retired until it holds. Score is quality and diversity:
/// `0.6 × quality_score + 0.4 × (1 − max cosine to any other retained sample)`.
/// Deterministic: ties retire the smaller id first.
enum SampleRetirementPolicy {
  static let version = "retire_qd_v1"
  static let cap = 10
  static let retainedRetired = 10
  static let qualityWeight = 0.6
  static let diversityWeight = 0.4

  struct Entry: Sendable, Equatable {
    let id: UUID
    let vector: [Float]
    let qualityScore: Double
  }

  static func retire(active: [Entry], incoming: [Entry], cap: Int = cap) -> (
    keep: [UUID], retire: [UUID]
  ) {
    var pool = (active + incoming).sorted { $0.id.uuidString < $1.id.uuidString }
    var retired: [UUID] = []
    while pool.count > max(0, cap) {
      var lowest: (index: Int, score: Double)?
      for (index, entry) in pool.enumerated() {
        var nearest: Float = -1
        for (other, candidate) in pool.enumerated() where other != index {
          nearest = max(nearest, IdentityMatcher.cosine(entry.vector, candidate.vector))
        }
        let diversity = 1 - Double(max(-1, min(1, nearest)))
        let score = qualityWeight * entry.qualityScore + diversityWeight * diversity
        if lowest == nil || score < lowest!.score { lowest = (index, score) }
      }
      guard let lowest else { break }
      retired.append(pool.remove(at: lowest.index).id)
    }
    return (pool.map(\.id), retired)
  }
}
