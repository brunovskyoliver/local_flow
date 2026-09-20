import XCTest

@testable import LocalFlow

final class SpeakerAlignerTests: XCTestCase {
  private typealias Turn = SpeakerAligner.Turn

  private func turn(_ speaker: Int?, _ start: Int64, _ end: Int64) -> Turn {
    Turn(speaker: speaker, startMs: start, endMs: end)
  }

  /// Segment [0, 1000) against each table row.
  private func assign(
    _ turns: [Turn], segment: SpeakerAligner.Segment = .init(startMs: 0, endMs: 1_000)
  )
    -> SpeakerAligner.Assignment
  {
    SpeakerAligner.assign(segment, turns: turns)
  }

  func testVersionMatchesThePipelineString() {
    XCTAssertEqual(SpeakerAligner.version, "align_dom0.60_ratio2_ovl0.20_v1")
    XCTAssertEqual(
      DiarizationPipelineVersion.current,
      "offline_vbx_community1_nonexcl+win600s_v1+xwin_cos_greedy_v1+align_dom0.60_ratio2_ovl0.20_v1"
    )
  }

  func testTable() {
    struct Row {
      let name: String
      let turns: [Turn]
      let kind: SpeakerAssignmentKind
      let speaker: Int?
      let top: Int?
      let second: Int?
      let c1: Double
      let c2: Double
    }
    let rows: [Row] = [
      .init(
        name: "dominant", turns: [turn(3, 0, 900), turn(4, 900, 1_000)], kind: .speaker,
        speaker: 3, top: 3, second: 4, c1: 0.9, c2: 0.1),
      .init(
        name: "two voices overlap", turns: [turn(1, 0, 600), turn(2, 300, 1_000)],
        kind: .ambiguous, speaker: nil, top: 2, second: 1, c1: 0.7, c2: 0.6),
      .init(
        name: "silence", turns: [], kind: .unknown, speaker: nil, top: nil, second: nil, c1: 0,
        c2: 0),
      .init(
        name: "too little speech", turns: [turn(1, 0, 500)], kind: .unknown, speaker: nil, top: 1,
        second: nil, c1: 0.5, c2: 0),
      .init(
        name: "overflow counts toward no speaker", turns: [turn(nil, 0, 1_000), turn(5, 0, 300)],
        kind: .unknown, speaker: nil, top: 5, second: nil, c1: 0.3, c2: 0),
      .init(
        name: "overflow beside a dominant speaker",
        turns: [turn(nil, 0, 1_000), turn(5, 0, 700)], kind: .speaker, speaker: 5, top: 5,
        second: nil, c1: 0.7, c2: 0),
      .init(
        name: "turn outside the segment", turns: [turn(1, 1_000, 2_000), turn(2, -500, 0)],
        kind: .unknown, speaker: nil, top: nil, second: nil, c1: 0, c2: 0),
    ]
    for row in rows {
      let result = assign(row.turns)
      XCTAssertEqual(result.kind, row.kind, row.name)
      XCTAssertEqual(result.speaker, row.speaker, row.name)
      XCTAssertEqual(result.top, row.top, row.name)
      XCTAssertEqual(result.second, row.second, row.name)
      XCTAssertEqual(result.topCoverage, row.c1, accuracy: 1e-12, row.name)
      XCTAssertEqual(result.secondCoverage, row.c2, accuracy: 1e-12, row.name)
    }
  }

  func testExactThresholdEdges() {
    // c1 = 0.60 exactly is a speaker; one millisecond less is not.
    XCTAssertEqual(assign([turn(1, 0, 600)]).kind, .speaker)
    XCTAssertEqual(assign([turn(1, 0, 599)]).kind, .unknown)
    // c1 = 2 × c2 exactly is a speaker; c2 one millisecond more is ambiguous.
    XCTAssertEqual(assign([turn(1, 0, 600), turn(2, 700, 1_000)]).kind, .speaker)
    XCTAssertEqual(assign([turn(1, 0, 600), turn(2, 699, 1_000)]).kind, .ambiguous)
    // Below the dominance rule, c2 = 0.20 exactly is ambiguous; less is unknown.
    XCTAssertEqual(assign([turn(1, 0, 500), turn(2, 500, 700)]).kind, .ambiguous)
    XCTAssertEqual(assign([turn(1, 0, 500), turn(2, 500, 699)]).kind, .unknown)
    // Edges hold for odd durations, where decimal thresholds are not whole milliseconds.
    let odd = SpeakerAligner.Segment(startMs: 0, endMs: 7)
    XCTAssertEqual(assign([turn(1, 0, 5)], segment: odd).kind, .speaker)  // 0.714
    XCTAssertEqual(assign([turn(1, 0, 4)], segment: odd).kind, .unknown)  // 0.571
  }

  func testTiesGoToTheLowerSpeakerKey() {
    let result = assign([turn(9, 0, 500), turn(2, 500, 1_000)])
    XCTAssertEqual(result.top, 2)
    XCTAssertEqual(result.second, 9)
    XCTAssertEqual(result.kind, .ambiguous)
    let reversed = assign([turn(2, 500, 1_000), turn(9, 0, 500)])
    XCTAssertEqual(reversed, result, "Input order never changes the result")
  }

  func testOverlappingTurnsOfOneSpeakerCountAsTheirUnion() {
    let result = assign([turn(1, 0, 400), turn(1, 200, 700), turn(1, 100, 300)])
    XCTAssertEqual(result.topCoverage, 0.7, accuracy: 1e-12)
    XCTAssertEqual(result.kind, .speaker)
    let nested = assign([turn(1, 0, 500), turn(1, 100, 200), turn(2, 500, 1_000)])
    XCTAssertEqual(nested.topCoverage, 0.5, accuracy: 1e-12)
    XCTAssertEqual(nested.kind, .ambiguous)
  }

  func testRepeatedRunsAreIdenticalAndLeaveSegmentsUnchanged() {
    let segments = (0..<200).map {
      SpeakerAligner.Segment(startMs: Int64($0) * 700, endMs: Int64($0) * 700 + 900)
    }
    var generator = SystemRandomNumberGenerator()
    let turns = (0..<400).map { _ -> Turn in
      let start = Int64.random(in: 0..<140_000, using: &generator)
      return turn(
        Int.random(in: 0..<5, using: &generator), start,
        start + Int64.random(in: 1..<3_000, using: &generator))
    }
    let copy = segments
    let first = SpeakerAligner.align(segments, turns: turns)
    let second = SpeakerAligner.align(segments, turns: turns.reversed())
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, segments.count)
    XCTAssertEqual(segments, copy)
    for result in first {
      XCTAssertEqual(result.kind == .speaker, result.speaker != nil)
      XCTAssertTrue((0...1).contains(result.topCoverage))
      XCTAssertTrue((0...1).contains(result.secondCoverage))
      XCTAssertGreaterThanOrEqual(result.topCoverage, result.secondCoverage)
    }
  }
}
