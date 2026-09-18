import XCTest

@testable import LocalFlow

final class LiveChunkPlannerTests: XCTestCase {
  func testBothGeometriesCoverEightHoursAndOneSampleTail() {
    for configuration in LiveChunkPlanner.Configuration.allCases {
      var planner = LiveChunkPlanner(configuration: configuration, stretchSequence: 3)
      planner.streamEnd = 8 * 3_600 * 16_000 + 1
      var covered = 0
      var index = 0
      while let window = planner.nextWindow(tail: true) {
        XCTAssertEqual(window.sampleStart, covered)
        XCTAssertEqual(window.index, index)
        XCTAssertEqual(window.windowIndex, index)
        XCTAssertEqual(window.startSample, Int64(covered))
        XCTAssertEqual(window.stretchSequence, 3)
        XCTAssertEqual(window.isTail, window.sampleCount < configuration.windowSamples)
        XCTAssertLessThanOrEqual(window.sampleCount, configuration.windowSamples)
        covered += window.sampleCount
        index += 1
      }
      XCTAssertEqual(covered, planner.streamEnd)
      var nextStretch = LiveChunkPlanner(configuration: configuration, stretchSequence: 4)
      nextStretch.streamEnd = configuration.windowSamples
      let first = nextStretch.nextWindow()
      XCTAssertEqual(first?.windowIndex, 0)
      XCTAssertEqual(first?.startSample, 0)
      XCTAssertEqual(first?.stretchSequence, 4)
      XCTAssertEqual(first?.isTail, false)
    }
    XCTAssertEqual(LiveChunkPlanner.version, "live_contiguous_96000_v1")
  }

  func testSkipPreservesPrefixAndDoesNotCrossGap() {
    var planner = LiveChunkPlanner()
    planner.streamEnd = 200_001
    let prefix = planner.skip(10_000..<110_000)
    XCTAssertEqual(prefix?.sampleCount, 10_000)
    XCTAssertEqual(prefix?.isTail, true)
    XCTAssertEqual(prefix?.stretchSequence, 1)
    let tail = planner.nextWindow(tail: true)
    XCTAssertEqual(tail?.sampleStart, 110_000)
    XCTAssertEqual(tail?.sampleCount, 90_001)
    XCTAssertEqual(tail?.isTail, true)
    XCTAssertEqual(tail?.windowIndex, 1)
    XCTAssertEqual(
      (prefix?.sampleCount ?? 0) + 100_000 + (tail?.sampleCount ?? 0), planner.streamEnd)
  }
}
