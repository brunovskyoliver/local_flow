import XCTest

@testable import LocalFlow

final class WindowClusterReconcilerTests: XCTestCase {
  private func axis(_ index: Int) -> [Float] {
    DiarizationScripts.centroid(axis: index, dimension: 8)
  }

  /// A unit vector at `similarity` cosine to axis 0, leaning toward axis 1.
  private func toward(_ similarity: Float) -> [Float] {
    var value = [Float](repeating: 0, count: 8)
    value[0] = similarity
    value[1] = (1 - similarity * similarity).squareRoot()
    return value
  }

  private func window(_ clusters: [Int: [Float]?], seconds: Double = 10) -> DiarizationWindowResult
  {
    var turns: [DiarizationWindowResult.Turn] = []
    var centroids: [Int: [Float]] = [:]
    for (cluster, centroid) in clusters {
      turns.append(.init(cluster: cluster, startSeconds: 0, endSeconds: seconds, quality: nil))
      if let centroid { centroids[cluster] = centroid }
    }
    return .init(turns: turns, centroids: centroids)
  }

  func testMatchedWhenSimilarAndClearOfTheNextBest() {
    var reconciler = WindowClusterReconciler()
    var key = 0
    let first = reconciler.reconcile(window([0: axis(0), 1: axis(2)]), nextKey: &key)
    XCTAssertEqual(
      first.created,
      [.init(key: 0, reconciliation: .confident), .init(key: 1, reconciliation: .confident)])
    // Window cluster ids are window-local: 5 is the speaker first seen as 0.
    let second = reconciler.reconcile(window([5: toward(0.71)]), nextKey: &key)
    XCTAssertEqual(second.keys, [5: 0])
    XCTAssertEqual(second.matched, 1)
    XCTAssertTrue(second.created.isEmpty)
    XCTAssertEqual(key, 2)
  }

  func testNoPairAtThresholdIsANewConfidentCluster() {
    var reconciler = WindowClusterReconciler()
    var key = 0
    _ = reconciler.reconcile(window([0: axis(0)]), nextKey: &key)
    let result = reconciler.reconcile(window([0: toward(0.69)]), nextKey: &key)
    XCTAssertEqual(result.keys, [0: 1])
    XCTAssertEqual(result.created, [.init(key: 1, reconciliation: .confident)])
    XCTAssertEqual(result.matched, 0)
  }

  func testPairAtThresholdWithSmallMarginIsANewUncertainCluster() {
    var reconciler = WindowClusterReconciler()
    var key = 0
    // Two run clusters at cosine 0.5: axis 0 and a vector between axes 0 and 1.
    _ = reconciler.reconcile(window([0: axis(0)]), nextKey: &key)
    _ = reconciler.reconcile(window([0: toward(0.5)]), nextKey: &key)
    XCTAssertEqual(reconciler.clusterCount, 2)
    // Similar to both (0.83 and 0.90): a pair at τ, margin under 0.10.
    var between = [Float](repeating: 0, count: 8)
    between[0] = 0.9
    between[1] = 0.6
    let result = reconciler.reconcile(window([3: between]), nextKey: &key)
    XCTAssertEqual(result.keys, [3: 2])
    XCTAssertEqual(result.created, [.init(key: 2, reconciliation: .uncertain)])
    XCTAssertEqual(result.uncertain, 1)
    XCTAssertEqual(result.matched, 0)
  }

  func testClusterWithoutCentroidIsNewUncertainAndNeverMatched() {
    var reconciler = WindowClusterReconciler()
    var key = 0
    let first = reconciler.reconcile(window([0: nil]), nextKey: &key)
    XCTAssertEqual(first.created, [.init(key: 0, reconciliation: .uncertain)])
    let second = reconciler.reconcile(window([0: axis(0)]), nextKey: &key)
    XCTAssertEqual(second.created, [.init(key: 1, reconciliation: .confident)])
  }

  func testGreedyOneToOneTiesByWindowClusterThenRunKey() {
    var reconciler = WindowClusterReconciler()
    var key = 0
    _ = reconciler.reconcile(window([0: axis(0), 1: axis(1)]), nextKey: &key)
    // Both window clusters are identical to run cluster 0; cluster 2 wins the tie.
    let result = reconciler.reconcile(window([2: axis(0), 4: axis(0)]), nextKey: &key)
    XCTAssertEqual(result.keys[2], 0)
    XCTAssertEqual(result.keys[4], 2)
    // Cluster 4's only pair at τ was taken: it is new and marked uncertain.
    XCTAssertEqual(result.created, [.init(key: 2, reconciliation: .uncertain)])
  }

  func testTracksReconcileSeparately() {
    var system = WindowClusterReconciler()
    var microphone = WindowClusterReconciler()
    var key = 0
    _ = system.reconcile(window([0: axis(0)]), nextKey: &key)
    let local = microphone.reconcile(window([0: axis(0)]), nextKey: &key)
    // Same voice vector, other track: a new run cluster with a run-wide unique key.
    XCTAssertEqual(local.created, [.init(key: 1, reconciliation: .confident)])
  }

  func testRunCentroidsAreDurationWeighted() {
    // Same two windows, opposite durations. A probe on the far side of axis 0 matches
    // only the centroid dominated by the long axis-0 window.
    var probe = [Float](repeating: 0, count: 8)
    probe[0] = 0.8
    probe[1] = -0.6
    func matches(axisSeconds: Double, towardSeconds: Double) -> Bool {
      var reconciler = WindowClusterReconciler()
      var key = 0
      _ = reconciler.reconcile(window([0: axis(0)], seconds: axisSeconds), nextKey: &key)
      _ = reconciler.reconcile(window([0: toward(0.75)], seconds: towardSeconds), nextKey: &key)
      return reconciler.reconcile(window([0: probe]), nextKey: &key).matched == 1
    }
    XCTAssertTrue(matches(axisSeconds: 90, towardSeconds: 10))
    XCTAssertFalse(matches(axisSeconds: 10, towardSeconds: 90))
  }

  func testCapacityOverflowLeavesClustersUnmapped() {
    var reconciler = WindowClusterReconciler(capacity: 2)
    var key = 0
    let result = reconciler.reconcile(
      window([0: axis(0), 1: axis(1), 2: axis(2)]), nextKey: &key)
    XCTAssertEqual(result.keys, [0: 0, 1: 1])
    XCTAssertEqual(result.overflowClusters, 1)
    XCTAssertEqual(WindowClusterReconciler().capacity, 64)
  }

  func testDeterministic() {
    func run() -> [WindowClusterReconciler.Result] {
      var reconciler = WindowClusterReconciler()
      var key = 0
      return [
        reconciler.reconcile(window([0: axis(0), 1: axis(1), 2: nil]), nextKey: &key),
        reconciler.reconcile(window([0: axis(1), 1: toward(0.9), 3: axis(3)]), nextKey: &key),
      ]
    }
    XCTAssertEqual(run(), run())
  }
}
