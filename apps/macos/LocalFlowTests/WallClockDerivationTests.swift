import XCTest

@testable import LocalFlow

final class WallClockDerivationTests: XCTestCase {
  func testPauseOffsetsMicrophonePreferenceSystemFallbackAndTruncation() {
    let id = UUID()
    let micID = UUID()
    let systemID = UUID()
    func segment(_ sequence: Int, trackID: UUID, at: Int64) -> MeetingSegment {
      .init(
        id: UUID(), trackID: trackID, sequence: sequence, relativePath: "track.aac",
        startOffsetMs: Int64(sequence - 1) * 1_000, durationMs: 1_000, startedAt: at,
        hostStartNs: 0, openReason: .start)
    }
    let meeting = Meeting(
      id: id, state: .completed, createdAt: 100_000,
      wallClockMs: 30_000, recordedMs: 3_000, updatedAt: 130_000, revision: 0)
    let detail = MeetingDetail(
      meeting: meeting,
      tracks: [
        .init(
          track: .init(
            id: micID, meetingID: id, kind: .microphone, channelCount: 1, bitrate: 64_000),
          segments: [
            segment(1, trackID: micID, at: 100_000), segment(3, trackID: micID, at: 120_000),
          ]),
        .init(
          track: .init(
            id: systemID, meetingID: id, kind: .system, channelCount: 2, bitrate: 96_000),
          segments: [
            segment(1, trackID: systemID, at: 100_050), segment(2, trackID: systemID, at: 110_000),
          ]),
      ], pauses: [], notes: .init(meetingID: id, text: "", updatedAt: 0, revision: 0), outcomes: [])
    let descriptor = AnalysisStreamDescriptor(
      source: .livePCMTee,
      stretches: [.init(sequence: 1, lengthMs: 1_000, tracks: .both)], stretchesTruncated: true)
    let clock = WallClockDerivation(detail: detail, descriptor: descriptor)
    XCTAssertEqual(clock.wallClock(startMs: 500), 100_500)
    XCTAssertEqual(clock.wallClock(startMs: 1_500), 110_500)
    XCTAssertEqual(clock.wallClock(startMs: 2_500), 120_500)
    XCTAssertNil(clock.wallClock(startMs: 3_000))
    XCTAssertNil(clock.wallClock(startMs: -1))
    let missing = AnalysisStreamDescriptor(
      source: .livePCMTee,
      stretches: [.init(sequence: 4, lengthMs: 1_000, tracks: .both)])
    XCTAssertNil(WallClockDerivation(detail: detail, descriptor: missing).wallClock(startMs: 500))
  }
}
