import Foundation
import OSLog
import Observation

/// The identification scheduler (research R2, R8, R10): one bounded, deduplicated run
/// queue, one memory-only past-search queue, enrollment jobs ahead of runs, and one
/// piece of model work at a time. Admission writes the `pending` run, so the queue and
/// the database agree after a relaunch. Everything short-circuits when the global
/// setting is off (FR-015, FR-038).
@MainActor @Observable
final class SpeakerIdentificationCoordinator: IdentificationObserving {
  static let queueCapacity = 100
  static let pastSearchCapacity = 500
  static let queueFullNotice = "Speaker identification queue is full"
  /// Attempts at a busy or preempted enrollment before it fails.
  static let enrollmentAttempts = 20
  static let rssInterval: Duration = .seconds(10)

  /// The displayed meeting's status; see `observe(meetingID:)`.
  private(set) var status: IdentificationStatus?
  private(set) var activeMeetingID: UUID?
  var queuedCount: Int { queue.count }
  var pastSearchRemaining: Int { pastSearch.count }
  var noticePublished: (@MainActor (String) -> Void)?
  /// R10: after an enrollment stored ≥ 1 sample, once per enrollment.
  var enrollmentDidStore: (@MainActor (_ knownSpeakerID: UUID, _ name: String) -> Void)?
  /// Feature 011: identity writes refresh the analysis stale flag.
  @ObservationIgnored weak var intelligence: (any IntelligenceObserving)?

