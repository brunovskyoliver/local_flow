import Foundation
import OSLog
import Observation

/// The diarization queue (research R8): at most 100 meetings, deduplicated, one run at
/// a time, independent of any open window. Admission writes the `pending` run, so the
/// queue and the database agree after a relaunch.
@MainActor @Observable
final class SpeakerDiarizationCoordinator: DiarizationObserving {
  static let queueCapacity = 100
  static let queueFullNotice = "Speaker labeling queue is full"

  struct DiarizationStatus: Sendable, Equatable {
    let meetingID: UUID
    var state: MeetingDiarizationState
    /// Windows done over windows planned, while running.
    var progress: Double?
    var failure: DiarizationFailureCategory?
    /// Bumped whenever this meeting's accepted result changes.
    var labelsRevision = 0
    /// FR-009: the In-room meeting checkmark.
    var inRoom = false
  }

  /// The displayed meeting's status; see `observe(meetingID:)`.
  private(set) var status: DiarizationStatus?
  private(set) var activeMeetingID: UUID?
  var queuedCount: Int { queue.count }
  var noticePublished: (@MainActor (String) -> Void)?

  @ObservationIgnored private let diarizer: MeetingDiarizer
  /// Also the Assign speakers sheet's store.
  @ObservationIgnored let store: any SpeakerStoring
  @ObservationIgnored private let automaticEnabled: @MainActor () -> Bool
  @ObservationIgnored private let modelInstalled: @MainActor () async -> Bool
  @ObservationIgnored private let retryDelay: Duration
  @ObservationIgnored private let clock: any MeetingClock
  /// FR-037: RSS samples every 10 s while a run is active (`diarizing`).
  @ObservationIgnored private let recorder: ResourceRecorder?
  @ObservationIgnored private var rssTask: Task<Void, Never>?
  static let rssInterval: Duration = .seconds(10)
  @ObservationIgnored private var queue: [UUID] = []
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var cancelled: Set<UUID> = []
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "speakers")

  init(
    diarizer: MeetingDiarizer, store: any SpeakerStoring,
    automaticEnabled: @escaping @MainActor () -> Bool,
    modelInstalled: @escaping @MainActor () async -> Bool,
    retryDelay: Duration = .seconds(5), clock: any MeetingClock = SystemMeetingClock(),
    recorder: ResourceRecorder? = nil
  ) {
    self.diarizer = diarizer
    self.store = store
    self.automaticEnabled = automaticEnabled
    self.modelInstalled = modelInstalled
    self.retryDelay = retryDelay
    self.clock = clock
    self.recorder = recorder
  }

  /// FR-026: one row's manual speaker. The caller relabels its pager; the accepted
  /// result is unchanged, so no status is published. Returns false when refused.
  func correctSegment(meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection) async
    -> Bool
  {
    do {
      try await store.correctSegment(
        meetingID: meetingID, segmentID: segmentID, to: correction, now: clock.nowMilliseconds)
      return true
    } catch SpeakerStore.Error.correctionCapacity {
      noticePublished?("This meeting has too many speaker changes to save more.")
    } catch {
      noticePublished?("The speaker change could not be saved.")
    }
    return false
  }

  // MARK: Triggers

  /// After `final` is published and the finalization lease has finished.
  func meetingTranscriptDidFinalize(id: UUID) {
    guard automaticEnabled() else { return }
    Task {
      guard await modelInstalled() else { return }
      await enqueue(id, trigger: .automatic, revision: nil)
    }
  }

  /// Label speakers, Re-run, Retry and the in-room change. Always available (FR-002).
  func requestRun(meetingID: UUID, revision: Int64?, trigger: DiarizationTrigger) async {
    await enqueue(meetingID, trigger: trigger, revision: revision)
  }

  /// FR-009: In-room meeting. The snapshot changes first, then a run with the
  /// `in_room_change` trigger replaces any queued one; the accepted labels stay until
  /// it succeeds.
  func setInRoom(meetingID id: UUID, inRoom: Bool) async {
    do {
      try await store.setInRoom(meetingID: id, inRoom: inRoom, now: clock.nowMilliseconds)
    } catch {
      noticePublished?("The in-room setting could not be saved.")
      return
    }
    if status?.meetingID == id { status?.inRoom = inRoom }
    await cancel(meetingID: id)
    await enqueue(id, trigger: .inRoomChange, revision: nil)
  }

  /// Launch resume: meetings whose run is already `pending`.
  func resume(_ ids: [UUID]) {
    for id in ids where !queue.contains(id) && activeMeetingID != id {
      guard queue.count < Self.queueCapacity else { break }
      queue.append(id)
    }
    pump()
  }

  /// Cancel speaker labeling: the pending or running run is removed.
  func cancel(meetingID id: UUID) async {
    if activeMeetingID == id {
      await stopActive()
    } else {
      queue.removeAll { $0 == id }
      if let run = try? await store.diarization(meetingID: id)?.currentRunID {
        try? await store.cancel(runID: run)
      }
    }
    await refresh(id)
  }

  /// Cancel and join; the meeting's rows then go with its cascade.
  func meetingWillDelete(id: UUID) async {
    queue.removeAll { $0 == id }
    if activeMeetingID == id { await stopActive() }
    if status?.meetingID == id { status = nil }
  }

  /// The detail view shows this meeting; its stored state becomes `status`.
  func observe(meetingID id: UUID) async {
    if status?.meetingID != id { status = DiarizationStatus(meetingID: id, state: .notRequested) }
    await refresh(id)
  }

  /// Save names changed the accepted result's labels; the open transcript relabels.
  func namesDidChange(meetingID id: UUID) {
    if status?.meetingID == id { status?.labelsRevision += 1 }
  }

  func shutdown() async {
    await diarizer.prepareForShutdown()
    queue.removeAll()
    retry?.cancel()
    await stopActive()
  }

  // MARK: Queue

  private func enqueue(_ id: UUID, trigger: DiarizationTrigger, revision: Int64?) async {
    guard !queue.contains(id), activeMeetingID != id else { return }
    guard queue.count < Self.queueCapacity else {
      // An automatic request just leaves the meeting `not_requested`.
      if trigger != .automatic { noticePublished?(Self.queueFullNotice) }
      return
    }
    do {
      _ = try await diarizer.admit(meetingID: id, trigger: trigger, expectedRevision: revision)
    } catch SpeakerStore.Error.runInProgress {
      // Already pending (for example from reconciliation): queue it once.
    } catch {
      logger.notice("Diarization admission refused")
      if trigger != .automatic { noticePublished?("Speakers can't be labeled right now.") }
      return
    }
    // The await above may have let a duplicate in.
    guard !queue.contains(id), activeMeetingID != id else { return }
    queue.append(id)
    await refresh(id)
    pump()
  }

  private func pump() {
    guard task == nil, retry == nil, !queue.isEmpty else { return }
    let id = queue.removeFirst()
    activeMeetingID = id
    let diarizer = diarizer
    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, planned in
      Task { @MainActor in self?.report(id, done: done, planned: planned) }
    }
    task = Task { [weak self] in
      let outcome = await diarizer.run(meetingID: id, progress: progress)
      await self?.finish(id, outcome: outcome)
    }
    startRSSSampler()
  }

  private func startRSSSampler() {
    guard rssTask == nil, let recorder else { return }
    let clock = clock
    rssTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: Self.rssInterval) } catch { return }
        guard let self, self.activeMeetingID != nil else { return }
        recorder.record(phase: .diarizing, rssBytes: ResourceRecorder.residentBytes())
      }
    }
  }

  private func report(_ id: UUID, done: Int, planned: Int) {
    guard status?.meetingID == id, activeMeetingID == id, planned > 0 else { return }
    status?.state = .running
    status?.progress = Double(done) / Double(planned)
  }

  private func finish(_ id: UUID, outcome: MeetingDiarizer.Outcome) async {
    task = nil
    activeMeetingID = nil
    rssTask?.cancel()
    rssTask = nil
    switch outcome {
    case .preempted, .busy:
      // Back to the head; the model is someone else's for now.
      if !cancelled.contains(id) { queue.insert(id, at: 0) }
      scheduleRetry()
    case .failed(.transcriptChanged):
      if automaticEnabled() { await enqueue(id, trigger: .automatic, revision: nil) }
    case .succeeded:
      if status?.meetingID == id { status?.labelsRevision += 1 }
    case .failed, .cancelled, .nothingToRun: break
    }
    cancelled.remove(id)
    await refresh(id)
    pump()
  }

  private func scheduleRetry() {
    guard retry == nil else { return }
    let delay = retryDelay
    retry = Task { [weak self] in
      try? await Task.sleep(for: delay)
      self?.retry = nil
      self?.pump()
    }
  }

  private func stopActive() async {
    guard let id = activeMeetingID, let running = task else { return }
    cancelled.insert(id)
    running.cancel()
    await running.value
  }

  private func refresh(_ id: UUID) async {
    guard status?.meetingID == id else { return }
    let state = (try? await store.meetingState(meetingID: id)) ?? .notRequested
    var failure: DiarizationFailureCategory?
    if state == .failed || state == .interrupted {
      failure = try? await store.latestRun(meetingID: id)?.failureCategory
    }
    let inRoom = (try? await store.diarization(meetingID: id)?.inRoom) ?? false
    guard status?.meetingID == id else { return }
    status?.state = state
    status?.failure = failure
    status?.inRoom = inRoom
    if state != .running { status?.progress = nil }
  }

}

/// contracts/ui.md "Status line": one content-free sentence per failure category.
enum DiarizationFailureMessage {
  static func message(for category: DiarizationFailureCategory) -> String {
    switch category {
    case .modelUnavailable:
      "Speaker labeling model isn't installed. Install it in Settings → Models."
    case .osUnsupported: "Speaker labeling needs macOS 15 or later."
    case .modelLoadFailure: "The speaker labeling model couldn't be loaded."
    case .audioMissing: "This meeting's audio isn't available, so speakers can't be labeled."
    case .audioDecodeFailure: "This meeting's audio couldn't be read."
    case .runtimeFailure: "Speaker labeling stopped unexpectedly."
    case .transcriptChanged: "The transcript changed while speakers were being labeled."
    case .persistenceFailure: "Speaker labels couldn't be saved."
    case .persistenceCapacity: "Speaker labels couldn't be saved. Meeting storage is full."
    case .interrupted: "Speaker labeling was interrupted."
    }
  }

  /// Retry is offered unless another attempt cannot help on this Mac.
  static func isRetryable(_ category: DiarizationFailureCategory) -> Bool {
    category != .osUnsupported
  }
}
