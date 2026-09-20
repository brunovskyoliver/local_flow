import XCTest

@testable import LocalFlow

/// Clusters with almost no speech fold into their track's closest substantial cluster
/// or lose their speaker; they never become a "Speaker N" of their own.
final class MinorClusterFoldTests: XCTestCase {
  private func unit(_ angle: Double) -> [Double] { [cos(angle), sin(angle), 0] }

  func testVersionNamesTheConfiguration() {
    XCTAssertEqual(MinorClusterFold.version, "minor10s_5pct_cos0.60_v1")
  }

  func testSubstantialClustersAreLeftAlone() {
    let clusters = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 1_675_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 60_000, centroid: unit(1.2)),
      MinorClusterFold.Cluster(key: 2, track: .microphone, speechMs: 1_465_000, centroid: unit(0)),
    ]
    XCTAssertEqual(MinorClusterFold.decide(clusters), [])
  }

  func testAMinorClusterFoldsIntoTheClosestSubstantialClusterOfItsTrack() {
    let clusters = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 1_675_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 6_418, centroid: unit(0.6)),
      MinorClusterFold.Cluster(key: 2, track: .system, speechMs: 2_360, centroid: unit(1.5)),
      // The microphone's own voice is closer to cluster 2 but on another track.
      MinorClusterFold.Cluster(
        key: 3, track: .microphone, speechMs: 1_465_000, centroid: unit(1.5)),
    ]
    let choices = MinorClusterFold.decide(clusters)
    XCTAssertEqual(choices.map(\.key), [1, 2])
    XCTAssertEqual(choices[0].decision, .fold(into: 0))
    XCTAssertEqual(try XCTUnwrap(choices[0].similarity), cos(0.6), accuracy: 1e-6)
    // cos(1.5) ≈ 0.07: under the fold similarity, so the turns lose their speaker.
    XCTAssertEqual(choices[1].decision, .detach)
    XCTAssertEqual(try XCTUnwrap(choices[1].similarity), cos(1.5), accuracy: 1e-6)
  }

  func testWithoutACentroidOrATargetTheClusterDetaches() {
    let noCentroid = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 300_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 1_000, centroid: nil),
    ]
    XCTAssertEqual(
      MinorClusterFold.decide(noCentroid), [.init(key: 1, decision: .detach, similarity: nil)])
    let noTarget = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 300_000, centroid: nil),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 1_000, centroid: unit(0)),
    ]
    XCTAssertEqual(
      MinorClusterFold.decide(noTarget), [.init(key: 1, decision: .detach, similarity: nil)])
  }

  func testTheRelativeBoundKeepsEveryoneInAShortMeeting() {
    // 5% of the 100 s cluster is 5 s: a 6 s cluster is a speaker here, and 4 s is not.
    let clusters = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 100_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 6_000, centroid: unit(0.1)),
      MinorClusterFold.Cluster(key: 2, track: .system, speechMs: 4_000, centroid: unit(0.1)),
    ]
    XCTAssertEqual(MinorClusterFold.decide(clusters).map(\.key), [2])
    // Many equal voices: none is under 5% of the largest, so all stay.
    let equal = (0..<65).map {
      MinorClusterFold.Cluster(key: $0, track: .system, speechMs: 5, centroid: unit(Double($0)))
    }
    XCTAssertEqual(MinorClusterFold.decide(equal), [])
  }

  func testTheAbsoluteBoundKeepsAThirdVoiceInALongMeeting() {
    // 5% of an hour is 3 min; the absolute 10 s bound applies instead.
    let clusters = [
      MinorClusterFold.Cluster(key: 0, track: .system, speechMs: 3_600_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .system, speechMs: 10_000, centroid: unit(0.1)),
      MinorClusterFold.Cluster(key: 2, track: .system, speechMs: 9_999, centroid: unit(0.1)),
    ]
    XCTAssertEqual(MinorClusterFold.decide(clusters).map(\.key), [2])
  }

  func testFoldsNeverChainAndTiesGoToTheLowerKey() {
    let clusters = [
      MinorClusterFold.Cluster(key: 0, track: .microphone, speechMs: 500_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 1, track: .microphone, speechMs: 500_000, centroid: unit(0)),
      MinorClusterFold.Cluster(key: 2, track: .microphone, speechMs: 2_000, centroid: unit(0.2)),
      MinorClusterFold.Cluster(key: 3, track: .microphone, speechMs: 3_000, centroid: unit(0.2)),
    ]
    let choices = MinorClusterFold.decide(clusters)
    XCTAssertEqual(choices.map(\.decision), [.fold(into: 0), .fold(into: 0)])
  }
}
