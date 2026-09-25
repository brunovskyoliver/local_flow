import XCTest

@testable import LocalFlow

/// `regions_v1` (research R4) at every edge: eligibility, trims, limits, spread, audio
/// checks, labels and determinism.
final class VoiceRegionSelectorTests: XCTestCase {
  private let root = UUID()
  private let other = UUID()
  private let run = UUID()

  private func turn(
    _ speaker: UUID?, _ start: Int64, _ end: Int64, track: MeetingTrackKind = .system,
    quality: Double? = nil, overlapped: Bool = false, id: Int64 = 0
  ) -> SpeakerTurn {
    SpeakerTurn(
      id: id, runID: run, speakerID: speaker, track: track, startMs: start, endMs: end,
      engineQuality: quality, overlapped: overlapped)
  }

  func testOnlyCleanSingleSpeakerTurnsBecomeRegionsTrimmedAtBothEnds() {
    let turns = [
      turn(root, 0, 5_000),  // 4.6 s after trims: eligible
      turn(root, 10_000, 13_300),  // 2.9 s after trims: too short
      turn(root, 20_000, 30_000, overlapped: true),  // flagged by diarization
      turn(root, 40_000, 50_000),  // intersects the other speaker's microphone turn
      turn(root, 60_000, 70_000, quality: 0.4),  // engine quality below 0.5
      turn(root, 80_000, 90_000, quality: 0.5),  // at the floor: allowed
      turn(root, 100_000, 130_000),  // cut to 20 s
    ]
    let others = [turn(other, 45_000, 46_000, track: .microphone)]
    let regions = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: others, meetingLengthMs: 130_000, limits: .enroll)
    XCTAssertEqual(regions.map(\.startMs), [200, 80_200, 100_200])
    XCTAssertEqual(regions.map(\.endMs), [4_800, 89_800, 120_200])
    XCTAssertEqual(regions.map(\.engineQuality), [nil, 0.5, nil])
    XCTAssertEqual(regions.map(\.track), [.system, .system, .system])
  }

  func testAbsentQualityIsAllowedAndOverflowTurnsAreSkipped() {
    let regions = VoiceRegionSelector.select(
      rootTurns: [turn(root, 0, 10_000), turn(nil, 20_000, 30_000)], otherTurns: [],
      meetingLengthMs: 30_000, limits: .query)
    XCTAssertEqual(regions.count, 1)
  }

  func testSpreadTakesTheLongestEligibleRegionPerSpanFirst() {
    // 100 s meeting, five 20 s spans; two candidates per span with a longer one in each.
    var turns: [SpeakerTurn] = []
    for span in 0..<5 {
      let base = Int64(span) * 20_000
      turns.append(turn(root, base, base + 4_000, id: Int64(span * 2)))  // 3.6 s
      turns.append(turn(root, base + 10_000, base + 16_000, id: Int64(span * 2 + 1)))  // 5.6 s
    }
    let regions = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: [], meetingLengthMs: 100_000, limits: .enroll)
    XCTAssertEqual(regions.count, 5)
    XCTAssertEqual(regions.map(\.startMs), [10_200, 30_200, 50_200, 70_200, 90_200])
    // Query limits: four regions, the last span's longest is dropped, output in start order.
    let query = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: [], meetingLengthMs: 100_000, limits: .query)
    XCTAssertEqual(query.map(\.startMs), [10_200, 30_200, 50_200, 70_200])
  }

  func testRemainingLongestRegionsFillUpAfterTheSpread() {
    let turns = [
      turn(root, 0, 12_000, id: 1), turn(root, 13_000, 20_000, id: 2),
      turn(root, 21_000, 25_000, id: 3),
    ]
    let regions = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: [], meetingLengthMs: 25_000, limits: .enroll)
    XCTAssertEqual(regions.map(\.startMs), [200, 13_200, 21_200])
  }

  func testTotalAudioLimitCutsTheLastRegionAndStopsBelowTheMinimum() {
    let turns = (0..<6).map { index in
      turn(root, Int64(index) * 25_000, Int64(index) * 25_000 + 20_400, id: Int64(index))
    }
    let enroll = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: [], meetingLengthMs: 150_000, limits: .enroll)
    XCTAssertEqual(enroll.reduce(0) { $0 + $1.durationMs }, 100_000)
    XCTAssertEqual(enroll.count, 5)
    let query = VoiceRegionSelector.select(
      rootTurns: turns, otherTurns: [], meetingLengthMs: 150_000, limits: .query)
    XCTAssertEqual(query.reduce(0) { $0 + $1.durationMs }, 60_000)
    XCTAssertEqual(query.count, 3)
  }

  func testAudioCheckRejectsClippedAndQuietRegions() {
    let count = VoiceRegionRequest.minSamples
    var clean = (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    XCTAssertNil(VoiceRegionSelector.audioCheck(clean))
    // 0.1% of 48,000 is 48 samples: 48 at the threshold pass, 49 fail.
    for index in 0..<48 { clean[index] = 0.99 }
    XCTAssertNil(VoiceRegionSelector.audioCheck(clean))
    clean[48] = -0.995
    XCTAssertEqual(VoiceRegionSelector.audioCheck(clean), .clipped)
    let quiet = [Float](repeating: 0.004, count: count)  // −48 dBFS
    XCTAssertEqual(VoiceRegionSelector.audioCheck(quiet), .tooQuiet)
    let audible = [Float](repeating: 0.01, count: count)  // −40 dBFS
    XCTAssertNil(VoiceRegionSelector.audioCheck(audible))
    XCTAssertEqual(VoiceRegionSelector.audioCheck([]), .tooQuiet)
  }

  func testQualityLabelAndScore() {
    XCTAssertEqual(VoiceRegionSelector.qualityLabel(durationMs: 6_000, engineQuality: nil), .good)
    XCTAssertEqual(VoiceRegionSelector.qualityLabel(durationMs: 6_000, engineQuality: 0.7), .good)
    XCTAssertEqual(VoiceRegionSelector.qualityLabel(durationMs: 5_999, engineQuality: 0.9), .fair)
    XCTAssertEqual(VoiceRegionSelector.qualityLabel(durationMs: 20_000, engineQuality: 0.69), .fair)
    let low = VoiceRegionSelector.qualityScore(durationMs: 3_000, engineQuality: 0.5)
    let high = VoiceRegionSelector.qualityScore(durationMs: 12_000, engineQuality: 1)
    XCTAssertLessThan(low, high)
    XCTAssertEqual(high, 1, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(low, 0)
  }

  func testIdenticalInputGivesIdenticalOutputAndNoEligibleRegionGivesNone() {
    let turns = (0..<20).map { index in
      turn(
        root, Int64(index) * 7_000, Int64(index) * 7_000 + 5_000 + Int64(index % 3) * 500,
        id: Int64(index))
    }
    let first = VoiceRegionSelector.select(
      rootTurns: turns.shuffled(), otherTurns: [], meetingLengthMs: 140_000, limits: .enroll)
    let second = VoiceRegionSelector.select(
      rootTurns: turns.reversed(), otherTurns: [], meetingLengthMs: 140_000, limits: .enroll)
    XCTAssertEqual(first, second)
    let none = VoiceRegionSelector.select(
      rootTurns: [turn(root, 0, 3_000)], otherTurns: [], meetingLengthMs: 3_000, limits: .enroll)
    XCTAssertEqual(none, [])
  }

  /// The sorted sweep answers every clash test exactly like scanning every other turn,
  /// with and without excluded speakers, for long, short, nested and speakerless turns.
  func testSortedClashSweepMatchesAFullScan() {
    var generator = SeededGenerator(seed: 7)
    let speakers = (0..<6).map { _ in UUID() }
    for _ in 0..<50 {
      let count = Int.random(in: 0..<120, using: &generator)
      let others = (0..<count).map { index -> SpeakerTurn in
        let start = Int64.random(in: 0..<600_000, using: &generator)
        let long = Int.random(in: 0..<10, using: &generator) == 0
        let length = Int64.random(in: 1..<(long ? 200_000 : 8_000), using: &generator)
        let speaker = Int.random(in: 0..<8, using: &generator)
        return turn(
          speaker < speakers.count ? speakers[speaker] : nil, start, start + length,
          id: Int64(index))
      }
      let excluded = Set(speakers.prefix(Int.random(in: 0..<3, using: &generator)))
      let sweep = VoiceRegionSelector.OtherTurns(others)
      for probe in 0..<60 {
        let start = Int64.random(in: 0..<650_000, using: &generator)
        let length = Int64.random(in: 1..<30_000, using: &generator)
        let speaker = speakers[Int.random(in: 0..<speakers.count, using: &generator)]
        let root = turn(speaker, start, start + length, id: Int64(10_000 + probe))
        let scanned = others.contains { other in
          other.speakerID != root.speakerID && other.startMs < root.endMs
            && other.endMs > root.startMs
        }
        XCTAssertEqual(sweep.clashes(with: root), scanned)
        let scannedExcluding = others.contains { other in
          other.speakerID != root.speakerID && other.startMs < root.endMs
            && other.endMs > root.startMs
            && !(other.speakerID.map(excluded.contains) ?? false)
        }
        XCTAssertEqual(sweep.clashes(with: root, excluding: excluded), scannedExcluding)
      }
    }
  }

  /// Regions for many roots from one grouping equal the per-root filters they replace.
  func testRegionsForAllRootsMatchPerRootFiltering() {
    var generator = SeededGenerator(seed: 11)
    let speakers = (0..<8).map { _ in UUID() }
    let roots = [
      RegionExtractor.Root(id: speakers[0], members: [speakers[1]], source: .remote),
      RegionExtractor.Root(id: speakers[2], members: [], source: .remote),
      RegionExtractor.Root(id: speakers[3], members: [speakers[4], speakers[5]], source: .remote),
      RegionExtractor.Root(id: speakers[6], members: [], source: .local),
    ]
    var start: Int64 = 0
    let turns = (0..<400).map { index -> SpeakerTurn in
      start += Int64.random(in: 0..<30_000, using: &generator)
      let length = Int64.random(in: 500..<25_000, using: &generator)
      let speaker = speakers[Int.random(in: 0..<speakers.count, using: &generator)]
      let quality: Double? =
        Bool.random(using: &generator) ? nil : Double.random(in: 0.3...1, using: &generator)
      return turn(
        speaker, start, start + length,
        track: Bool.random(using: &generator) ? .system : .microphone, quality: quality,
        overlapped: Int.random(in: 0..<10, using: &generator) == 0, id: Int64(index))
    }
    var found = 0
    for track in [MeetingTrackKind?.none, .system, .microphone] {
      for limits in [VoiceRegionSelector.Limits.query, .enroll] {
        let grouped = RegionExtractor.regions(
          for: roots, turns: turns, track: track, lengthMs: start, limits: limits)
        XCTAssertEqual(grouped.map(\.root), roots.map(\.id))
        for (root, entry) in zip(roots, grouped) {
          let own = turns.filter {
            guard let speaker = $0.speakerID, root.clusters.contains(speaker) else { return false }
            return track == nil || $0.track == track
          }
          let others = turns.filter { $0.speakerID.map { !root.clusters.contains($0) } ?? false }
          let expected = VoiceRegionSelector.select(
            rootTurns: own, otherTurns: others, meetingLengthMs: start, limits: limits)
          XCTAssertEqual(entry.regions, expected)
          found += expected.count
        }
      }
    }
    XCTAssertGreaterThan(found, 0, "the fixture yields regions to compare")
  }
}

/// SplitMix64: a reproducible sequence for randomized equivalence tests.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
