import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class MeetingRecoveryTests: XCTestCase {
  func testACrashedRecordingIsRecoveredUpToTheLastCompleteFrame() async throws {
    let harness = try MeetingHarness()
    harness.coordinator.recover()
    await harness.coordinator.waitForRecovery()
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: 2, into: harness.recorder)
    await harness.recorder.heartbeat()
    let open = try XCTUnwrap(harness.segments(id).first)
    let part = try XCTUnwrap(harness.root.resolve(relativePath: open["relative_path"]))
    let kept = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int)
    // The process dies mid-frame: a torn ADTS header is the last thing on disk.
    let handle = try FileHandle(forWritingTo: part)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0xFF, 0xF1, 0x4C, 0x80]))
    try handle.close()

    // Next launch.
    harness.makeRecorder()
    harness.coordinator.recover()
    await harness.coordinator.waitForRecovery()

    let stored = try await harness.store.meeting(id: id)
    XCTAssertEqual(stored?.state, .interrupted)
    XCTAssertEqual(stored?.failureReason, .notRunningAtLastState)
    XCTAssertEqual(harness.coordinator.notice, "1 meeting recovered")
    let row = try XCTUnwrap(harness.segments(id).first)
    XCTAssertEqual(row["state"] as String, "finalized")
    XCTAssertEqual(row["close_reason"] as String?, "recovered")
    let path: String = row["relative_path"]
    XCTAssertTrue(path.hasSuffix(".aac"))
    let url = try XCTUnwrap(harness.root.resolve(relativePath: path))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, kept)
    XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    XCTAssertGreaterThan(row["duration_ms"] as Int64, 1_800)
    // A new meeting can start after recovery.
    await harness.coordinator.start()
    XCTAssertNotNil(harness.coordinator.meetingID)
    await harness.coordinator.stop()
  }
}
