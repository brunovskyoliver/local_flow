import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class MeetingRecorderTests: XCTestCase {
  /// 100 AAC frames, about 2.13 s, so rotation shows without 6 minutes of audio.
  private static let shortSegment = MeetingRecorder.Limits(segmentFrames: 100)
  private static let shortMs: Int64 = 100 * 1_024 * 1_000 / 48_000
  private var harness: MeetingHarness!

  override func setUp() async throws {
    harness = try MeetingHarness(limits: Self.shortSegment)
  }

  override func tearDown() async throws {
    harness = nil
  }

  private func recording() async throws -> UUID {
    let (meeting, track) = try await harness.prepared()
    try await harness.recorder.start(meetingID: meeting, trackID: track)
    return meeting
  }

  func testDefaultsAreTheSpecifiedLimits() {
    let limits = MeetingRecorder.Limits()
    XCTAssertEqual(limits.segmentFrames * 1_024, 360 * 48_000)
    XCTAssertEqual(limits.heartbeat, .seconds(5))
    XCTAssertEqual(limits.warningFreeBytes, 1_000_000_000)
    XCTAssertEqual(limits.stopFreeBytes, 200_000_000)
    XCTAssertEqual(limits.maximumRecordedMs, 4 * 3_600_000)
  }

  func testSegmentsRotateAtAnExactFrameCount() async throws {
    let meeting = try await recording()
    harness.engine.feed(seconds: 5, into: harness.recorder)
    await harness.recorder.heartbeat()
    let rows = try harness.segments(meeting)
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows.map { $0["open_reason"] as String }, ["start", "rotated", "rotated"])
    XCTAssertEqual(rows.map { $0["close_reason"] as String? }, ["rotated", "rotated", nil])
    XCTAssertEqual(rows.map { $0["state"] as String }, ["finalized", "finalized", "open"])
    XCTAssertEqual(
      rows.map { $0["start_offset_ms"] as Int64 }, [0, Self.shortMs, 2 * Self.shortMs])
    for row in rows.prefix(2) {
      XCTAssertEqual(row["duration_ms"] as Int64, Self.shortMs)
      let path: String = row["relative_path"]
      XCTAssertTrue(path.hasSuffix(".aac"))
      let url = try XCTUnwrap(harness.root.resolve(relativePath: path))
      let scan = try ADTSValidator.scan(url: url)
      XCTAssertEqual(scan.completeFrames, 100)
      XCTAssertEqual(scan.trailingBytes, 0)
    }
    await harness.recorder.stop()
    try await harness.assertState(meeting, .completed)
  }

  func testHeartbeatSyncsAndWritesProgress() async throws {
    harness.makeRecorder()
    let meeting = try await recording()
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.recorder.heartbeat()
    let row = try XCTUnwrap(harness.segments(meeting).first)
    XCTAssertEqual(row["state"] as String, "open")
    XCTAssertGreaterThan(row["duration_ms"] as Int64, 800)
    XCTAssertGreaterThan(row["byte_size"] as Int64, 0)
    let part = try XCTUnwrap(harness.root.resolve(relativePath: row["relative_path"]))
    XCTAssertTrue(part.path.hasSuffix(".aac.part"))
    let size = try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64
    XCTAssertEqual(size, row["byte_size"] as Int64)
    await harness.recorder.stop()
  }

  func testInterruptionPausesWithAGapAndResumes() async throws {
    harness.makeRecorder()
    let meeting = try await recording()
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.recorder.interruption(began: true)
    try await harness.assertState(meeting, .paused)
    XCTAssertTrue(harness.recorder.isPaused)
    XCTAssertFalse(harness.engine.running)
    var pauses = try harness.rows(
      "SELECT * FROM meeting_pauses WHERE meeting_id = ?", [meeting.uuidString])
    XCTAssertEqual(pauses.count, 1)
    XCTAssertNil(pauses[0]["ended_at"] as Int64?)
    harness.clock.advance(ms: 30_000)
    await harness.recorder.interruption(began: false)
    try await harness.assertState(meeting, .recording)
    XCTAssertTrue(harness.engine.running)
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.recorder.stop()
    pauses = try harness.rows(
      "SELECT * FROM meeting_pauses WHERE meeting_id = ?", [meeting.uuidString])
    XCTAssertEqual(pauses[0]["closed_by"] as String?, "resume")
    XCTAssertEqual(
      (pauses[0]["ended_at"] as Int64) - (pauses[0]["started_at"] as Int64), 30_000)
    let rows = try harness.segments(meeting)
    XCTAssertEqual(rows.map { $0["open_reason"] as String }, ["start", "resume"])
    XCTAssertEqual(rows.map { $0["close_reason"] as String? }, ["pause", "stop"])
    let stored = try await harness.store.meeting(id: meeting)
    XCTAssertEqual(stored?.state, .completed)
    XCTAssertEqual(stored?.wallClockMs, 30_000)
    XCTAssertEqual(stored?.recordedMs, 0)
  }

  func testRouteChangeRotatesWithDeviceChanged() async throws {
    harness.makeRecorder()
    let meeting = try await recording()
    harness.engine.feed(seconds: 1, into: harness.recorder)
    harness.engine.inputName = "AirPods Pro"
    harness.engine.format = MeetingSourceFormat(sampleRate: 16_000, channels: 1)
    await harness.recorder.routeChanged()
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.recorder.stop()
    let rows = try harness.segments(meeting)
    XCTAssertEqual(rows.map { $0["open_reason"] as String }, ["start", "device_changed"])
    XCTAssertEqual(rows.map { $0["close_reason"] as String? }, ["device_changed", "stop"])
    XCTAssertEqual(
      rows.map { $0["input_device_name"] as String? }, ["iPhone Microphone", "AirPods Pro"])
    XCTAssertEqual(rows.map { $0["state"] as String }, ["finalized", "finalized"])
    XCTAssertGreaterThan(rows[1]["duration_ms"] as Int64, 800)
    try await harness.assertState(meeting, .completed)
  }

  func testStorageFloorStopsAndSaves() async throws {
    harness.makeRecorder()
    var ended: [MeetingRecorder.End] = []
    harness.recorder.onEnded = { ended.append($0) }
    let meeting = try await recording()
    harness.engine.feed(seconds: 1, into: harness.recorder)
    harness.free = 900_000_000
    await harness.recorder.heartbeat()
    XCTAssertTrue(harness.recorder.lowStorage)
    try await harness.assertState(meeting, .recording)
    harness.free = 150_000_000
    await harness.recorder.heartbeat()
    XCTAssertEqual(ended, [.storageFull])
    XCTAssertFalse(harness.recorder.isRecording)
    XCTAssertTrue(harness.engine.deactivated)
    try await harness.assertState(meeting, .completed)
    let row = try XCTUnwrap(harness.segments(meeting).first)
    XCTAssertEqual(row["state"] as String, "finalized")
    XCTAssertEqual(row["close_reason"] as String?, "stop")
    XCTAssertGreaterThan(row["duration_ms"] as Int64, 800)
  }
}
