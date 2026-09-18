import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingAnalysisTapTests: XCTestCase {
  func testCopiesDropsWholeBlocksAndDetachClosesAdmission() throws {
    let tap = try MeetingAnalysisTap(
      kind: .microphone, format: .init(sampleRate: 48_000, channels: 1))
    let block = try XCTUnwrap(tap.ring.makeBlock())
    block.frameLength = 4_096
    block.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
    for _ in 0..<33 { tap.push(block) }
    XCTAssertEqual(tap.ring.occupancy, 32)
    XCTAssertEqual(tap.droppedFrames, 4_096)
    block.floatChannelData![0][0] = 0.75
    let copy = try XCTUnwrap(tap.ring.makeBlock())
    XCTAssertEqual(tap.ring.pop(into: copy), 4_096)
    XCTAssertEqual(copy.floatChannelData![0][0], 0.25)
    tap.detach()
    tap.detach()
    tap.push(block)
    XCTAssertEqual(tap.ring.occupancy, 31)
  }
}
