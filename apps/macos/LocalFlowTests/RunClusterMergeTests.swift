import XCTest

@testable import LocalFlow

/// Run clusters of one voice that the forward-only reconciler split are merged again
/// on their centroids once every window is done; distinct voices and other tracks are
/// left alone.
final class RunClusterMergeTests: XCTestCase {
  private func unit(_ angle: Double) -> [Double] { [cos(angle), sin(angle), 0] }

  func testVersionNamesTheConfiguration() {
    XCTAssertEqual(RunClusterMerge.version, "merge_cos0.70_v1")
    XCTAssertEqual(RunClusterMerge.mergeSimilarity, DiarizationConstants.reconcileSimilarity)
  }

  func testDistinctVoicesAreLeftAlone() {
    let clusters = [
      RunClusterMerge.Cluster(key: 0, track: .system, speechMs: 600_000, centroid: unit(0)),
      RunClusterMerge.Cluster(key: 1, track: .system, speechMs: 300_000, centroid: unit(1.0)),
      RunClusterMerge.Cluster(key: 2, track: .microphone, speechMs: 700_000, centroid: unit(0)),
    ]
    let result = RunClusterMerge.apply(clusters)
    XCTAssertEqual(result.folds, [:])
    XCTAssertEqual(result.merges, [])
    XCTAssertEqual(result.clusters, clusters)
  }

  func testOneVoicePerWindowCollapsesIntoTheFirstCluster() {
    // The 2026-09-21 meeting's system track: one remote voice, a new run cluster per
    // window at cosine 0.95–0.99 to each other, and a 4 s fragment at 0.85.
    let voice = (0..<6).map { index in
      RunClusterMerge.Cluster(
        key: index * 2, track: .system, speechMs: 400_000, centroid: unit(Double(index) * 0.05))
    }
    let fragment = RunClusterMerge.Cluster(
      key: 1, track: .system, speechMs: 4_000, centroid: unit(0.55))
    let local = RunClusterMerge.Cluster(
      key: 20, track: .microphone, speechMs: 700_000, centroid: unit(0))
    let result = RunClusterMerge.apply(voice + [fragment, local])
    XCTAssertEqual(result.folds, [1: 0, 2: 0, 4: 0, 6: 0, 8: 0, 10: 0])
    XCTAssertEqual(result.clusters.map(\.key), [0, 20])
    XCTAssertEqual(result.clusters[0].speechMs, 2_404_000)
    XCTAssertEqual(result.clusters[1], local)
    XCTAssertEqual(result.merges.count, 6)
    XCTAssertTrue(result.merges.allSatisfy { $0.similarity >= RunClusterMerge.mergeSimilarity })
  }

  func testChainsResolveToTheSurvivorAndTheCentroidIsSpeechWeighted() throws {
    // 1 is at τ to 0 (cos 0.5 = 0.88) and 2 is at τ to 1 (cos 0.55 = 0.85) but not to 0.
    // 1 joins 0 first, and the combined centroid, dominated by 0's speech, is then
    // too far from 2 (cos ≈ 0.54) for 2 to follow.
    let clusters = [
      RunClusterMerge.Cluster(key: 0, track: .system, speechMs: 900_000, centroid: unit(0)),
      RunClusterMerge.Cluster(key: 1, track: .system, speechMs: 100_000, centroid: unit(0.5)),
      RunClusterMerge.Cluster(key: 2, track: .system, speechMs: 100_000, centroid: unit(1.05)),
    ]
    let result = RunClusterMerge.apply(clusters)
    XCTAssertEqual(result.merges.map { [$0.key, $0.into] }, [[1, 0]])
    XCTAssertEqual(result.folds, [1: 0])
    XCTAssertEqual(result.clusters.map(\.key), [0, 2])
    let merged = result.clusters[0]
    XCTAssertEqual(merged.speechMs, 1_000_000)
    let expected = zip(unit(0), unit(0.5)).map { ($0 * 900_000 + $1 * 100_000) / 1_000_000 }
    for (value, target) in zip(try XCTUnwrap(merged.centroid), expected) {
      XCTAssertEqual(value, target, accuracy: 1e-9)
    }
  }

  func testAChainFollowsItsSurvivor() {
    // 5 joins 3 first (closest), then 3 joins 0: 5's fold points at 0.
    let clusters = [
      RunClusterMerge.Cluster(key: 0, track: .system, speechMs: 100_000, centroid: unit(0)),
      RunClusterMerge.Cluster(key: 3, track: .system, speechMs: 100_000, centroid: unit(0.4)),
      RunClusterMerge.Cluster(key: 5, track: .system, speechMs: 100_000, centroid: unit(0.5)),
    ]
    let result = RunClusterMerge.apply(clusters)
    XCTAssertEqual(result.merges.map { [$0.key, $0.into] }, [[5, 3], [3, 0]])
    XCTAssertEqual(result.folds, [3: 0, 5: 0])
    XCTAssertEqual(result.clusters.map(\.key), [0])
  }

  func testClustersWithoutACentroidNeverMerge() {
    let clusters = [
      RunClusterMerge.Cluster(key: 0, track: .system, speechMs: 100_000, centroid: nil),
      RunClusterMerge.Cluster(key: 1, track: .system, speechMs: 100_000, centroid: unit(0)),
    ]
    XCTAssertEqual(RunClusterMerge.apply(clusters).folds, [:])
  }

  func testDeterministic() {
    let clusters = (0..<8).map { index -> RunClusterMerge.Cluster in
      let track: MeetingTrackKind = index % 2 == 0 ? .system : .microphone
      return RunClusterMerge.Cluster(
        key: index, track: track, speechMs: Int64(1_000 * (index + 1)),
        centroid: unit(Double(index) * 0.3))
    }
    XCTAssertEqual(RunClusterMerge.apply(clusters), RunClusterMerge.apply(clusters))
  }
}
