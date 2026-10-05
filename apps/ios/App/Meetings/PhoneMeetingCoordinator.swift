import Foundation
import LocalFlowCore
import Observation
import os

/// Owns the phone's one meeting (User Story 1): `created → preparing → recording ⇄ paused →
/// finalizing → completed` through `MeetingStore`, origin `iphone`, one microphone track and
/// a transcription row. One microphone owner at a time (FR-006, research R9): a ready
/// dictation session ends first, a dictation still transcribing blocks the start. The Live
/// Activity comes before any audio. Launch runs `MeetingReconciler` before Start is allowed.
@MainActor
@Observable
final class PhoneMeetingCoordinator: MeetingIntentHandler {
  static let dictationBusy = "Wait for the dictation to finish transcribing."
  static let endedDictation = "The dictation session ended so the meeting can use the microphone."
  static let liveActivitiesOff =
    "Turn on Live Activities for LocalFlow in Settings to record meetings."
  static let microphoneDenied =
    "LocalFlow needs the microphone. Turn it on in Settings › LocalFlow › Microphone."
  static let microphoneFailed = "The microphone couldn't start. Try again."
  static let storageFull = "Not enough free space to record. Free at least 200 MB."
  static let lowStorage = "Less than 1 GB free. The meeting stops and saves at 200 MB."
  static let stoppedForStorage = "The meeting stopped because storage is almost full. It's saved."
  static let stoppedAtLimit = "The meeting stopped at the 4-hour limit. It's saved."
  static let stoppedOnFailure = "Recording failed. The audio so far is saved."
  static let notSaved = "The meeting couldn't be saved. Try again."

  /// The meeting being recorded.
  private(set) var meetingID: UUID?
  private(set) var notice: String?
  private(set) var isBusy = false
  /// Bumped when a meeting starts, stops or is recovered, so the list refreshes.
  private(set) var revision = 0
  /// Where a stop came from: the app's own Stop can start background work from the tap;
  /// the Live Activity and the recorder stop with the app possibly in the background.
  enum StopOrigin: Sendable { case app, liveActivity, recorder }
  /// A meeting ended and its audio is on disk (Feature 020: the server queue picks it up).
  @ObservationIgnored var onEnded: ((UUID, StopOrigin) -> Void)?

