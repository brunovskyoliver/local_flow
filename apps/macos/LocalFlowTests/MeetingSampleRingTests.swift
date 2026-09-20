import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingSampleRingTests: XCTestCase {
  func testPreservingTimelinePlacesLongGapBeforeLaterAudioInEveryChannel() throws {
    for channels in [1, 2, 8] {
      let ring = try MeetingSampleRing(channels: channels, sampleRate: 44_100)
      let before = [Float](repeating: 0.25, count: 17 * channels)
      for _ in 0..<32 { XCTAssertTrue(ring.push(interleaved: before, frames: 17)) }
      XCTAssertFalse(
        ring.push(interleaved: [Float](repeating: 0.9, count: 9_000 * channels), frames: 9_000))
      let block = try XCTUnwrap(ring.makeBlock())
      for _ in 0..<32 {
        XCTAssertEqual(ring.popPreservingTimeline(into: block), 17)
        for channel in 0..<channels {
          XCTAssertEqual(block.floatChannelData![channel][0], 0.25)
        }
      }
      XCTAssertEqual(ring.popPreservingTimeline(into: block), 0, "open tail is not guessed")
      let after = (0..<(23 * channels)).map { Float($0 % channels + 1) / 10 }
      XCTAssertTrue(ring.push(interleaved: after, frames: 23))
      var silence = 0
      for expected in [4_096, 4_096, 808] {
        XCTAssertEqual(ring.popPreservingTimeline(into: block), UInt32(expected))
        silence += expected
        for channel in 0..<channels {
          XCTAssertTrue((0..<expected).allSatisfy { block.floatChannelData![channel][$0] == 0 })
        }
        XCTAssertEqual(ring.occupancy, 1, "later audio stays queued until its original position")
      }
      XCTAssertEqual(silence, 9_000)
      XCTAssertEqual(ring.popPreservingTimeline(into: block), 23)
      for channel in 0..<channels {
        XCTAssertEqual(block.floatChannelData![channel][22], Float(channel + 1) / 10)
      }
      ring.closeAndJoin()
      XCTAssertEqual(ring.popPreservingTimeline(into: block), 0)
      XCTAssertEqual(ring.droppedFrames, 9_000)
      XCTAssertEqual(ring.highWater, 32)
    }
  }

  func testPreservingTimelineIncludesConsecutiveTerminalDropsOnlyAfterClose() throws {
    let ring = try MeetingSampleRing(channels: 2, sampleRate: 48_000)
    for _ in 0..<32 {
      XCTAssertTrue(ring.push(interleaved: [0.25, -0.25], frames: 1))
    }
    for frames in [5_000, 100] {
      XCTAssertFalse(
        ring.push(interleaved: [Float](repeating: 0.5, count: frames * 2), frames: frames))
    }
    let block = try XCTUnwrap(ring.makeBlock())
    var total = 0
    for _ in 0..<32 { total += Int(ring.popPreservingTimeline(into: block)) }
    XCTAssertEqual(total, 32)
    XCTAssertEqual(ring.popPreservingTimeline(into: block), 0)
    ring.closeAndJoin()
    for expected in [4_096, 1_004] {
      XCTAssertEqual(ring.popPreservingTimeline(into: block), UInt32(expected))
      total += expected
      for channel in 0..<2 {
        XCTAssertTrue((0..<expected).allSatisfy { block.floatChannelData![channel][$0] == 0 })
      }
    }
    XCTAssertEqual(total, 5_132)
    XCTAssertEqual(ring.popPreservingTimeline(into: block), 0)
    XCTAssertEqual(ring.popPreservingTimeline(into: block), 0, "terminal gap is emitted once")
    XCTAssertEqual(ring.droppedFrames, 5_100)
  }

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
