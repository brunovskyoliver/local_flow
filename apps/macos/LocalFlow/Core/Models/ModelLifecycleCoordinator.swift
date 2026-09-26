import Foundation

/// The sole owner of runtime creation, leases, inference and release. One lease and one
/// resident runtime at a time, keyed by workload: speech models, diarization and the
/// voice embedder are never resident together (FR-032, ADR 0017, ADR 0020).
actor ModelLifecycleCoordinator {
  enum State: Sendable, Equatable { case unloaded, preparing, active, cooling, releasing }
  typealias Factory = @Sendable () async throws -> any TranscriptionRuntime
  typealias DiarizationFactory = @Sendable () async throws -> any DiarizationRuntime

  private enum Resident: Sendable {
    case speech(any TranscriptionRuntime)
    case meeting(any TranscriptionRuntime, MeetingLanguage)
    case diarization(any DiarizationRuntime)
    case embedding(any VoiceEmbeddingRuntime)

    var workload: ModelWorkload {
      switch self {
      case .speech: .speechRecognition
      case .meeting: .meetingTranscription
      case .diarization: .diarization
      case .embedding: .speakerIdentification
      }
    }

    /// The language a meeting runtime decodes in; nil for every other workload.
    var meetingLanguage: MeetingLanguage? {
      if case .meeting(_, let language) = self { return language }
      return nil
    }

    func shutdown() async {
      switch self {
      case .speech(let runtime), .meeting(let runtime, _): await runtime.shutdown()
      case .diarization(let runtime): await runtime.shutdown()
      case .embedding(let runtime): await runtime.shutdown()
      }
    }
  }

  private let factory: Factory
  /// Receives the language the acquiring pass recorded in its pipeline version, so
  /// the runtime decodes in exactly that language.
  typealias MeetingFactory = @Sendable (MeetingLanguage) async throws -> any TranscriptionRuntime
  private let meetingFactory: MeetingFactory
  private let diarizationFactory: DiarizationFactory
  private let voiceEmbeddingFactory: VoiceEmbeddingFactory
  private let clock: any DictationClock
  private let observe: @Sendable (State, ModelWorkload, UInt64) -> Void
  private var stateStarted = DispatchTime.now().uptimeNanoseconds
  private var runtime: Resident?
  private var loading: Task<Resident, Error>?
  private var inference: Task<TranscriptionWindow, Error>?
  private var diarizing: Task<DiarizationWindowResult, Error>?
  private var embedding: Task<VoiceEmbedding, Error>?
  /// The workload of the runtime being prepared, used or released.
  private var workload: ModelWorkload = .speechRecognition
  private var observedWorkload: ModelWorkload = .speechRecognition
  private var release: Task<Void, Never>?
  private var cooldown: Task<Void, Never>?
  private var cooldownGeneration: UInt64 = 0
  private var keepLoaded = false
  private var owner: ModelLease?
  /// The lease Keep model ready took to re-prepare live speech after other work.
  /// Nobody waits on it, so diarization and identification preempt it.
  private var warmLease: ModelLease?
  private var boost: (lease: ModelLease, terms: VocabularyBoostTerms)?
  /// Speaker work queued or running, by coordinator token with the newest sequence
  /// seen. While any is pending, Keep model ready does not reload live speech between
  /// leases; the last withdrawal triggers the reload instead.
  private var speakerDemand: [UUID: (sequence: UInt64, pending: Bool)] = [:]
  /// Callers of `waitUntilAvailable`, resumed when no lease is held and no install is
  /// running. Bounded: past the capacity a caller returns at once and relies on its
  /// own fallback delay.
  private var availabilityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  static let availabilityWaiterCapacity = 16
  private var installing = false
  private(set) var generation: UInt64 = 0
  private(set) var state: State = .unloaded {
    didSet {
      guard oldValue != state else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      observe(oldValue, observedWorkload, now &- stateStarted)
      stateStarted = now
      observedWorkload = workload
      observe(state, workload, 0)
    }
  }

  init(
    clock: any DictationClock = SystemDictationClock(),
    observe: @escaping @Sendable (State, ModelWorkload, UInt64) -> Void = { _, _, _ in },
    diarizationFactory: @escaping DiarizationFactory = { throw DictationFailure.modelUnavailable },
    voiceEmbeddingFactory: @escaping VoiceEmbeddingFactory = {
      throw DictationFailure.modelUnavailable
    },
    meetingFactory: @escaping MeetingFactory = { _ in throw DictationFailure.modelUnavailable },
    factory: @escaping Factory
  ) {
    self.clock = clock
    self.factory = factory
    self.meetingFactory = meetingFactory
    self.diarizationFactory = diarizationFactory
    self.voiceEmbeddingFactory = voiceEmbeddingFactory
    self.observe = observe
  }

  struct Snapshot: Sendable, Equatable {
    let state: State
    let loaded: Bool
    let leased: Bool
    let installing: Bool
    var controlsAvailable: Bool {
      !leased && !installing && (state == .unloaded || state == .cooling)
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      state: state, loaded: runtime?.workload == .speechRecognition, leased: owner != nil,
      installing: installing)
  }

  /// Admission and acquisition run on this actor before the first suspension.
  func loadIfIdle() async throws {
    guard owner == nil, !installing, state == .unloaded || state == .cooling else {
      throw DictationFailure.busy
    }
    let lease = try await acquire(session: UUID())
    try await finish(lease)
  }

  func unloadIfIdle() async throws {
    guard owner == nil, !installing, state == .unloaded || state == .cooling else {
      throw DictationFailure.busy
    }
    // beginRelease changes state before suspending; acquire joins that release.
    await beginRelease()
  }

  /// Application termination also joins an already-running cooldown release.
  func shutdownIfIdle() async throws {
    guard owner == nil, !installing else { throw DictationFailure.busy }
    installing = true
    defer {
      installing = false
      notifyAvailable()
    }
    await beginRelease()
  }

  /// Both speech workloads preempt a diarization or identification lease: ownership
  /// moves to the new lease before any suspension, then the revoked lease's in-flight
  /// window is joined and its runtime released. A diarization or identification acquire
  /// preempts only Keep model ready's own background reload of live speech.
  /// `meetingLanguage` applies to `.meetingTranscription` only: a resident meeting
  /// runtime built for another language is released and rebuilt.
  /// `boost` is the dictation's Dictionary for the keyword spotter (Feature 013); it is
  /// bound to the returned lease and never outlives it.
  func acquire(
    session: UUID, workload requested: ModelWorkload = .speechRecognition,
    meetingLanguage: MeetingLanguage = .defaultLanguage, boost: VocabularyBoostTerms? = nil
  )
    async throws -> ModelLease
  {
    try await acquire(
      session: session, workload: requested, meetingLanguage: meetingLanguage, warm: false,
      boost: boost)
  }

  /// `warm` marks Keep model ready's own reload, which speaker work may preempt.
  private func acquire(
    session: UUID, workload requested: ModelWorkload, meetingLanguage: MeetingLanguage,
    warm: Bool, boost: VocabularyBoostTerms? = nil
  ) async throws -> ModelLease {
    let requestedLanguage = requested == .meetingTranscription ? meetingLanguage : nil
    guard !Task.isCancelled else { throw DictationFailure.cancelled }
    let preemptsWarm = !requested.isSpeech && owner != nil && owner == warmLease
    let preempts =
      (requested.isSpeech && owner?.workload.isSpeech == false || preemptsWarm) && !installing
    guard owner == nil || preempts, !installing else { throw DictationFailure.busy }
    generation &+= 1
    let lease = ModelLease(sessionID: session, generation: generation, workload: requested)
    owner = lease
    warmLease = warm ? lease : nil
    self.boost = boost.map { (lease, $0) }
    return try await withTaskCancellationHandler {
      cooldown?.cancel()
      cooldown = nil
      if preempts {
        await beginRelease()
        if Task.isCancelled { await cancelAndJoin(lease) }
        guard owner == lease else { throw DictationFailure.cancelled }
      }
      if let pending = release {
        await pending.value
        if Task.isCancelled { await cancelAndJoin(lease) }
        guard owner == lease else { throw DictationFailure.cancelled }
        release = nil
      }
      if let resident = runtime {
        if resident.workload == requested, resident.meetingLanguage == requestedLanguage {
          state = .active
          return lease
        }
        // A workload or language switch releases the resident runtime before preparing
        // the other.
        await beginRelease()
        if Task.isCancelled { await cancelAndJoin(lease) }
        guard owner == lease else { throw DictationFailure.cancelled }
      }
      workload = requested
      state = .preparing
      let factory = factory
      let meetingFactory = meetingFactory
      let diarizationFactory = diarizationFactory
      let voiceEmbeddingFactory = voiceEmbeddingFactory
      let task = Task { () throws -> Resident in
        switch requested {
        case .speechRecognition: return .speech(try await factory())
        case .meetingTranscription:
          return .meeting(try await meetingFactory(meetingLanguage), meetingLanguage)
        case .diarization: return .diarization(try await diarizationFactory())
        case .speakerIdentification: return .embedding(try await voiceEmbeddingFactory())
        }
      }
      loading = task
      do {
        let loaded = try await task.value
        if Task.isCancelled { await cancelAndJoin(lease) }
        // cancelAndJoin owns the task result and its cleanup after revocation.
        guard owner == lease, state == .preparing else { throw DictationFailure.cancelled }
        loading = nil
        runtime = loaded
        state = .active
        return lease
      } catch {
        if owner == lease {
          loading = nil
          owner = nil
          state = .unloaded
          notifyAvailable()
        }
        throw error
      }
    } onCancel: {
      Task { await self.cancelAndJoin(lease) }
    }
  }

  func transcribe(_ lease: ModelLease, samples: [Float]) async throws -> TranscriptionWindow {
    guard owner == lease, state == .active else {
      throw DictationFailure.staleLease
    }
    let runtime: any TranscriptionRuntime
    switch self.runtime {
    case .speech(let value), .meeting(let value, _): runtime = value
    default: throw DictationFailure.staleLease
    }
    guard inference == nil else { throw DictationFailure.busy }
    let maximum = lease.workload == .meetingTranscription ? 1_920_000 : 239_360
    guard !samples.isEmpty, samples.count <= maximum, samples.allSatisfy(\.isFinite) else {
      throw DictationFailure.invalidAudio
    }
    let terms = boost?.lease == lease ? boost?.terms : nil
    let task = Task { try await runtime.transcribe(samples, boost: terms) }
    inference = task
    do {
      let result = try await task.value
      guard owner == lease, state == .active else { throw DictationFailure.cancelled }
      inference = nil
      guard result.text.utf8.count <= 65_536, result.tokens.count <= 16_384 else {
        throw DictationFailure.invalidResult
      }
      return result
    } catch {
      if owner == lease { inference = nil }
      throw error
    }
  }

  /// Settings › Models › Test: load the workload's runtime, run one second of
  /// silence through a speech model, then release it. Loading alone proves the
  /// speaker models; silence would only exercise their empty-result path.
  func smokeTest(_ workload: ModelWorkload) async throws {
    let lease = try await acquire(session: UUID(), workload: workload)
    do {
      if workload.isSpeech {
        _ = try await transcribe(lease, samples: [Float](repeating: 0, count: 16_000))
      }
    } catch {
      try? await finish(lease)
      throw error
    }
    try await finish(lease)
  }

  /// The only diarization inference entry. One window at a time; request bounds are
  /// checked before the runtime sees them.
  func diarize(_ lease: ModelLease, window request: DiarizationWindowRequest) async throws
    -> DiarizationWindowResult
  {
    guard owner == lease, state == .active, case .diarization(let runtime) = self.runtime else {
      throw DictationFailure.staleLease
    }
    guard diarizing == nil else { throw DictationFailure.busy }
    guard request.isValid else { throw DictationFailure.invalidAudio }
    let task = Task { try await runtime.diarize(request) }
    diarizing = task
    do {
      let result = try await task.value
      guard owner == lease, state == .active else { throw DictationFailure.cancelled }
      diarizing = nil
      guard result.isValid else { throw DictationFailure.invalidResult }
      return result
    } catch {
      if owner == lease { diarizing = nil }
      throw error
    }
  }

  /// The only voice embedding inference entry (Feature 010). One region at a time;
  /// request and result bounds are checked before and after the runtime sees them.
  func embed(_ lease: ModelLease, region request: VoiceRegionRequest) async throws
    -> VoiceEmbedding
  {
    guard owner == lease, state == .active, case .embedding(let runtime) = self.runtime else {
      throw DictationFailure.staleLease
    }
    guard embedding == nil else { throw DictationFailure.busy }
    guard request.isValid else { throw DictationFailure.invalidAudio }
    let task = Task { try await runtime.embed(request) }
    embedding = task
    do {
      let result = try await task.value
      guard owner == lease, state == .active else { throw DictationFailure.cancelled }
      embedding = nil
      guard result.isValid else { throw DictationFailure.invalidResult }
      return result
    } catch {
      if owner == lease { embedding = nil }
      throw error
    }
  }

  /// Live speech cools down; meeting, diarization and identification leases release at
  /// once, then Keep model ready re-prepares the live speech runtime unless speaker
  /// work is still queued.
  func finish(_ lease: ModelLease) async throws {
    guard owner == lease else { throw DictationFailure.staleLease }
    guard inference == nil, diarizing == nil, embedding == nil, loading == nil else {
      throw DictationFailure.busy
    }
    owner = nil
    if warmLease == lease { warmLease = nil }
    guard lease.workload != .speechRecognition else {
      state = .cooling
      scheduleCooldown()
      notifyAvailable()
      return
    }
    notifyAvailable()
    await beginRelease()
    warmIfNeeded()
  }

  /// Keep model ready re-prepares live speech once nothing else wants the model:
  /// not while a lease is held, an install runs, or speaker work is still queued.
  private func warmIfNeeded() {
    guard keepLoaded, owner == nil, !installing, state == .unloaded, !hasSpeakerDemand else {
      return
    }
    Task { await self.warm() }
  }

  private func warm() async {
    guard keepLoaded, owner == nil, !installing, state == .unloaded || state == .cooling,
      !hasSpeakerDemand
    else { return }
    guard
      let lease = try? await acquire(
        session: UUID(), workload: .speechRecognition, meetingLanguage: .defaultLanguage,
        warm: true)
    else { return }
    try? await finish(lease)
  }

  private var hasSpeakerDemand: Bool { speakerDemand.values.contains { $0.pending } }

  /// Speaker coordinators report whether they have work queued or running. Updates
  /// may arrive out of order, so only a newer sequence for a token applies.
  func setSpeakerDemand(_ token: UUID, pending: Bool, sequence: UInt64) {
    if let current = speakerDemand[token], current.sequence >= sequence { return }
    speakerDemand[token] = (sequence, pending)
    if !pending { warmIfNeeded() }
  }

  /// Returns once no lease is held and no install is running, or at once when that is
  /// already true or the caller is cancelled. Speaker coordinators await this after a
  /// busy acquire instead of polling on a timer.
  func waitUntilAvailable() async {
    guard owner != nil || installing, !Task.isCancelled,
      availabilityWaiters.count < Self.availabilityWaiterCapacity
    else { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          availabilityWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.resumeWaiter(id) }
    }
  }

  private func resumeWaiter(_ id: UUID) {
    availabilityWaiters.removeValue(forKey: id)?.resume()
  }

  private func notifyAvailable() {
    guard owner == nil, !installing, !availabilityWaiters.isEmpty else { return }
    let waiters = availabilityWaiters.values
    availabilityWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func setKeepLoaded(_ enabled: Bool) {
    keepLoaded = enabled
    cooldownGeneration &+= 1
    cooldown?.cancel()
    cooldown = nil
    if !enabled, owner == nil, state == .cooling { scheduleCooldown() }
  }

  private func scheduleCooldown() {
    cooldownGeneration &+= 1
    cooldown?.cancel()
    cooldown = nil
    guard !keepLoaded else { return }
    let deadline = cooldownGeneration
    let expected = generation
    let clock = clock
    cooldown = Task { [weak self] in
      do {
        try await clock.sleep(for: .seconds(30))
        try Task.checkCancellation()
        await self?.releaseIfIdle(generation: expected, deadline: deadline)
      } catch {
        // A new lease invalidates this deadline.
      }
    }
  }

  func cancelSessionAndJoin(_ session: UUID) async {
    if let lease = owner, lease.sessionID == session {
      await cancelAndJoin(lease)
    } else if release != nil {
      // Ownership is revoked before shutdown finishes. Repeated cancellation
      // still joins that shutdown instead of returning while work is alive.
      await beginRelease()
    }
  }

  func cancelAndJoin(_ lease: ModelLease) async {
    guard owner == lease else {
      if release != nil { await beginRelease() }
      return
    }
    owner = nil
    notifyAvailable()
    await beginRelease()
  }

  /// Ends a live speech lease whose session was cancelled or left incomplete without
  /// discarding a healthy runtime: an in-flight window is cancelled and joined, then the
  /// runtime cools down exactly as after `finish`, so Keep model ready still holds. A
  /// pending load, a window that failed for any reason other than cancellation, or any
  /// other workload releases as `cancelAndJoin` does.
  func cancelAndCool(_ lease: ModelLease) async {
    var healthy =
      owner == lease && lease.workload == .speechRecognition && state == .active
      && loading == nil
    if healthy { healthy = await interruptInference(lease) }
    guard healthy, owner == lease, state == .active, loading == nil, inference == nil else {
      await cancelAndJoin(lease)
      return
    }
    owner = nil
    state = .cooling
    scheduleCooldown()
    notifyAvailable()
  }

  /// Cancels and joins the lease's in-flight speech window, keeping the lease and its
  /// runtime. False when that window failed for a reason other than cancellation, which
  /// callers treat as a runtime fault, or when the lease is no longer current.
  func interruptInference(_ lease: ModelLease) async -> Bool {
    guard owner == lease else { return false }
    guard let pending = inference else { return true }
    pending.cancel()
    let outcome = await pending.result
    if owner == lease, inference == pending { inference = nil }
    switch outcome {
    case .success: return true
    case .failure(let error):
      return error is CancellationError || error as? DictationFailure == .cancelled
    }
  }

  func releaseIfIdle(generation expected: UInt64, deadline: UInt64? = nil) async {
    guard !keepLoaded, generation == expected, owner == nil, state == .cooling,
      deadline == nil || deadline == cooldownGeneration
    else { return }
    await beginRelease()
  }

  func installModel(_ operation: @Sendable () async throws -> Void) async throws {
    guard owner == nil, !installing else { throw DictationFailure.busy }
    installing = true
    defer {
      installing = false
      notifyAvailable()
    }
    await beginRelease()
    try Task.checkCancellation()
    try await operation()
  }

  private func beginRelease() async {
    cooldown?.cancel()
    cooldown = nil
    if let pending = release {
      let expected = generation
      await pending.value
      if generation == expected, owner == nil {
        release = nil
        state = .unloaded
      }
      return
    }
    state = .releasing
    let expected = generation
    let current = runtime
    let pendingLoad = loading
    let pendingInference = inference
    let pendingWindow = diarizing
    let pendingRegion = embedding
    runtime = nil
    loading = nil
    inference = nil
    diarizing = nil
    embedding = nil
    pendingLoad?.cancel()
    pendingInference?.cancel()
    pendingWindow?.cancel()
    pendingRegion?.cancel()
    let task = Task {
      // Cancellation cannot interrupt every CoreML call. Join before shutdown.
      _ = await pendingInference?.result
      _ = await pendingWindow?.result
      _ = await pendingRegion?.result
      let loaded = try? await pendingLoad?.value
      if let current { await current.shutdown() } else if let loaded { await loaded.shutdown() }
    }
    release = task
    await task.value
    if generation == expected {
      release = nil
      state = .unloaded
    }
  }
}