  let recorder: MeetingRecorder
  let store: MeetingStore
  private let root: MeetingStorageRoot
  private let session: SessionController
  private let activity: MeetingActivityController
  private let clock: any MeetingClock
  @ObservationIgnored private var recovery: Task<Void, Never>?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "meetings")

  init(
    store: MeetingStore, root: MeetingStorageRoot, recorder: MeetingRecorder,
    session: SessionController, activity: MeetingActivityController,
    clock: any MeetingClock = SystemMeetingClock()
  ) {
    self.store = store
    self.root = root
    self.recorder = recorder
    self.session = session
    self.activity = activity
    self.clock = clock
    recorder.onChange = { [weak self] in self?.updateActivity() }
    recorder.onEnded = { [weak self] end in self?.recorderEnded(end) }
  }

  var isRecording: Bool { meetingID != nil }

  /// Why Record meeting is disabled, or nil.
  var startBlockedReason: String? {
    guard meetingID == nil else { return nil }
    switch session.session?.state {
    case .recording, .finishing: return Self.dictationBusy
    default: return nil
    }
  }

  /// Launch: recover what a crash, kill or power loss left behind (FR-004), and end a
  /// meeting activity a previous process left on screen.
  func recover() {
    guard recovery == nil else { return }
    activity.end()
    let reconciler = MeetingReconciler(store: store, root: root, recorder: nil, clock: clock)
    recovery = Task {
      let summary = await reconciler.run()
      if let text = summary.noticeText { notice = text }
      if !summary.isSilent { revision += 1 }
    }
  }

  func waitForRecovery() async { await recovery?.value }

  func start() async {
    guard !isBusy, meetingID == nil else { return }
    isBusy = true
    defer { isBusy = false }
    await recovery?.value
    guard startBlockedReason == nil else { return refuse(startBlockedReason) }
    guard await recorder.engine.requestPermission() else { return refuse(Self.microphoneDenied) }
    // The permission prompt can outlast a dictation that started meanwhile.
    guard startBlockedReason == nil else { return refuse(startBlockedReason) }
    do {
      try FileSegmentWriter.ensurePrivateDirectory(root.url)
    } catch {
      return refuse(Self.notSaved)
    }
    let free = recorder.freeSpace() ?? .max
    guard free >= MeetingRecorder.Limits().stopFreeBytes else { return refuse(Self.storageFull) }
    let now = clock.nowMilliseconds
    do {
      try activity.begin(at: Date(timeIntervalSince1970: Double(now) / 1_000))
    } catch {
      return refuse(Self.liveActivitiesOff)
    }
    let endedDictation = session.isActive
    if endedDictation { session.end(.userEnded) }
    var created: UUID?
    do {
      let meeting = try await store.create(now: now, origin: .iphone)
      created = meeting.id
      let track = MeetingTrack(
        id: UUID(), meetingID: meeting.id, kind: .microphone, channelCount: 1,
        bitrate: MeetingTrackKind.microphone.bitrate)
      // The transcription row comes with the tracks; `flowd-meeting` needs both.
      try await store.transition(
        id: meeting.id, to: .preparing, now: now,
        effects: [.insertTracks([track]), .insertTranscription(liveRequested: false)])
      do {
        try await recorder.start(meetingID: meeting.id, trackID: track.id)
      } catch {
        Self.log.error("Meeting start failed: \(String(describing: error), privacy: .public)")
        _ = try? await store.transition(
          id: meeting.id, to: .failed, now: clock.nowMilliseconds,
          effects: [.failure((error as? MeetingCaptureFailure)?.reason ?? .deviceLost, detail: nil)]
        )
        activity.end()
        revision += 1
        return refuse(Self.microphoneFailed)
      }
    } catch {
      Self.log.error("Meeting rows failed: \(String(describing: error), privacy: .public)")
      if let created {
        _ = try? await store.transition(
          id: created, to: .failed, now: clock.nowMilliseconds,
          effects: [.failure(.storageUnavailable, detail: nil)])
      }
      activity.end()
      return refuse(Self.notSaved)
    }
    meetingID = created
    notice =
      endedDictation
      ? Self.endedDictation : recorder.lowStorage ? Self.lowStorage : nil
    revision += 1
  }

  func stop(from origin: StopOrigin = .app) async {
    guard meetingID != nil, !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    activity.update(activityState(.stopping))
    await recorder.stop()
    ended(notice: nil, origin: origin)
  }

  /// The Live Activity's Stop.
  func stopMeeting() async { await stop(from: .liveActivity) }

  func clearNotice() { notice = nil }

  private func refuse(_ text: String?) { notice = text }

  // MARK: Private

  private func recorderEnded(_ end: MeetingRecorder.End) {
    switch end {
    case .storageFull: ended(notice: Self.stoppedForStorage, origin: .recorder)
    case .durationLimit: ended(notice: Self.stoppedAtLimit, origin: .recorder)
    case .failed: ended(notice: Self.stoppedOnFailure, origin: .recorder)
    }
  }

  private func ended(notice: String?, origin: StopOrigin) {
    activity.end()
    let id = meetingID
    meetingID = nil
    self.notice = notice
    revision += 1
    if let id { onEnded?(id, origin) }
  }

  private func updateActivity() {
    guard meetingID != nil else { return }
    activity.update(activityState(recorder.isPaused ? .paused : .recording))
  }

  private func activityState(_ phase: MeetingActivityAttributes.ContentState.Phase)
    -> MeetingActivityAttributes.ContentState
  {
    let now = Date(timeIntervalSince1970: Double(clock.nowMilliseconds) / 1_000)
    let elapsed =
      recorder.elapsedBefore + (recorder.runningSince.map { now.timeIntervalSince($0) } ?? 0)
    return .init(phase: phase, since: now.addingTimeInterval(-elapsed), elapsed: elapsed)
  }
}
