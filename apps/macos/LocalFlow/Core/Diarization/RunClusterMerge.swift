import Foundation

/// `merge_cos0.70_v1`. The window reconciler is greedy and forward-only: a cluster it
/// creates for a voice it already knows (a fragment in one window, a window whose
/// centroid was still built from a few chunks) stays a separate "Speaker N" for the
/// rest of the run. This is the global step the literature applies to chunked
/// diarization: after every window, the run clusters of a track are clustered again
/// on their duration-weighted centroids with centroid linkage, most similar pair
/// first, while a pair is at least τ. Pure; runs once per run before the minor fold
/// and never reads text (FR-001). Tracks are never merged with each other.
enum RunClusterMerge {
  static var version: String { DiarizationPipelineVersion.merge }

  /// The reconciler's τ: two run clusters this close would have been one had their
  /// first windows met in the right order.
  static let mergeSimilarity = DiarizationConstants.reconcileSimilarity

  struct Cluster: Sendable, Equatable {
    let key: Int
    let track: MeetingTrackKind
    let speechMs: Int64
    let centroid: [Double]?
  }

  struct Merge: Sendable, Equatable {
    /// The cluster that goes away and the one it joins; the survivor is always the
    /// lower key, so the first voice heard keeps its label.
    let key: Int
    let into: Int
    /// Cosine between the two centroids when the pair was chosen.
    let similarity: Double
  }

  struct Result: Sendable, Equatable {
    /// Merged cluster → survivor, already resolved through chains.
    var folds: [Int: Int] = [:]
    /// Each survivor's combined speech and weighted centroid.
    var clusters: [Cluster] = []
    /// The pairs in the order they were merged, for the run log.
    var merges: [Merge] = []
  }

  static func apply(_ clusters: [Cluster]) -> Result {
    var result = Result()
    var survivors: [Cluster] = []
    for track in [MeetingTrackKind.system, .microphone] {
      var members = clusters.filter { $0.track == track }.sorted { $0.key < $1.key }
      while let pair = closestPair(members) {
        let (low, high) = (members[pair.low], members[pair.high])
        members.remove(at: pair.high)
        members[pair.low] = combine(low, high)
        result.merges.append(.init(key: high.key, into: low.key, similarity: pair.similarity))
        // Anything folded into `high` earlier now follows it into `low`.
        for (key, into) in result.folds where into == high.key { result.folds[key] = low.key }
        result.folds[high.key] = low.key
      }
      survivors += members
    }
    result.clusters = survivors.sorted { $0.key < $1.key }
    return result
  }

  private static func closestPair(_ members: [Cluster])
    -> (low: Int, high: Int, similarity: Double)?
  {
    var best: (low: Int, high: Int, similarity: Double)?
    for low in members.indices {
      guard let left = members[low].centroid else { continue }
      for high in members.indices where high > low {
        guard let right = members[high].centroid else { continue }
        let value = WindowClusterReconciler.cosine(left, right)
        guard value >= mergeSimilarity, best.map({ value > $0.similarity }) ?? true else {
          continue
        }
        best = (low, high, value)
      }
    }
    return best
  }

  private static func combine(_ low: Cluster, _ high: Cluster) -> Cluster {
    let weightLow = Double(max(low.speechMs, 1))
    let weightHigh = Double(max(high.speechMs, 1))
    var centroid = low.centroid
    if let left = low.centroid, let right = high.centroid, left.count == right.count {
      centroid = zip(left, right).map {
        ($0 * weightLow + $1 * weightHigh) / (weightLow + weightHigh)
      }
    }
    return .init(
      key: low.key, track: low.track, speechMs: low.speechMs + high.speechMs, centroid: centroid)
  }
}
