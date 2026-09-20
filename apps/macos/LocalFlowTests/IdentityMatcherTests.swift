import XCTest

@testable import LocalFlow

/// `tiers_v1` (research R6) at every threshold edge, with the provisional WeSpeaker values.
final class IdentityMatcherTests: XCTestCase {
  private let thresholds = IdentificationTestSupport.thresholds
  private let alice = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
  private let bob = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

  /// A profile of `count` samples whose cosine with `unit(axis: 0)` is `cosine`.
  private func profile(_ id: UUID, cosine: Float, count: Int = 3, local: Bool = false)
    -> CandidateProfile
  {
    CandidateProfile(
      id: id,
      samples: (0..<count).map { VoiceVectors.related(axis: 0, other: 10 + $0, cosine: cosine) },
      isLocalUser: local)
  }

  private func query(seconds: Int64 = 8) -> [QueryRegion] {
    [QueryRegion(vector: VoiceVectors.unit(axis: 0), weightMs: seconds * 1_000)]
  }

  func testHighScoreWithMarginAndSupportIsRecognizedAtTheEdge() {
    let decision = IdentityMatcher.decide(
      query: query(),
      profiles: [profile(alice, cosine: thresholds.high), profile(bob, cosine: 0.3)],
      rejected: [], thresholds: thresholds)
    XCTAssertEqual(decision.state, .recognized)
    XCTAssertEqual(decision.best?.knownSpeakerID, alice)
    XCTAssertEqual(decision.best?.tier, .recognized)
    XCTAssertEqual(decision.best?.reasons, [])
    XCTAssertEqual(decision.best?.supportCount, 3)
    XCTAssertNil(decision.second)
    XCTAssertEqual(decision.candidates.count, 2)
    let other = decision.candidates.first { $0.knownSpeakerID == bob }
    XCTAssertEqual(other?.tier, .below)
    XCTAssertEqual(other?.reasons, [.belowMedium])
  }

  func testMarginBelowDeltaGivesPossibleWithTheRunnerUp() {
    let decision = IdentityMatcher.decide(
      query: query(), profiles: [profile(alice, cosine: 0.82), profile(bob, cosine: 0.81)],
      rejected: [], thresholds: thresholds)
    XCTAssertEqual(decision.state, .possible)
    XCTAssertEqual(decision.best?.knownSpeakerID, alice)
    XCTAssertEqual(decision.best?.reasons, [.margin])
    XCTAssertEqual(decision.second?.knownSpeakerID, bob)
    XCTAssertEqual(decision.second?.tier, .possible)
    // A gap of δ or more is enough.
    let apart = IdentityMatcher.decide(
      query: query(),
      profiles: [profile(alice, cosine: 0.92), profile(bob, cosine: 0.80)],
      rejected: [], thresholds: thresholds)
    XCTAssertEqual(apart.state, .recognized)
    XCTAssertNil(apart.second)
  }

