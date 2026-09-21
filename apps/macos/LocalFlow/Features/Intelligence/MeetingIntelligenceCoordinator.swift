import Foundation
import OSLog
import Observation

/// The analysis scheduler (`contracts/client-analysis.md`): one bounded,
/// deduplicated meeting queue and one run at a time. Admission inside
/// `MeetingAnalyzer.run` writes the `pending` row, so queue and database agree
/// after a relaunch. Automatic enqueue happens only when
/// `AppPreferences.meetingSummariesAutomatic` is on; manual generation always
/// works (FR-035).
@MainActor @Observable
final class MeetingIntelligenceCoordinator: IntelligenceObserving {
  static let queueCapacity = 100
  static let queueFullNotice = "Summary queue is full"

  /// The displayed meeting's status; see `observe(meetingID:)`.
  private(set) var status: AnalysisStatus?
  private(set) var activeMeetingID: UUID?
  var queuedCount: Int { queue.count }
  var noticePublished: (@MainActor (String) -> Void)?

  @ObservationIgnored private let analyzer: MeetingAnalyzer
  @ObservationIgnored private let store: any AnalysisStoring
  @ObservationIgnored private let automaticEnabled: @MainActor () -> Bool
  @ObservationIgnored private let clock: any MeetingClock
  @ObservationIgnored private var queue: [UUID] = []
  @ObservationIgnored private var triggers: [UUID: AnalysisTrigger] = [:]
  @ObservationIgnored private var admissions: [UUID: MeetingAnalyzer.Admission] = [:]
  /// Meetings whose `pending` row is being written right now; dedupe covers
  /// them so a second event can't double-admit.
  @ObservationIgnored private var admitting: Set<UUID> = []
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var cancelled: Set<UUID> = []
  @ObservationIgnored private var progress: [UUID: AnalysisProgress] = [:]
  /// Meetings whose `server_busy` run already used its one re-queue
  /// (contract step 6: retry once after 30 s, then fail for good).
  @ObservationIgnored private var busyRequeued: Set<UUID> = []
  @ObservationIgnored private var requeueTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "intelligence")
  @ObservationIgnored private let recorder: ResourceRecorder?

  init(
    analyzer: MeetingAnalyzer, store: any AnalysisStoring,
    automaticEnabled: @escaping @MainActor () -> Bool,
    clock: any MeetingClock = SystemMeetingClock(),
    recorder: ResourceRecorder? = nil
  ) {
    self.analyzer = analyzer
    self.store = store
    self.automaticEnabled = automaticEnabled
    self.clock = clock
    self.recorder = recorder
  }

  // MARK: Triggers

  /// `IntelligenceObserving`: after a final transcript pass is adopted.
  func meetingTranscriptDidFinalize(id: UUID) {
    guard automaticEnabled() else { return }
    enqueue(id, trigger: .automatic)
  }

  /// Generate Summary, Retry and Regenerate (`requestRun` in the contract);
  /// always allowed, whatever the automatic preference says.
  func requestRun(meetingID: UUID, trigger: AnalysisTrigger = .manual) {
    enqueue(meetingID, trigger: trigger)
  }

  /// Cancel the queued or running analysis for this meeting.
  func cancel(meetingID id: UUID) async {
    queue.removeAll { $0 == id }
    triggers[id] = nil
    admissions[id] = nil
    progress[id] = nil
    dropRequeue(id)
    if activeMeetingID == id {
      await stopActive()
    } else {
      // Only an in-flight admission needs the flag; nothing else can arrive.
      if admitting.contains(id) { cancelled.insert(id) }
      if let run = try? await store.latestRun(meetingID: id),
        run.state == .pending || run.state == .running
      {
        try? await store.cancel(runID: run.id, now: clock.nowMilliseconds)
      }
    }
    await refresh(id)
  }

  /// `IntelligenceObserving`: cancel and join; the meeting's rows go with its
  /// cascade.
  func meetingWillDelete(id: UUID) async {
    queue.removeAll { $0 == id }
    triggers[id] = nil
    admissions[id] = nil
    progress[id] = nil
    dropRequeue(id)
    if activeMeetingID == id { await stopActive() }
    if admitting.contains(id) { cancelled.insert(id) }
    if let run = try? await store.latestRun(meetingID: id),
      run.state == .pending || run.state == .running
    {
      try? await store.cancel(runID: run.id, now: clock.nowMilliseconds)
    }
    if status?.meetingID == id { status = nil }
  }

  /// `IntelligenceObserving`: an evidence write (assignment, identity, notes)
  /// may have outdated the accepted analysis. The version is recomputed and
  /// compared to the accepted run's — a display-name-only rename keeps the
  /// version and never flips the flag. Staleness never enqueues a run.
  func evidenceDidChange(meetingID: UUID) {
    Task { [weak self] in await self?.refreshStaleness(meetingID) }
  }

  private func refreshStaleness(_ id: UUID) async {
    guard let pointer = try? await store.analysis(meetingID: id),
      let acceptedID = pointer.acceptedRunID,
      let current = try? await analyzer.currentEvidenceVersion(meetingID: id),
      let accepted = try? await store.runs(meetingID: id, limit: AnalysisStore.runRowCap)
        .first(where: { $0.id == acceptedID })
    else { return }
    guard status?.meetingID == id, status?.hasAccepted == true else { return }
    let stale = current != accepted.evidenceVersion
    if stale, status?.stale != true {
      recorder?.record(phase: .analysisValidating, metric: .analysisStaleCount, itemCount: 1)
    }
    status?.stale = stale
  }

  /// Launch resume (FR-007a): the reconciler interrupted the leftover rows
  /// and picked these meetings; each restarts through the queue as a fresh run.
  func resume(_ restarts: [UUID]) {
    for id in restarts {
      enqueue(id, trigger: .restart)
    }
  }

  /// The detail view shows this meeting; its stored state becomes `status`.
  @discardableResult
  func observe(meetingID id: UUID) async -> AnalysisStatus {
    if status?.meetingID != id {
      status = AnalysisStatus(meetingID: id)
    }
    await refresh(id)
    return status ?? AnalysisStatus(meetingID: id)
  }

  func shutdown() async {
    queue.removeAll()
    triggers.removeAll()
    progress.removeAll()
    for task in requeueTasks.values { task.cancel() }
    requeueTasks.removeAll()
    busyRequeued.removeAll()
    await stopActive()
  }

  // MARK: Queue

  /// Admission writes the `pending` row first; the queued status is published
  /// only after that store write succeeded. A pre-admission refusal leaves no
  /// row — a manual requester is told, an automatic event stays quiet.
  private func enqueue(_ id: UUID, trigger: AnalysisTrigger) {
    admit(id, trigger: trigger) { [analyzer] in
      try await analyzer.admit(meetingID: id, trigger: trigger)
    }
  }

  private func admit(
    _ id: UUID, trigger: AnalysisTrigger,
    makeAdmission: @escaping @MainActor () async throws -> MeetingAnalyzer.Admission
  ) {
    guard !queue.contains(id), !admitting.contains(id), activeMeetingID != id else {
      // A manual ask on a queued automatic run upgrades its trigger.
      if trigger != .automatic { triggers[id] = trigger }
      return
    }
    let inFlight = queue.count + admitting.count + (activeMeetingID == nil ? 0 : 1)
    guard inFlight < Self.queueCapacity else {
      noticePublished?(Self.queueFullNotice)
      return
    }
    admitting.insert(id)
    Task {
      do {
        let admission = try await makeAdmission()
        admitting.remove(id)
        guard !cancelled.contains(id) else {
          try? await store.cancel(runID: admission.run.id, now: clock.nowMilliseconds)
          cancelled.remove(id)
          return
        }
        queue.append(id)
        recorder?.record(
          phase: .analysisQueued, metric: .analysisQueueDepth,
          itemCount: UInt32(clamping: queue.count))
        admissions[id] = admission
        triggers[id] = trigger
        await refresh(id)
      } catch let failure as AnalysisFailure {
        admitting.remove(id)
        cancelled.remove(id)
        // A resume that lost its pending row or eligibility stays quiet, as
        // does every automatic refusal; manual requesters are told.
        if trigger != .automatic && trigger != .restart {
          noticePublished?(AnalysisFailureMessage.message(for: failure.category))
        }
      } catch {
        admitting.remove(id)
        cancelled.remove(id)
        logger.notice("analysis admission failed")
        if trigger != .automatic && trigger != .restart {
          noticePublished?(AnalysisFailureMessage.message(for: .persistenceFailure))
        }
      }
      pump()
    }
  }

  private func pump() {
    guard task == nil, !queue.isEmpty else { return }
    let id = queue.removeFirst()
    guard let admission = admissions.removeValue(forKey: id) else {
      pump()
      return
    }
    activeMeetingID = id
    var analyzer = analyzer
    analyzer.progress = { [weak self] meetingID, value in
      Task { @MainActor in self?.report(meetingID, progress: value) }
    }
    task = Task { [weak self] in
      do {
        let run = try await analyzer.execute(admission)
        await self?.finish(id, run: run)
      } catch is CancellationError {
        await self?.finish(id, run: nil)
      } catch {
        await self?.finish(id, run: nil)
      }
    }
  }

  private func finish(_ id: UUID, run: AnalysisRun?) async {
    task = nil
    activeMeetingID = nil
    progress[id] = nil
    triggers[id] = nil
    cancelled.remove(id)
    // contracts/client-analysis.md step 6: `server_busy` (or HTTP 429) is a
    // re-queue request — the run re-enters the queue once after 30 s; a
    // second busy answer stays `server_unavailable`.
    if let run, run.state == .failed, run.failureCategory == .serverUnavailable,
      run.failureDetail == "server_busy", !busyRequeued.contains(id)
    {
      busyRequeued.insert(id)
      requeueTasks[id] = Task { [weak self] in
        try? await self?.clock.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        await self?.requeue(id)
      }
    } else {
      busyRequeued.remove(id)
    }
    await refresh(id)
    pump()
  }

  private func requeue(_ id: UUID) {
    requeueTasks[id] = nil
    enqueue(id, trigger: .retry)
  }

  private func dropRequeue(_ id: UUID) {
    requeueTasks[id]?.cancel()
    requeueTasks[id] = nil
    busyRequeued.remove(id)
  }

  private func report(_ id: UUID, progress value: AnalysisProgress?) {
    progress[id] = value
    guard status?.meetingID == id, activeMeetingID == id else { return }
    status?.progress = value
    if value != nil { status?.state = .running }
  }

  private func stopActive() async {
    guard let id = activeMeetingID, let running = task else { return }
    cancelled.insert(id)
    running.cancel()
    await running.value
  }

  private func refresh(_ id: UUID) async {
    let pointer = try? await store.analysis(meetingID: id)
    let run = try? await store.latestRun(meetingID: id)
    guard status?.meetingID == id else { return }
    var next = AnalysisStatus(meetingID: id)
    next.hasAccepted = pointer?.acceptedRunID != nil
    next.stale = status?.stale ?? false
    if activeMeetingID == id {
      next.state = .running
      next.progress = progress[id]
    } else if queue.contains(id) {
      next.state = .pending
      next.queuedPosition = queue.firstIndex(of: id).map { $0 + 1 }
    } else if let run {
      next.state = AnalysisStatus.State(run.state)
      if run.state == .failed || run.state == .timedOut || run.state == .interrupted {
        next.failure = run.failureCategory
      }
    }
    status = next
  }
}