  @ObservationIgnored private let identifier: MeetingIdentifier
  @ObservationIgnored private let enrollment: EnrollmentJob
  @ObservationIgnored let store: any IdentityStoring
  @ObservationIgnored private let enabled: @MainActor () -> Bool
  @ObservationIgnored private let retryDelay: Duration
  @ObservationIgnored private let clock: any MeetingClock
  @ObservationIgnored private let recorder: ResourceRecorder?
  @ObservationIgnored private var rssTask: Task<Void, Never>?
  @ObservationIgnored private var queue: [UUID] = []
  @ObservationIgnored private var triggers: [UUID: IdentificationTrigger] = [:]
  @ObservationIgnored private var pastSearch: [UUID] = []
  @ObservationIgnored private var pastSearchName: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var cancelled: Set<UUID> = []
  /// Enrollments wait in order and run before the next identification run.
  @ObservationIgnored private var enrollments: [PendingEnrollment] = []
  @ObservationIgnored private var activeEnrollment: PendingEnrollment?
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "identification")

  private final class PendingEnrollment {
    let request: EnrollmentRequest
    let continuation: CheckedContinuation<EnrollmentOutcome, Never>
    var attempts = 0
    init(request: EnrollmentRequest, continuation: CheckedContinuation<EnrollmentOutcome, Never>) {
      self.request = request
      self.continuation = continuation
    }
  }

  init(
    identifier: MeetingIdentifier, enrollment: EnrollmentJob, store: any IdentityStoring,
    enabled: @escaping @MainActor () -> Bool, retryDelay: Duration = .seconds(5),
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil
  ) {
    self.identifier = identifier
    self.enrollment = enrollment
    self.store = store
    self.enabled = enabled
    self.retryDelay = retryDelay
    self.clock = clock
    self.recorder = recorder
  }

  /// Meetings whose automatic identification run must end in one
  /// `meetingSpeakersDidSettle` so the summary sees every identity there is.
  @ObservationIgnored private var pendingSettle: Set<UUID> = []

  // MARK: Triggers

  /// After the diarization lease has finished and the adoption committed (FR-022).
  /// True when an identification run follows — it then owns the settle.
  @discardableResult
  func diarizationDidAdopt(meetingID: UUID) -> Bool {
    guard enabled() else { return false }
    pendingSettle.insert(meetingID)
    Task {
      if await !enqueue(meetingID, trigger: .automatic), pendingSettle.remove(meetingID) != nil {
        intelligence?.meetingSpeakersDidSettle(id: meetingID)
      }
    }
    return true
  }

  /// Rerun identification, Retry and the sample-change rerun.
  func requestRun(meetingID: UUID, trigger: IdentificationTrigger) async {
    guard enabled() else {
      if trigger != .automatic { noticePublished?("Speaker identification is turned off.") }
      return
    }
    await enqueue(meetingID, trigger: trigger)
  }

  /// Cancel identification: the pending or running run is removed.
  func cancel(meetingID id: UUID) async {
    pastSearch.removeAll { $0 == id }
    if pendingSettle.remove(id) != nil {
      // No identities will land; the waiting summary proceeds without them.
      intelligence?.meetingSpeakersDidSettle(id: id)
    }
    if activeMeetingID == id {
      await stopActive()
    } else {
      queue.removeAll { $0 == id }
      triggers[id] = nil
      if let run = try? await store.identification(meetingID: id)?.currentRunID {
        try? await store.cancel(runID: run)
      }
    }
    await refresh(id)
  }

  /// Cancel and join; the meeting's rows then go with its cascade. Pending enrollments
  /// for the meeting are dropped.
  func meetingWillDelete(id: UUID) async {
    queue.removeAll { $0 == id }
    triggers[id] = nil
    pastSearch.removeAll { $0 == id }
    pendingSettle.remove(id)
    for pending in enrollments where pending.request.meetingID == id {
      pending.continuation.resume(returning: .failed(.interrupted))
    }
    enrollments.removeAll { $0.request.meetingID == id }
    if activeMeetingID == id { await stopActive() }
    if status?.meetingID == id { status = nil }
  }

  /// Launch resume: meetings whose run is already `pending`. Their settle was
  /// in flight when the app quit; finishing the run fires it now.
  func resume(_ ids: [UUID]) {
    guard enabled() else { return }
    for id in ids where !queue.contains(id) && activeMeetingID != id {
      guard queue.count < Self.queueCapacity else { break }
      queue.append(id)
      triggers[id] = .retry
      pendingSettle.insert(id)
    }
    pump()
  }

  /// The detail view shows this meeting; its stored state becomes `status`.
  func observe(meetingID id: UUID) async {
    if status?.meetingID != id {
      status = IdentificationStatus(meetingID: id, state: .notRequested)
    }
    await refresh(id)
  }

  /// A confirmation or correction changed the meeting's effective identities —
  /// adopted run results, enrollments and every manual action funnel here, so
  /// the evidence-change notice goes out exactly once per write.
  func identitiesDidChange(meetingID id: UUID) {
    if status?.meetingID == id { status?.identityRevision += 1 }
    intelligence?.evidenceDidChange(meetingID: id)
  }

  func shutdown() async {
    await identifier.prepareForShutdown()
    queue.removeAll()
    pastSearch.removeAll()
    retry?.cancel()
    for pending in enrollments { pending.continuation.resume(returning: .failed(.interrupted)) }
    enrollments.removeAll()
    await stopActive()
  }

  // MARK: Enrollment (US1)

  /// Queue-ordered, with a lease of its own; runs before the next identification run.
  func enroll(_ request: EnrollmentRequest) async -> EnrollmentOutcome {
    guard enabled() else { return .disabled }
    if status?.meetingID == request.meetingID { status?.enrolling = true }
    let outcome = await withCheckedContinuation { continuation in
      enrollments.append(PendingEnrollment(request: request, continuation: continuation))
      pump()
    }
    if status?.meetingID == request.meetingID, activeEnrollment == nil,
      !enrollments.contains(where: { $0.request.meetingID == request.meetingID })
    {
      status?.enrolling = false
    }
    return outcome
  }

  // MARK: Past search (US6, R10)

  /// Look for this voice in past meetings: every meeting with an Unknown remote root,
  /// newest first, queued for one run at a time. Returns how many were queued.
  func startPastSearch(knownSpeakerID: UUID) async -> Int {
    guard enabled() else { return 0 }
    let name = (try? await store.knownSpeakers().first { $0.id == knownSpeakerID }?.name) ?? ""
    let meetings =
      (try? await store.meetingsWithUnknownRemoteSpeakers(limit: Self.pastSearchCapacity)) ?? []
    pastSearch = Array(meetings.filter { $0 != activeMeetingID }.prefix(Self.pastSearchCapacity))
    pastSearchName = name
    let queued = pastSearch.count
    if let id = status?.meetingID { await refresh(id) }
    pump()
    return queued
  }

  func cancelPastSearch() {
    pastSearch.removeAll()
    pastSearchName = nil
    if let id = status?.meetingID { Task { await refresh(id) } }
  }

  // MARK: Queue

  /// True when the meeting is queued or running at the end — false when admission
  /// was refused and no run will come of it.
  @discardableResult
  private func enqueue(_ id: UUID, trigger: IdentificationTrigger) async -> Bool {
    guard !queue.contains(id), activeMeetingID != id else { return true }
    // The active run counts against the bound; a busy retry puts it back at the head.
    guard queue.count + (activeMeetingID == nil ? 0 : 1) < Self.queueCapacity else {
      // An automatic request just leaves the meeting as it was; a manual one is told.
      noticePublished?(Self.queueFullNotice)
      return false
    }
    do {
      guard try await identifier.admit(meetingID: id, trigger: trigger) != nil else {
        return false
      }
    } catch IdentityStore.Error.runInProgress {
      // Already pending (for example from reconciliation): queue it once.
    } catch {
      logger.notice("Identification admission refused")
      if trigger != .automatic { noticePublished?("Speakers can't be identified right now.") }
      return false
    }
    guard !queue.contains(id), activeMeetingID != id else { return true }
    queue.append(id)
    triggers[id] = trigger
    await refresh(id)
    pump()
    return true
  }

  private func pump() {
    guard task == nil, retry == nil else { return }
    if let next = enrollments.first {
      enrollments.removeFirst()
      startEnrollment(next)
      return
    }
    var meetingID: UUID?
    var pastSearchRun = false
    if !queue.isEmpty {
      meetingID = queue.removeFirst()
    } else if !pastSearch.isEmpty {
      meetingID = pastSearch.removeFirst()
      pastSearchRun = true
    }
    guard let id = meetingID else { return }
    activeMeetingID = id
    let identifier = identifier
    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, planned in
      Task { @MainActor in self?.report(id, done: done, planned: planned) }
    }
    task = Task { [weak self] in
      var outcome: MeetingIdentifier.Outcome
      if pastSearchRun {
        do {
          guard try await identifier.admit(meetingID: id, trigger: .pastSearch) != nil else {
            await self?.finish(id, outcome: .skipped)
            return
          }
        } catch IdentityStore.Error.runInProgress {
        } catch {
          await self?.finish(id, outcome: .skipped)
          return
        }
      }
      outcome = await identifier.run(meetingID: id, progress: progress)
      await self?.finish(id, outcome: outcome)
    }
    startRSSSampler()
  }

  private func startEnrollment(_ pending: PendingEnrollment) {
    activeEnrollment = pending
    activeMeetingID = pending.request.meetingID
    let enrollment = enrollment
    let id = pending.request.meetingID
    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, planned in
      Task { @MainActor in self?.report(id, done: done, planned: planned, enrolling: true) }
    }
    task = Task { [weak self] in
      let result = await enrollment.run(pending.request, progress: progress)
      await self?.finishEnrollment(pending, result: result)
    }
    startRSSSampler()
  }

  private func finishEnrollment(_ pending: PendingEnrollment, result: EnrollmentJob.Result) async {
    task = nil
    activeEnrollment = nil
    activeMeetingID = nil
    rssTask?.cancel()
    rssTask = nil
    switch result {
    case .busy, .preempted:
      pending.attempts += 1
      if pending.attempts < Self.enrollmentAttempts, !cancelled.contains(pending.request.meetingID)
      {
        enrollments.insert(pending, at: 0)
        scheduleRetry()
      } else {
        pending.continuation.resume(returning: .failed(.modelUnavailable))
      }
    case .outcome(let outcome, let knownSpeakerID):
      pending.continuation.resume(returning: outcome)
      if case .stored(let count) = outcome, count >= 1, let knownSpeakerID {
        let name = (try? await store.knownSpeakers().first { $0.id == knownSpeakerID }?.name) ?? ""
        enrollmentDidStore?(knownSpeakerID, name)
      }
    }
    cancelled.remove(pending.request.meetingID)
    await refresh(pending.request.meetingID)
    identitiesDidChange(meetingID: pending.request.meetingID)
    pump()
  }

  private func startRSSSampler() {
    guard rssTask == nil, let recorder else { return }
    let clock = clock
    rssTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: Self.rssInterval) } catch { return }
        guard let self, self.activeMeetingID != nil else { return }
        recorder.record(phase: .identifying, rssBytes: ResourceRecorder.residentBytes())
      }
    }
  }

  private func report(_ id: UUID, done: Int, planned: Int, enrolling: Bool = false) {
    guard status?.meetingID == id, activeMeetingID == id, planned > 0 else { return }
    if enrolling {
      status?.enrolling = true
    } else {
      status?.state = .running
      status?.progress = Double(done) / Double(planned)
    }
  }

  private func finish(_ id: UUID, outcome: MeetingIdentifier.Outcome) async {
    task = nil
    activeMeetingID = nil
    rssTask?.cancel()
    rssTask = nil
    switch outcome {
    case .preempted, .busy:
      // Back to the head; the model is someone else's for now.
      if !cancelled.contains(id) {
        queue.insert(id, at: 0)
        scheduleRetry()
      }
    case .succeeded:
      identitiesDidChange(meetingID: id)
      if pendingSettle.remove(id) != nil {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    case .failed, .cancelled, .nothingToRun, .skipped:
      if pendingSettle.remove(id) != nil {
        intelligence?.meetingSpeakersDidSettle(id: id)
      }
    }
    if outcome != .busy, outcome != .preempted { triggers[id] = nil }
    cancelled.remove(id)
    await refresh(id)
    // The past-search line on the displayed meeting follows runs of other meetings.
    if let displayed = status?.meetingID, displayed != id { await refresh(displayed) }
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
    var failure: IdentificationFailureCategory?
    if state == .failed || state == .interrupted {
      failure = try? await store.latestRun(meetingID: id)?.failureCategory
    }
    guard status?.meetingID == id else { return }
    status?.state = state
    status?.failure = failure
    if state != .running { status?.progress = nil }
    status?.enrolling =
      activeEnrollment?.request.meetingID == id
      || enrollments.contains { $0.request.meetingID == id }
    if let name = pastSearchName, !pastSearch.isEmpty || activeMeetingID != nil {
      status?.pastSearch = .init(name: name, remaining: pastSearch.count)
    } else {
      status?.pastSearch = nil
      if pastSearch.isEmpty { pastSearchName = nil }
    }
  }
}

/// contracts/ui.md "Status line": one content-free sentence per failure category.
enum IdentificationFailureMessage {
  static func message(for category: IdentificationFailureCategory) -> String {
    switch category {
    case .modelUnavailable:
      "Speaker labeling model isn't installed. Install it in Settings → Models."
    case .osUnsupported: "Speaker identification needs macOS 15 or later."
    case .modelLoadFailure: "The voice model couldn't be loaded."
    case .audioMissing: "This meeting's audio isn't available, so speakers can't be identified."
    case .audioDecodeFailure: "This meeting's audio couldn't be read."
    case .runtimeFailure: "Speaker identification stopped unexpectedly."
    case .diarizationChanged: "Speaker labels changed while speakers were being identified."
    case .persistenceFailure: "Speaker identities couldn't be saved."
    case .persistenceCapacity: "Speaker identities couldn't be saved. Meeting storage is full."
    case .interrupted: "Speaker identification was interrupted."
    }
  }

  static func isRetryable(_ category: IdentificationFailureCategory) -> Bool {
    category != .osUnsupported
  }
}