  func testSupportBelowTwoGivesPossible() {
    let decision = IdentityMatcher.decide(
      query: query(), profiles: [profile(alice, cosine: 0.9, count: 1)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(decision.state, .possible)
    XCTAssertEqual(decision.best?.reasons, [.support])
    XCTAssertEqual(decision.best?.supportCount, 1)
  }

  func testShortQueryAudioGivesAtMostPossible() {
    let decision = IdentityMatcher.decide(
      query: query(seconds: 5), profiles: [profile(alice, cosine: 0.95)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(decision.state, .possible)
    XCTAssertEqual(decision.best?.reasons, [.minSpeech])
    let enough = IdentityMatcher.decide(
      query: query(seconds: 6), profiles: [profile(alice, cosine: 0.95)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(enough.state, .recognized)
  }

  func testBelowMediumIsUnknownAndTheNearestCandidateIsNeverSurfaced() {
    let decision = IdentityMatcher.decide(
      query: query(), profiles: [profile(alice, cosine: thresholds.medium - 0.01)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(decision.state, .unknown)
    XCTAssertNil(decision.best)
    XCTAssertNil(decision.second)
    XCTAssertEqual(decision.candidates.map(\.tier), [.below])
    XCTAssertEqual(decision.candidates.map(\.reasons), [[.belowMedium]])
    let atMedium = IdentityMatcher.decide(
      query: query(), profiles: [profile(alice, cosine: thresholds.medium)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(atMedium.state, .possible)
  }

  func testScoreIsTheTopThreeMeanWeightedByRegionDuration() {
    // Five samples: three at 0.9 and two at 0.1; the top-3 mean is 0.9.
    let samples =
      (0..<3).map { VoiceVectors.related(axis: 0, other: 10 + $0, cosine: 0.9) }
      + (0..<2).map { VoiceVectors.related(axis: 0, other: 20 + $0, cosine: 0.1) }
    let profile = CandidateProfile(id: alice, samples: samples, isLocalUser: false)
    let regions = [
      QueryRegion(vector: VoiceVectors.unit(axis: 0), weightMs: 6_000),
      QueryRegion(vector: VoiceVectors.unit(axis: 40), weightMs: 2_000),  // cosine 0
    ]
    let decision = IdentityMatcher.decide(
      query: regions, profiles: [profile], rejected: [], thresholds: thresholds)
    XCTAssertEqual(decision.best?.score ?? 0, 0.9 * 0.75, accuracy: 1e-4)
    XCTAssertEqual(decision.best?.sampleCount, 5)
    XCTAssertEqual(decision.best?.supportCount, 3)
  }

  func testRejectedAndDisabledProfilesAreExcludedButRecorded() {
    var disabled = profile(bob, cosine: 0.95)
    disabled.recognitionEnabled = false
    let decision = IdentityMatcher.decide(
      query: query(), profiles: [profile(alice, cosine: 0.95), disabled], rejected: [alice],
      thresholds: thresholds)
    XCTAssertEqual(decision.state, .unknown)
    XCTAssertNil(decision.best)
    let rejected = decision.candidates.first { $0.knownSpeakerID == alice }
    XCTAssertEqual(rejected?.reasons, [.rejected])
    XCTAssertEqual(rejected?.tier, .below)
    let off = decision.candidates.first { $0.knownSpeakerID == bob }
    XCTAssertEqual(off?.reasons, [.disabled])
  }

  func testTheLocalUserProfileIsEvidenceOnly() {
    let local = profile(bob, cosine: 0.99, local: true)
    let decision = IdentityMatcher.decide(
      query: query(), profiles: [local, profile(alice, cosine: 0.8)], rejected: [],
      thresholds: thresholds)
    XCTAssertEqual(decision.state, .recognized)
    XCTAssertEqual(decision.best?.knownSpeakerID, alice)
    let evidence = decision.candidates.first { $0.knownSpeakerID == bob }
    XCTAssertEqual(evidence?.tier, .localEvidence)
    XCTAssertEqual(evidence?.reasons, [])
    let alone = IdentityMatcher.decide(
      query: query(), profiles: [local], rejected: [], thresholds: thresholds)
    XCTAssertEqual(alone.state, .unknown)
    XCTAssertNil(alone.best)
  }

  func testNoProfilesOrNoQueryIsUnknownAndOutputIsDeterministic() {
    XCTAssertEqual(
      IdentityMatcher.decide(query: query(), profiles: [], rejected: [], thresholds: thresholds),
      .unknown)
    let empty = IdentityMatcher.decide(
      query: [], profiles: [profile(alice, cosine: 0.9)], rejected: [], thresholds: thresholds)
    XCTAssertEqual(empty.state, .unknown)
    let profiles = [profile(alice, cosine: 0.7), profile(bob, cosine: 0.65)]
    let first = IdentityMatcher.decide(
      query: query(), profiles: profiles, rejected: [], thresholds: thresholds)
    let second = IdentityMatcher.decide(
      query: query(), profiles: profiles.reversed(), rejected: [], thresholds: thresholds)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.candidates.count, 2)
  }
}
