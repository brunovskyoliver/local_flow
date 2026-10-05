import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class PhoneMeetingCoordinatorTests: XCTestCase {
  private var harness: MeetingHarness!
  private var meetings: PhoneMeetingCoordinator { harness.coordinator }

  override func setUp() async throws {
    harness = try MeetingHarness()
    meetings.recover()
    await meetings.waitForRecovery()
  }

  override func tearDown() async throws {
    harness = nil
  }

  func testRecordsAnIPhoneMeetingThroughEveryState() async throws {
    await meetings.start()
    let id = try XCTUnwrap(meetings.meetingID)
    XCTAssertEqual(harness.activity.calls, [.end, .end, .request(.recording)])
    try await harness.assertState(id, .recording)
    // Rows `preparing` inserted: one microphone track and a transcription row.
    let tracks = try harness.rows(
      "SELECT type FROM meeting_tracks WHERE meeting_id = ?", [id.uuidString])
    XCTAssertEqual(tracks.map { $0["type"] as String }, ["microphone"])
    let transcription = try harness.rows(
      "SELECT state FROM meeting_transcriptions WHERE meeting_id = ?", [id.uuidString])
    XCTAssertEqual(transcription.first?["state"] as String?, "not_requested")
    let origin = try harness.rows("SELECT origin FROM meetings WHERE id = ?", [id.uuidString])
    XCTAssertEqual(origin.first?["origin"] as String?, "iphone")
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await meetings.stop()
    XCTAssertNil(meetings.meetingID)
    XCTAssertEqual(harness.activity.calls.suffix(2), [.update(.stopping), .end])
    let stored = try await harness.store.meeting(id: id)
    XCTAssertEqual(stored?.state, .completed)
    XCTAssertNotNil(stored?.startedAt)
    XCTAssertNotNil(stored?.completedAt)
    let detail = try await harness.store.detail(id: id)
    XCTAssertEqual(detail?.tracks.first?.track.health, .finalized)
    XCTAssertGreaterThan(detail?.tracks.first?.track.totalDurationMs ?? 0, 800)
  }

  func testLowStorageWarnsOnTheRecordingScreenWhenItDropsMidMeeting() async throws {
    await meetings.start()
    XCTAssertNil(meetings.lowStorageWarning)
    XCTAssertNil(meetings.notice)
    harness.engine.feed(seconds: 1, into: harness.recorder)
    harness.free = 900_000_000
    await harness.recorder.heartbeat()
    XCTAssertTrue(meetings.isRecording)
    XCTAssertEqual(meetings.lowStorageWarning, PhoneMeetingCoordinator.lowStorage)
    harness.free = 5_000_000_000
    await harness.recorder.heartbeat()
    XCTAssertNil(meetings.lowStorageWarning, "space came back")
    harness.free = 900_000_000
    await harness.recorder.heartbeat()
    await meetings.stop()
    XCTAssertNil(meetings.lowStorageWarning, "only while recording")
  }

  func testStopsAtTheFourHourCap() async throws {
    harness.makeRecorder(limits: .init(maximumRecordedMs: 500))
    await meetings.start()
    let id = try XCTUnwrap(meetings.meetingID)
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.recorder.heartbeat()
    XCTAssertNil(meetings.meetingID)
    XCTAssertEqual(meetings.notice, PhoneMeetingCoordinator.stoppedAtLimit)
    XCTAssertEqual(harness.activity.calls.last, .end)
    try await harness.assertState(id, .completed)
  }

  func testNoLiveActivityMeansNoRecording() async throws {
    harness.activity.areActivitiesEnabled = false
    await meetings.start()
    XCTAssertNil(meetings.meetingID)
    XCTAssertEqual(meetings.notice, PhoneMeetingCoordinator.liveActivitiesOff)
    XCTAssertFalse(harness.engine.running)
    XCTAssertTrue(try harness.rows("SELECT id FROM meetings").isEmpty)
  }

  func testStartRefusedWhileADictationIsTranscribing() async throws {
    let controller = harness.controller
    await harness.phone.runtime.set(loadDelay: .milliseconds(500))
    await controller.open(origin: .app)
    let request = UUID()
    XCTAssertEqual(controller.start(requestID: request, source: .app), .started)
    let stopping = Task { await controller.stop(requestID: request) }
    while controller.session?.state != .finishing { await Task.yield() }
    XCTAssertEqual(meetings.startBlockedReason, PhoneMeetingCoordinator.dictationBusy)
    await meetings.start()
    XCTAssertNil(meetings.meetingID)
    XCTAssertEqual(meetings.notice, PhoneMeetingCoordinator.dictationBusy)
    XCTAssertTrue(try harness.rows("SELECT id FROM meetings").isEmpty)
    await stopping.value
  }

  func testStartingEndsAReadyDictationSession() async throws {
    let controller = harness.controller
    await controller.open(origin: .app)
    XCTAssertEqual(controller.session?.state, .ready)
    await meetings.start()
    XCTAssertNotNil(meetings.meetingID)
    XCTAssertEqual(controller.session?.endReason, .userEnded)
    XCTAssertFalse(harness.phone.capture.engineRunning)
    XCTAssertEqual(meetings.notice, PhoneMeetingCoordinator.endedDictation)
    await meetings.stop()
  }

  func testDictationRefusedWhileAMeetingRecords() async throws {
    let controller = harness.controller
    await meetings.start()
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertEqual(controller.session?.endReason, .meetingRecording)
    XCTAssertFalse(harness.phone.capture.engineRunning)
    await meetings.stop()
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.state, .ready)
    controller.end(.userEnded)
  }

  func testLiveActivityStopEndsTheMeeting() async throws {
    await meetings.start()
    let id = try XCTUnwrap(meetings.meetingID)
    MeetingIntentHandlers.current = meetings
    defer { MeetingIntentHandlers.current = nil }
    _ = try await StopMeetingIntent().perform()
    XCTAssertNil(meetings.meetingID)
    try await harness.assertState(id, .completed)
  }
}