/// One speaker coordinator's link to the lifecycle: reports whether it has model work
/// queued or running, coalesced to the latest value per main-actor turn and sequenced
/// so late updates cannot overwrite newer ones.
@MainActor
final class SpeakerModelDemand {
  private let lifecycle: ModelLifecycleCoordinator
  private let token = UUID()
  private var pending = false
  private var sent = false
  private var sequence: UInt64 = 0
  private var scheduled = false

  init(lifecycle: ModelLifecycleCoordinator) {
    self.lifecycle = lifecycle
  }

  func update(pending: Bool) {
    self.pending = pending
    guard !scheduled else { return }
    scheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.scheduled = false
      guard self.pending != self.sent else { return }
      self.sent = self.pending
      self.sequence &+= 1
      await self.lifecycle.setSpeakerDemand(
        self.token, pending: self.sent, sequence: self.sequence)
    }
  }

  /// A busy or preempted run waits for the lifecycle to free the model, bounded by
  /// `fallback` in case the release is never signalled (for example a failed finish).
  nonisolated static func waitForRetry(_ demand: SpeakerModelDemand?, fallback: Duration) async {
    guard let lifecycle = demand?.lifecycle else {
      try? await Task.sleep(for: fallback)
      return
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await lifecycle.waitUntilAvailable() }
      group.addTask { try? await Task.sleep(for: fallback) }
      await group.next()
      group.cancelAll()
    }
  }
}
