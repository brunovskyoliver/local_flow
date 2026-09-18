import AVFoundation
import XCTest

@testable import LocalFlow

@MainActor
final class TrackPlaybackTests: XCTestCase {
  private var base: URL!
  private var root: MeetingStorageRoot!
  private let meeting = UUID()
  private let trackID = UUID()

  override func setUp() async throws {
    base = try makeMeetingTestRoot()
    root = MeetingStorageRoot(url: base.appendingPathComponent("Meetings", isDirectory: true))
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

  private func segment(
    _ sequence: Int, state: SegmentState, durationMs: Int64, reason: MeetingFailureReason? = nil
  )
    -> MeetingSegment
  {
    var segment = MeetingSegment(
      id: UUID(), trackID: trackID, sequence: sequence,
      relativePath: SegmentHandle.relativePath(
        meetingID: meeting, kind: .microphone, sequence: sequence, open: state == .open),
      startOffsetMs: 0, startedAt: 0, hostStartNs: 0, openReason: sequence == 1 ? .start : .resume)
    segment.state = state
    segment.durationMs = durationMs
    segment.failureReason = reason
    return segment
  }

  private func track(_ segments: [MeetingSegment]) -> MeetingTrackDetail {
    MeetingTrackDetail(
      track: MeetingTrack(
        id: trackID, meetingID: meeting, kind: .microphone, channelCount: 1, bitrate: 64_000),
      segments: segments)
  }

  func testLoadQueuesFinalizedSegmentsInOrderAndListsSkippedOnes() throws {
    let first = try ADTSFixtures.encodedTone(blocks: 12)
    let second = try ADTSFixtures.encodedTone(blocks: 6)
    let s1 = segment(1, state: .finalized, durationMs: 1_024)
    let s2 = segment(2, state: .unrecoverable, durationMs: 0, reason: .unrecoverableMedia)
    let s3 = segment(3, state: .finalized, durationMs: 512)
    let s4 = segment(4, state: .open, durationMs: 0)
    try ADTSFixtures.write(first, to: root.resolve(relativePath: s1.relativePath)!)
    try ADTSFixtures.write(second, to: root.resolve(relativePath: s3.relativePath)!)
    let controller = TrackPlaybackController()
    controller.load(track: track([s3, s1, s4, s2]), root: root)
    XCTAssertEqual(controller.queued.map(\.segment.sequence), [1, 3])
    XCTAssertEqual(controller.queued.map(\.offsetMs), [0, 1_024])
    XCTAssertEqual(controller.durationMs, 1_536)
    XCTAssertEqual(
      controller.skipped,
      [
        "Segment 2: Not playable: This track could not be made playable. The file was kept.",
        "Segment 4: Not playable: still open",
      ])
    XCTAssertTrue(controller.hasPlayableAudio)
    XCTAssertNil(controller.notice)
    XCTAssertEqual(controller.positionText, "0:00 / 0:01")
  }

  func testPlayPauseStopUpdateStateAndStopResetsPosition() async throws {
    let bytes = try ADTSFixtures.encodedTone(blocks: 24)
    let s1 = segment(1, state: .finalized, durationMs: 2_048)
    try ADTSFixtures.write(bytes, to: root.resolve(relativePath: s1.relativePath)!)
    let controller = TrackPlaybackController()
    controller.load(track: track([s1]), root: root)
    controller.play()
    XCTAssertTrue(controller.isPlaying)
    try await Task.sleep(nanoseconds: 700_000_000)
    controller.pause()
    XCTAssertFalse(controller.isPlaying)
    XCTAssertGreaterThan(controller.positionMs, 0, "position is start_offset + current time")
    controller.play()
    XCTAssertTrue(controller.isPlaying)
    controller.stop()
    XCTAssertFalse(controller.isPlaying)
    XCTAssertEqual(controller.positionMs, 0)
    controller.play()
    XCTAssertTrue(controller.isPlaying, "playable again after stop")
    controller.unload()
    XCTAssertFalse(controller.isPlaying)
  }

  func testFilesAreOpenedReadOnlyAndByteIdenticalAfterPlayback() async throws {
    let first = try ADTSFixtures.encodedTone(blocks: 6)
    let second = try ADTSFixtures.encodedTone(blocks: 6)
    let s1 = segment(1, state: .finalized, durationMs: 512)
    let s2 = segment(2, state: .finalized, durationMs: 512)
    let url1 = root.resolve(relativePath: s1.relativePath)!
    let url2 = root.resolve(relativePath: s2.relativePath)!
    try ADTSFixtures.write(first, to: url1)
    try ADTSFixtures.write(second, to: url2)
    let before = [try sha256(of: url1), try sha256(of: url2)]
    XCTAssertEqual(
      TrackPlaybackController.assetOptions.keys.sorted(),
      [AVURLAssetPreferPreciseDurationAndTimingKey])
    let controller = TrackPlaybackController()
    controller.load(track: track([s1, s2]), root: root)
    XCTAssertEqual(controller.openedURLs, [url1, url2])
    controller.play()
    try await Task.sleep(nanoseconds: 1_500_000_000)
    controller.stop()
    XCTAssertEqual([try sha256(of: url1), try sha256(of: url2)], before)
    // No AVAssetWriter or file handle for writing exists in the controller.
    var source = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { source.deleteLastPathComponent() }
    let text = try String(
      contentsOf: source.appendingPathComponent(
        "LocalFlow/Features/Meetings/TrackPlaybackController.swift"),
      encoding: .utf8)
    XCTAssertFalse(text.contains("AVAssetWriter"))
    XCTAssertFalse(text.contains("forWriting"))
    XCTAssertFalse(text.contains("forUpdating"))
  }

  func testTrackWithNoPlayableSegmentsReportsNoPlayableAudio() {
    let controller = TrackPlaybackController()
    controller.load(
      track: track([segment(1, state: .unrecoverable, durationMs: 0, reason: .fileMissing)]),
      root: root)
    XCTAssertFalse(controller.hasPlayableAudio)
    XCTAssertEqual(controller.notice, "No playable audio")
    XCTAssertEqual(controller.skipped.count, 1)
    controller.play()
    XCTAssertFalse(controller.isPlaying)
  }
}
