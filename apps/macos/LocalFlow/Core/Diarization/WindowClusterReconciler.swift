import Foundation

/// `xwin_cos_greedy_v1` (research R4). Maps one track's window clusters onto the run
/// clusters seen so far in that track. Pure; run-cluster centroids live in memory for
/// the run only and are never persisted (FR-036). One instance per track, so clusters
/// from different tracks are never compared.
struct WindowClusterReconciler: Sendable {
  static var version: String { DiarizationPipelineVersion.reconciler }

  struct NewCluster: Sendable, Equatable {
    let key: Int
    let reconciliation: SpeakerReconciliation
  }

  struct Result: Sendable, Equatable {
    /// Window cluster → run cluster key. A window cluster missing here overflowed.
    var keys: [Int: Int] = [:]
    /// Run clusters first seen in this window, in key order.
    var created: [NewCluster] = []
    var matched = 0
    var uncertain = 0
    var overflowClusters = 0
  }

  private struct RunCluster: Sendable {
    let key: Int
    /// Duration-weighted mean of the matched window centroids; nil when the cluster
    /// arrived without one.
    var centroid: [Double]?
    var weightMs: Double
  }

  let capacity: Int
  private var clusters: [RunCluster] = []

  init(capacity: Int = DiarizationConstants.clustersPerTrack) { self.capacity = capacity }

  var clusterCount: Int { clusters.count }

  /// Run-cluster centroids by key, for the minor-cluster fold at the end of the run.
  var centroids: [Int: [Double]] {
    Dictionary(
      uniqueKeysWithValues: clusters.compactMap { run in run.centroid.map { (run.key, $0) } })
  }

  /// `nextKey` is the run-wide key counter, so keys stay unique across tracks.
  mutating func reconcile(_ window: DiarizationWindowResult, nextKey: inout Int) -> Result {
    var durations: [Int: Double] = [:]
    for turn in window.turns {
      durations[turn.cluster, default: 0] += (turn.endSeconds - turn.startSeconds) * 1_000
    }
    let windowClusters = durations.keys.sorted()
    var similarity: [Int: [(key: Int, value: Double)]] = [:]
    for cluster in windowClusters {
      guard let centroid = window.centroids[cluster] else { continue }
      similarity[cluster] = clusters.compactMap { run in
        run.centroid.map { (run.key, Self.cosine(centroid, $0)) }
      }
    }
    // Pairs at τ, most similar first; ties by window cluster id, then run cluster key.
    let pairs = similarity.flatMap { cluster, values in
      values.filter { $0.value >= DiarizationConstants.reconcileSimilarity }
        .map { (cluster: cluster, key: $0.key, value: $0.value) }
    }.sorted {
      if $0.value != $1.value { return $0.value > $1.value }
      if $0.cluster != $1.cluster { return $0.cluster < $1.cluster }
      return $0.key < $1.key
    }
    var result = Result()
    var decided: [Int: SpeakerReconciliation] = [:]
    var taken: Set<Int> = []
    for pair in pairs where decided[pair.cluster] == nil && !taken.contains(pair.key) {
      let nextBest =
        similarity[pair.cluster]?.filter { $0.key != pair.key }.map(\.value).max()
        ?? -.infinity
      if pair.value - nextBest >= DiarizationConstants.reconcileMargin {
        result.keys[pair.cluster] = pair.key
        taken.insert(pair.key)
        decided[pair.cluster] = .confident
        result.matched += 1
      } else {
        // Close to more than one run cluster: never guessed into a match.
        decided[pair.cluster] = .uncertain
      }
    }
    for cluster in windowClusters where result.keys[cluster] == nil {
      let hadPair = pairs.contains { $0.cluster == cluster }
      let reconciliation: SpeakerReconciliation =
        window.centroids[cluster] == nil || hadPair ? .uncertain : .confident
      guard clusters.count < capacity else {
        result.overflowClusters += 1
        continue
      }
      let key = nextKey
      nextKey += 1
      clusters.append(.init(key: key, centroid: nil, weightMs: 0))
      result.keys[cluster] = key
      result.created.append(.init(key: key, reconciliation: reconciliation))
      if reconciliation == .uncertain { result.uncertain += 1 }
    }
    for cluster in windowClusters {
      guard let key = result.keys[cluster], let centroid = window.centroids[cluster],
        let index = clusters.firstIndex(where: { $0.key == key })
      else { continue }
      let weight = max(durations[cluster] ?? 0, 1)
      let previous = clusters[index]
      let values = centroid.map(Double.init)
      if let old = previous.centroid, old.count == values.count {
        let total = previous.weightMs + weight
        clusters[index].centroid = zip(old, values).map {
          ($0 * previous.weightMs + $1 * weight) / total
        }
        clusters[index].weightMs = total
      } else {
        clusters[index].centroid = values
        clusters[index].weightMs = weight
      }
    }
    return result
  }

  static func cosine(_ lhs: [Float], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
    var dot = 0.0
    var left = 0.0
    var right = 0.0
    for index in lhs.indices {
      let value = Double(lhs[index])
      dot += value * rhs[index]
      left += value * value
      right += rhs[index] * rhs[index]
    }
    guard left > 0, right > 0 else { return -1 }
    return dot / (left.squareRoot() * right.squareRoot())
  }
}
