import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingSampleRingTests: XCTestCase {
  func testCapacityIsPreallocatedAndFixed() throws {
    let ring = try MeetingSampleRing(channels: 8, sampleRate: 48_000)
    XCTAssertEqual(ring.capacity, 32)
    XCTAssertEqual(MeetingSampleRing.slotCapacity, 32)
    XCTAssertEqual(MeetingSampleRing.frameCapacity, 4_096)
    XCTAssertEqual(MeetingSampleRing.channelCapacity, 8)
    XCTAssertEqual(ring.occupancy, 0)
    XCTAssertEqual(ring.highWater, 0)
    let block = try XCTUnwrap(ring.makeBlock())
    XCTAssertEqual(block.frameCapacity, 4_096)
    XCTAssertEqual(block.format.channelCount, 8)
    let samples = [Float](repeating: 0.5, count: 4_096 * 8)
    for _ in 0..<10 { XCTAssertTrue(ring.push(interleaved: samples, frames: 4_096)) }
    XCTAssertEqual(ring.capacity, 32, "pushing never changes the preallocated capacity")
    XCTAssertEqual(ring.occupancy, 10)
    XCTAssertThrowsError(try MeetingSampleRing(channels: 9, sampleRate: 48_000))
  }

  func testOverflowDropsWholePushCountsFramesAndKeepsAdmitting() throws {
    let ring = try MeetingSampleRing(channels: 1, sampleRate: 48_000)
    let samples = [Float](repeating: 0.1, count: 4_096)
    for _ in 0..<32 { XCTAssertTrue(ring.push(interleaved: samples, frames: 4_096)) }
    XCTAssertFalse(ring.push(interleaved: samples, frames: 4_096), "dropped whole")
    XCTAssertEqual(ring.droppedFrames, 4_096)
    XCTAssertFalse(ring.push(interleaved: [Float](repeating: 0, count: 100), frames: 100))
    XCTAssertEqual(ring.droppedFrames, 4_196)
    XCTAssertEqual(ring.occupancy, 32)
    XCTAssertFalse(ring.formatFailure, "no latch in meeting mode")
    let block = try XCTUnwrap(ring.makeBlock())
    XCTAssertEqual(ring.pop(into: block), 4_096)
    XCTAssertTrue(ring.push(interleaved: samples, frames: 4_096), "admission stays open")
    XCTAssertEqual(ring.highWater, 32)
  }

  func testDrainPopsAtMostThirtyTwoSlotsPerCall() throws {
    let ring = try MeetingSampleRing(channels: 2, sampleRate: 44_100)
    let samples = [Float](repeating: 0.2, count: 2_048 * 2)
    // Small pushes each take one slot; 40 pushes fill 32 and drop 8.
    for _ in 0..<40 { _ = ring.push(interleaved: samples, frames: 2_048) }
    XCTAssertEqual(ring.droppedFrames, 8 * 2_048)
    let block = try XCTUnwrap(ring.makeBlock())
    var popped = 0
    let count = ring.drain(maxSlots: 64, into: block) { popped += Int($0.frameLength) }
    XCTAssertEqual(count, 32)
    XCTAssertEqual(popped, 32 * 2_048)
    XCTAssertEqual(ring.drain(into: block) { _ in }, 0)
    XCTAssertEqual(ring.highWater, 32)
  }

  /// The dictation ring keeps its latching policy: the meeting flag is per ring.
  func testDefaultRingStillLatchesOverflow() throws {
    let staging = try AudioCaptureStaging(channels: 1, sampleRate: 48_000)
    let samples = [Float](repeating: 0.1, count: 4_096)
    for _ in 0..<32 { XCTAssertTrue(staging.pushForTesting(samples, frames: 4_096)) }
    XCTAssertFalse(staging.pushForTesting(samples, frames: 4_096))
    XCTAssertEqual(staging.failure, .overflow)
    XCTAssertEqual(LFAudioRingDroppedFrames(staging.pointer), 0)
  }
}
