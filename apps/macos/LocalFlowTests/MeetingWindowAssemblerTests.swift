import XCTest

@testable import LocalFlow

final class MeetingWindowAssemblerTests: XCTestCase {
  func testContiguousWindowsAreAdjacentAndHistoryIsBounded() {
    let geometries =
      LiveChunkPlanner.Configuration.allCases.map { ($0.rawValue, $0.windowSamples) }
      + [("contiguous_fixed239360_preserve_v1", 239_360)]
    for (geometry, count) in geometries {
      var assembler = MeetingWindowAssembler(geometry: geometry)
      for index in 0..<100 {
        let result = assembler.append(
          window: .init(
            sequence: index, sampleStart: index * count,
            sampleCount: count, paddedSampleCount: count, text: "word \(index)", tokens: nil))
        XCTAssertEqual(result.text, "word \(index)")
        XCTAssertLessThanOrEqual(assembler.retainedWindowCount, 2)
        XCTAssertEqual(result.seam?.decision, index == 0 ? nil : "adjacent")
        XCTAssertEqual(result.seam?.discardedPrefixBytes ?? 0, 0)
      }
      XCTAssertEqual(
        assembler.assemblyVersion, "\(TranscriptAssembler.version)/\(geometry)")
    }
  }
}
