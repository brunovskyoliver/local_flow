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
  /// Feature 010 (FR-022): told after the lease has finished and adoption committed.
  @ObservationIgnored weak var identification: (any IdentificationObserving)?
  /// Feature 011: evidence writes (assignment, adopted labels) refresh the
  /// analysis stale flag.
  @ObservationIgnored weak var intelligence: (any IntelligenceObserving)?

  @ObservationIgnored private let diarizer: MeetingDiarizer
  /// Also the Assign speakers sheet's store.
  @ObservationIgnored let store: any SpeakerStoring
  @ObservationIgnored private let automaticEnabled: @MainActor () -> Bool
  @ObservationIgnored private let modelInstalled: @MainActor () async -> Bool
  /// The fallback wait after a busy or preempted run; the retry normally starts as
  /// soon as the lifecycle reports the model free.
  @ObservationIgnored private let retryDelay: Duration
  @ObservationIgnored private let clock: any MeetingClock
  /// Tells the lifecycle while runs are queued so Keep model ready waits for them, and
  /// wakes a busy retry when the model is released.
  @ObservationIgnored private let demand: SpeakerModelDemand?
  /// FR-037: RSS samples every 10 s while a run is active (`diarizing`).
  @ObservationIgnored private let recorder: ResourceRecorder?
  @ObservationIgnored private var rssTask: Task<Void, Never>?
  static let rssInterval: Duration = .seconds(10)
  @ObservationIgnored private var queue: [UUID] = [] {
    didSet { demandDidChange() }
  }
  @ObservationIgnored private var task: Task<Void, Never>? {
    didSet { demandDidChange() }
  }
  @ObservationIgnored private var retry: Task<Void, Never>? {
    didSet { demandDidChange() }
  }
  @ObservationIgnored private var cancelled: Set<UUID> = []
  /// Echo energy profiles handed over by the finalization pass, keyed by meeting.
  /// Bounded: kept only for the newest few pending runs, else the diarizer
  /// profiles the tracks itself.
  @ObservationIgnored private var echoProfiles: [UUID: EchoGate.Profile] = [:]
  @ObservationIgnored private var echoProfileOrder: [UUID] = []
  static let echoProfileCapacity = 4
  /// The profile handed to the active run, put back when the run returns to the queue.
  @ObservationIgnored private var activeEchoProfile: EchoGate.Profile?
  /// Meetings whose automatic speaker work must end in one `meetingSpeakersDidSettle`
  /// so the summary sees every label there is (settle instead of transcript-final).
  @ObservationIgnored private var pendingSettle: Set<UUID> = [] {
    didSet { demandDidChange() }
  }
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "speakers")

  init(
    diarizer: MeetingDiarizer, store: any SpeakerStoring,
    automaticEnabled: @escaping @MainActor () -> Bool,
    modelInstalled: @escaping @MainActor () async -> Bool,
    retryDelay: Duration = .seconds(30), clock: any MeetingClock = SystemMeetingClock(),
    recorder: ResourceRecorder? = nil, lifecycle: ModelLifecycleCoordinator? = nil
  ) {
    self.diarizer = diarizer
    self.store = store
    self.automaticEnabled = automaticEnabled
    self.modelInstalled = modelInstalled
    self.retryDelay = retryDelay
    self.clock = clock
    self.recorder = recorder
    self.demand = lifecycle.map(SpeakerModelDemand.init)
  }

  /// FR-026: one row's manual speaker. The caller relabels its pager; the accepted
  /// result is unchanged, so no status is published. Returns false when refused.
  func correctSegment(meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection) async
    -> Bool
  {
    do {
      try await store.correctSegment(
        meetingID: meetingID, segmentID: segmentID, to: correction, now: clock.nowMilliseconds)
      intelligence?.evidenceDidChange(meetingID: meetingID)
      return true
    } catch SpeakerStore.Error.correctionCapacity {
      noticePublished?("This meeting has too many speaker changes to save more.")
    } catch {
      noticePublished?("The speaker change could not be saved.")
    }
    return false
  }

  // MARK: Triggers

  /// After `final` is published and the finalization lease has finished. The
  /// summary is told once speaker work settles — a run that ends here, or at
  /// once when diarization is off, unavailable or refused (FR-002).
  func meetingTranscriptDidFinalize(id: UUID, echoProfile: EchoGate.Profile?) {
    if let echoProfile { keepEchoProfile(echoProfile, for: id) }
    guard automaticEnabled() else {
      intelligence?.meetingSpeakersDidSettle(id: id)
      return
    }
    Task {
      guard await modelInstalled() else {
        intelligence?.meetingSpeakersDidSettle(id: id)
        return
      }
      pendingSettle.insert(id)
      if await !enqueue(id, trigger: .automatic, revision: nil), pendingSettle.remove(id) != nil {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    }
  }

  /// Holds a handed-over profile for the meeting's next run, newest few only.
  private func keepEchoProfile(_ profile: EchoGate.Profile, for id: UUID) {
    if echoProfiles[id] == nil { echoProfileOrder.append(id) }
    echoProfiles[id] = profile
    while echoProfileOrder.count > Self.echoProfileCapacity {
      let stale = echoProfileOrder.removeFirst()
      echoProfiles.removeValue(forKey: stale)
    }
  }

  /// Meetings holding a handed-over echo profile, oldest first. For tests.
  var echoProfileMeetingIDs: [UUID] { echoProfileOrder }

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

  /// Launch resume: meetings whose run is already `pending`. The automatic
  /// summary was still waiting on these when the app quit, so they settle it.
  func resume(_ ids: [UUID]) {
    for id in ids where !queue.contains(id) && activeMeetingID != id {
      guard queue.count < Self.queueCapacity else { break }
      queue.append(id)
      pendingSettle.insert(id)
    }
    pump()
  }

  /// Cancel speaker labeling: the pending or running run is removed.
  func cancel(meetingID id: UUID) async {
    if pendingSettle.remove(id) != nil {
      // No labels will land after all; the waiting summary proceeds without them.
      intelligence?.meetingSpeakersDidSettle(id: id)
    }
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
    pendingSettle.remove(id)
    echoProfiles.removeValue(forKey: id)
    echoProfileOrder.removeAll { $0 == id }
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

  /// True when the meeting is queued or running at the end — false when admission
  /// was refused and no run will come of it.
  @discardableResult
  private func enqueue(_ id: UUID, trigger: DiarizationTrigger, revision: Int64?) async -> Bool {
    guard !queue.contains(id), activeMeetingID != id else { return true }
    guard queue.count < Self.queueCapacity else {
      // An automatic request just leaves the meeting `not_requested`.
      if trigger != .automatic { noticePublished?(Self.queueFullNotice) }
      return false
    }
    do {
      _ = try await diarizer.admit(meetingID: id, trigger: trigger, expectedRevision: revision)
    } catch SpeakerStore.Error.runInProgress {
      // Already pending (for example from reconciliation): queue it once.
    } catch {
      logger.notice("Diarization admission refused")
      if trigger != .automatic { noticePublished?("Speakers can't be labeled right now.") }
      return false
    }
    // The await above may have let a duplicate in.
    guard !queue.contains(id), activeMeetingID != id else { return true }
    queue.append(id)
    await refresh(id)
    pump()
    return true
  }

  private func pump() {
    guard task == nil, retry == nil, !queue.isEmpty else { return }
    let id = queue.removeFirst()
    activeMeetingID = id
    let diarizer = diarizer
    let echoProfile = echoProfiles.removeValue(forKey: id)
    echoProfileOrder.removeAll { $0 == id }
    activeEchoProfile = echoProfile
    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, planned in
      Task { @MainActor in self?.report(id, done: done, planned: planned) }
    }
    task = Task { [weak self] in
      let outcome = await diarizer.run(meetingID: id, progress: progress, echoProfile: echoProfile)
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
    let echoProfile = activeEchoProfile
    activeEchoProfile = nil
    switch outcome {
    case .preempted, .busy:
      // Back to the head; the model is someone else's for now. The retry gets the
      // same echo profile, unless a newer pass handed one over meanwhile.
      if !cancelled.contains(id) {
        queue.insert(id, at: 0)
        if let echoProfile, echoProfiles[id] == nil { keepEchoProfile(echoProfile, for: id) }
      }
      scheduleRetry()
    case .failed(.transcriptChanged):
      if automaticEnabled(), await enqueue(id, trigger: .automatic, revision: nil) {
        break
      }
      // Refused or switched off: no labels will land for this transcript.
      if pendingSettle.remove(id) != nil {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    case .succeeded:
      if status?.meetingID == id { status?.labelsRevision += 1 }
      // The diarizer's lease finished before adoption; identification may start now.
      let identifying = identification?.diarizationDidAdopt(meetingID: id) ?? false
      // New labels are evidence: an accepted analysis is now behind them.
      intelligence?.evidenceDidChange(meetingID: id)
      // Identification owns the settle when it took over; otherwise labels are done.
      if pendingSettle.remove(id) != nil && !identifying {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    case .failed, .cancelled, .nothingToRun:
      if pendingSettle.remove(id) != nil {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    }
    cancelled.remove(id)
    await refresh(id)
    pump()
  }

  private func scheduleRetry() {
    guard retry == nil else { return }
    let delay = retryDelay
    let demand = demand
    retry = Task { [weak self] in
      await SpeakerModelDemand.waitForRetry(demand, fallback: delay)
      self?.retry = nil
      self?.pump()
    }
  }

  private func demandDidChange() {
    demand?.update(
      pending: task != nil || retry != nil || !queue.isEmpty || !pendingSettle.isEmpty)
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
