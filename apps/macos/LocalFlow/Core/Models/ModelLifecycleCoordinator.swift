import Foundation

/// The sole owner of runtime creation, leases, inference and release.
actor ModelLifecycleCoordinator {
  enum State: Sendable, Equatable { case unloaded, preparing, active, cooling, releasing }
  typealias Factory = @Sendable () async throws -> any TranscriptionRuntime

  private let factory: Factory
  private let clock: any DictationClock
  private let observe: @Sendable (State, UInt64) -> Void
  private var stateStarted = DispatchTime.now().uptimeNanoseconds
  private var runtime: (any TranscriptionRuntime)?
  private var loading: Task<any TranscriptionRuntime, Error>?
  private var inference: Task<TranscriptionWindow, Error>?
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
      observe(oldValue, now &- stateStarted)
      stateStarted = now
      observe(state, 0)
    }
  }

  init(
    clock: any DictationClock = SystemDictationClock(),
    observe: @escaping @Sendable (State, UInt64) -> Void = { _, _ in },
    factory: @escaping Factory
  ) {
    self.clock = clock
    self.factory = factory
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
    Snapshot(state: state, loaded: runtime != nil, leased: owner != nil, installing: installing)
  }

  /// Admission and acquisition run on this actor before the first suspension.
  func loadIfIdle() async throws {
    guard owner == nil, !installing, state == .unloaded || state == .cooling else {
      throw DictationFailure.busy
    }
    let lease = try await acquire(session: UUID())
    try finish(lease)
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

  func acquire(session: UUID) async throws -> ModelLease {
    guard !Task.isCancelled else { throw DictationFailure.cancelled }
    guard owner == nil, !installing else { throw DictationFailure.busy }
    generation &+= 1
    let lease = ModelLease(sessionID: session, generation: generation)
    owner = lease
    return try await withTaskCancellationHandler {
      cooldown?.cancel()
      cooldown = nil
      if let pending = release {
        await pending.value
        if Task.isCancelled { await cancelAndJoin(lease) }
        guard owner == lease else { throw DictationFailure.cancelled }
        release = nil
      }
      if runtime != nil {
        state = .active
        return lease
      }
      state = .preparing
      let task = Task { try await factory() }
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
    guard owner == lease, state == .active, let runtime else {
      throw DictationFailure.staleLease
    }
    guard inference == nil else { throw DictationFailure.busy }
    guard !samples.isEmpty, samples.count <= 239_360, samples.allSatisfy(\.isFinite) else {
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

  func finish(_ lease: ModelLease) throws {
    guard owner == lease else { throw DictationFailure.staleLease }
    guard inference == nil, loading == nil else { throw DictationFailure.busy }
    owner = nil
    state = .cooling
    scheduleCooldown()
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
    runtime = nil
    loading = nil
    inference = nil
    pendingLoad?.cancel()
    pendingInference?.cancel()
    let task = Task {
      // Cancellation cannot interrupt every CoreML call. Join before shutdown.
      _ = await pendingInference?.result
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
