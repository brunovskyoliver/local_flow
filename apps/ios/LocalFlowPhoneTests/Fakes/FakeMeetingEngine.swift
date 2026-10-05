@preconcurrency import AVFAudio
import Foundation
import GRDB
import XCTest
import os

@testable import LocalFlow
@testable import LocalFlowCore

/// A microphone without hardware: `feed` hands 48 kHz mono PCM to the recorder's tap.
@MainActor
final class FakeMeetingEngine: MeetingAudioEngine {
  var onInterruption: ((Bool) -> Void)?
  var onRouteChange: (() -> Void)?
  var inputName: String? = "iPhone Microphone"
  var permission = true
  var startFails = false
  var format = MeetingSourceFormat(sampleRate: 48_000, channels: 1)
  private(set) var running = false
  private(set) var deactivated = false
  private var deliver: (@Sendable (AVAudioPCMBuffer) -> Void)?

  func requestPermission() async -> Bool { permission }

  func prepare() throws -> MeetingSourceFormat {
    if startFails { throw PhoneAudioCapture.CaptureError.noInput }
    deactivated = false
    return format
  }

  func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
    self.deliver = deliver
    running = true
  }

  func stop(deactivate: Bool) {
    running = false
    deliver = nil
    if deactivate { deactivated = true }
  }

  /// A 440 Hz tone in 4,800-frame buffers (what the hardware tends to hand out), draining
  /// the recorder's queue every few buffers so its 64-buffer bound never drops audio.
  func feed(seconds: Double, into recorder: MeetingRecorder) {
    guard let deliver,
      let pcm = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
        channels: AVAudioChannelCount(format.channels), interleaved: false)
    else { return }
    var remaining = Int(seconds * format.sampleRate)
    var phase: Float = 0
    var sent = 0
    while remaining > 0 {
      let count = min(4_800, remaining)
      let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(count))!
      buffer.frameLength = AVAudioFrameCount(count)
      for channel in 0..<format.channels {
        for index in 0..<count {
          buffer.floatChannelData![channel][index] =
            0.3 * sin(phase + Float(index) * 2 * .pi * 440 / Float(format.sampleRate))
        }
      }
      phase += Float(count) * 2 * .pi * 440 / Float(format.sampleRate)
      deliver(buffer)
      remaining -= count
      sent += 1
      if sent % 16 == 0 { recorder.drainAudio() }
    }
    recorder.drainAudio()
  }
}

/// Settable wall clock; the heartbeat loop's sleep never returns, so tests call
/// `heartbeat()` themselves.
final class FakeMeetingClock: MeetingClock, @unchecked Sendable {
  private let time = OSAllocatedUnfairLock(initialState: Int64(1_790_000_000_000))
  var nowMilliseconds: Int64 { time.withLock { $0 } }
  var monotonicNanoseconds: UInt64 { UInt64(nowMilliseconds) * 1_000_000 }
  func advance(ms: Int64) { time.withLock { $0 += ms } }
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: .seconds(86_400))
  }
}

/// `PhoneHarness` plus a meeting store, recorder and coordinator over a temporary folder.
@MainActor
final class MeetingHarness {
  let phone: PhoneHarness
  let root: MeetingStorageRoot
  let store: MeetingStore
  let writer: FileSegmentWriter
  let engine = FakeMeetingEngine()
  let clock = FakeMeetingClock()
  let activity = FakeMeetingActivityRequester()
  let controller: SessionController
  var free: Int64 = 50_000_000_000
  private(set) var recorder: MeetingRecorder!
  private(set) var coordinator: PhoneMeetingCoordinator!

  init(limits: MeetingRecorder.Limits = .init()) throws {
    phone = try PhoneHarness()
    root = MeetingStorageRoot(
      url: phone.root.appendingPathComponent("Meetings", isDirectory: true))
    try MeetingRecorder.prepareStorage(root.url)
    store = MeetingStore(history: phone.history, root: root)
    writer = FileSegmentWriter(root: root)
    controller = phone.makeController()
    makeRecorder(limits: limits)
  }

  /// A fresh recorder and coordinator, as after a relaunch.
  func makeRecorder(limits: MeetingRecorder.Limits = .init()) {
    recorder = MeetingRecorder(
      store: store, writer: writer, root: root, engine: engine, clock: clock, limits: limits,
      freeBytes: { [unowned self] in MainActor.assumeIsolated { free } })
    coordinator = PhoneMeetingCoordinator(
      store: store, root: root, recorder: recorder, session: controller,
      activity: MeetingActivityController(requester: activity), clock: clock)
    controller.meetingRecording = { [unowned self] in coordinator.isRecording }
  }

  /// A meeting in `preparing` with its microphone track, as the coordinator makes it.
  func prepared() async throws -> (meeting: UUID, track: UUID) {
    let meeting = try await store.create(now: clock.nowMilliseconds, origin: .iphone)
    let track = MeetingTrack(
      id: UUID(), meetingID: meeting.id, kind: .microphone, channelCount: 1, bitrate: 64_000)
    try await store.transition(
      id: meeting.id, to: .preparing, now: clock.nowMilliseconds,
      effects: [.insertTracks([track]), .insertTranscription(liveRequested: false)])
    return (meeting.id, track.id)
  }

  func rows(_ sql: String, _ arguments: StatementArguments = []) throws -> [Row] {
    try phone.history.database.read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
  }

  func segments(_ meeting: UUID) throws -> [Row] {
    try rows(
      """
      SELECT s.* FROM meeting_segments s JOIN meeting_tracks t ON t.id = s.track_id
      WHERE t.meeting_id = ? ORDER BY s.sequence
      """, [meeting.uuidString])
  }

  func assertState(_ meeting: UUID, _ expected: MeetingState, line: UInt = #line) async throws {
    let state = try await store.meeting(id: meeting)?.state
    XCTAssertEqual(state, expected, line: line)
  }
}