/// contracts/ui.md "Failure messages": one fixed sentence per category.
enum AnalysisFailureMessage {
  static func message(for category: AnalysisFailureCategory) -> String {
    switch category {
    case .notEligible: return "The transcript is not finished yet."
    case .serverUnreachable: return "Your server could not be reached."
    case .authenticationFailed: return "The server rejected the credential."
    case .serverUnavailable, .backendUnavailable:
      return "The server's language model is not running."
    case .backendBusy: return "The server is busy with dictation. Try again in a moment."
    case .backendTimeout, .timeout: return "The summary took too long and was stopped."
    case .unsupportedVersion, .malformedResponse, .oversizedResponse, .meetingMismatch:
      return "The server sent a summary LocalFlow could not read."
    case .sourceValidation, .protectedLiteral, .unsupportedContent, .overCap:
      return "The summary did not pass LocalFlow's checks and was not saved."
    case .tooLong:
      return "This meeting is too long to summarize with the current limits."
    case .persistenceFailure: return "The summary couldn't be saved."
    case .persistenceCapacity:
      return "The summary couldn't be saved. Meeting storage is full."
    case .interrupted: return "The summary was interrupted."
    }
  }
}

extension AnalysisStatus.State {
  init(_ state: AnalysisRunState) {
    switch state {
    case .pending: self = .pending
    case .running: self = .running
    case .succeeded, .superseded: self = .succeeded
    case .failed: self = .failed
    case .cancelled: self = .cancelled
    case .timedOut: self = .timedOut
    case .interrupted: self = .interrupted
    }
  }
}
