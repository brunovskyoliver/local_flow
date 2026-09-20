import Foundation

/// The sole owner of runtime creation, leases, inference and release. One lease and one
/// resident runtime at a time, keyed by workload: speech models and diarization are
/// never resident together (FR-032, ADR 0017).
actor ModelLifecycleCoordinator {
  enum State: Sendable, Equatable { case unloaded, preparing, active, cooling, releasing }
  typealias Factory = @Sendable () async throws -> any TranscriptionRuntime
  typealias DiarizationFactory = @Sendable () async throws -> any DiarizationRuntime

  private enum Resident: Sendable {
    case speech(any TranscriptionRuntime)
    case meeting(any TranscriptionRuntime)
    case diarization(any DiarizationRuntime)

    var workload: ModelWorkload {
      switch self {
      case .speech: .speechRecognition
      case .meeting: .meetingTranscription
      case .diarization: .diarization
      }
    }

    func shutdown() async {
      switch self {
      case .speech(let runtime), .meeting(let runtime): await runtime.shutdown()
      case .diarization(let runtime): await runtime.shutdown()
      }
    }
  }

  private let factory: Factory
  private let meetingFactory: Factory
  private let diarizationFactory: DiarizationFactory
  private let clock: any DictationClock
  private let observe: @Sendable (State, ModelWorkload, UInt64) -> Void
  private var stateStarted = DispatchTime.now().uptimeNanoseconds
  private var runtime: Resident?
  private var loading: Task<Resident, Error>?
  private var inference: Task<TranscriptionWindow, Error>?
  private var diarizing: Task<DiarizationWindowResult, Error>?
  /// The workload of the runtime being prepared, used or released.
  private var workload: ModelWorkload = .speechRecognition
  private var observedWorkload: ModelWorkload = .speechRecognition
  private var release: Task<Void, Never>?
  private var cooldown: Task<Void, Never>?
  private var cooldownGeneration: UInt64 = 0
  private var keepLoaded = false
  private var owner: ModelLease?
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
    meetingFactory: @escaping Factory = { throw DictationFailure.modelUnavailable },
    factory: @escaping Factory
  ) {
    self.clock = clock
    self.factory = factory
    self.meetingFactory = meetingFactory
    self.diarizationFactory = diarizationFactory
    self.observe = observe
  }

  struct Snapshot: Sendable {
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
    defer { installing = false }
    await beginRelease()
  }

  /// Both speech workloads preempt a diarization lease: ownership moves to the new lease
  /// before any suspension, then the revoked lease's in-flight window is joined and its
  /// runtime released. A diarization acquire never preempts.
  func acquire(session: UUID, workload requested: ModelWorkload = .speechRecognition)
    async throws -> ModelLease
  {
    guard !Task.isCancelled else { throw DictationFailure.cancelled }
    let preempts =
      requested != .diarization && owner?.workload == .diarization && !installing
    guard owner == nil || preempts, !installing else { throw DictationFailure.busy }
    generation &+= 1
    let lease = ModelLease(sessionID: session, generation: generation, workload: requested)
    owner = lease
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
        if resident.workload == requested {
          state = .active
          return lease
        }
        // A workload switch releases the resident runtime before preparing the other.
        await beginRelease()
        if Task.isCancelled { await cancelAndJoin(lease) }
        guard owner == lease else { throw DictationFailure.cancelled }
      }
      workload = requested
      state = .preparing
      let factory = factory
      let meetingFactory = meetingFactory
      let diarizationFactory = diarizationFactory
      let task = Task { () throws -> Resident in
        switch requested {
        case .speechRecognition: return .speech(try await factory())
        case .meetingTranscription: return .meeting(try await meetingFactory())
        case .diarization: return .diarization(try await diarizationFactory())
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
    case .speech(let value), .meeting(let value): runtime = value
    default: throw DictationFailure.staleLease
    }
    guard inference == nil else { throw DictationFailure.busy }
    let maximum = lease.workload == .meetingTranscription ? 1_920_000 : 239_360
    guard !samples.isEmpty, samples.count <= maximum, samples.allSatisfy(\.isFinite) else {
      throw DictationFailure.invalidAudio
    }
    let task = Task { try await runtime.transcribe(samples) }
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

  /// Live speech cools down; meeting and diarization leases release at once, then
  /// Keep model ready re-prepares the live speech runtime.
  func finish(_ lease: ModelLease) async throws {
    guard owner == lease else { throw DictationFailure.staleLease }
    guard inference == nil, diarizing == nil, loading == nil else {
      throw DictationFailure.busy
    }
    owner = nil
    guard lease.workload != .speechRecognition else {
      state = .cooling
      scheduleCooldown()
      return
    }
    await beginRelease()
    if keepLoaded, owner == nil, !installing {
      Task { try? await self.loadIfIdle() }
    }
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
    await beginRelease()
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
    defer { installing = false }
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
    runtime = nil
    loading = nil
    inference = nil
    diarizing = nil
    pendingLoad?.cancel()
    pendingInference?.cancel()
    pendingWindow?.cancel()
    let task = Task {
      // Cancellation cannot interrupt every CoreML call. Join before shutdown.
      _ = await pendingInference?.result
      _ = await pendingWindow?.result
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
