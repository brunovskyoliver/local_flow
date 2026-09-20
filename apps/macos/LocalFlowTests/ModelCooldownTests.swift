import XCTest

@testable import LocalFlow

/// The cooldown deadline is a clock contract, not wall time. This clock returns
/// from one sleep only after the test advances past the requested duration, so
/// the 29.999/30-second boundary is exact and no test waits half a minute.
private actor ManualClock: DictationClock {
  private(set) var requested: [Duration] = []
  private var elapsed: Duration = .zero
  private var waiters: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    let deadline = elapsed + duration
    requested.append(duration)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if elapsed >= deadline {
          continuation.resume()
        } else {
          waiters.append((id, deadline, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func advance(to value: Duration) {
    elapsed = value
    var remaining: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []
    for waiter in waiters {
      if elapsed >= waiter.1 { waiter.2.resume() } else { remaining.append(waiter) }
    }
    waiters = remaining
  }

  func cancel(_ id: UUID) {
    // A late cancellation from an older timer must not cancel its replacement.
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).2.resume(throwing: CancellationError())
  }

  func waitUntilSleeping(count: Int) async {
    for _ in 0..<1000 {
      if requested.count >= count { return }
      await Task.yield()
    }
  }
}

final class ModelCooldownTests: XCTestCase {
  private func settle() async {
    for _ in 0..<200 { await Task.yield() }
  }

  func testKeepLoadedReusesRuntimeBeyondDeadlineAndAllowsExplicitUnload() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let built = Counter()
    let coordinator = ModelLifecycleCoordinator(clock: clock) {
      _ = await built.increment()
      return runtime
    }
    await coordinator.setKeepLoaded(true)
    try await coordinator.loadIfIdle()
    let generation = await coordinator.generation
    await clock.advance(to: .seconds(300))
    await coordinator.releaseIfIdle(generation: generation)
    let retained = await coordinator.snapshot()
    XCTAssertTrue(retained.loaded)
    let lease = try await coordinator.acquire(session: UUID())
    try await coordinator.finish(lease)
    let count = await built.value
    XCTAssertEqual(count, 1)
    let deadlines = await clock.requested
    XCTAssertTrue(deadlines.isEmpty)
    try await coordinator.unloadIfIdle()
    let unloaded = await coordinator.snapshot()
    XCTAssertFalse(unloaded.loaded)
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testEnablingRetentionInvalidatesTimerAndDisablingStartsFreshCooldown() async throws {
    let clock = ManualClock()
    let coordinator = ModelLifecycleCoordinator(clock: clock) { ProbeRuntime() }
    try await coordinator.loadIfIdle()
    await clock.waitUntilSleeping(count: 1)
    let generation = await coordinator.generation
    await coordinator.setKeepLoaded(true)
    await settle()
    await coordinator.releaseIfIdle(generation: generation)
    let retained = await coordinator.snapshot()
    XCTAssertTrue(retained.loaded)
    await clock.advance(to: .seconds(300))
    await coordinator.setKeepLoaded(false)
    await clock.waitUntilSleeping(count: 2)
    await clock.advance(to: .seconds(329))
    await settle()
    let before = await coordinator.snapshot()
    XCTAssertTrue(before.loaded)
    await clock.advance(to: .seconds(330))
    for _ in 0..<1000 {
      if await coordinator.state == .unloaded { break }
      await Task.yield()
    }
    let after = await coordinator.snapshot()
    XCTAssertFalse(after.loaded)
  }

  func testDiarizationFinishReleasesWithoutCooldown() async throws {
    let clock = ManualClock()
    let factory = FakeDiarizationFactory()
    let coordinator = ModelLifecycleCoordinator(
      clock: clock, diarizationFactory: { try await factory.make() }, factory: { ProbeRuntime() })
    let lease = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(lease)
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded, "Released at finish, not after 30 seconds")
    let shutdowns = await factory.runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)
    let deadlines = await clock.requested
    XCTAssertTrue(deadlines.isEmpty)
  }

  func testKeepModelReadyPreparesSpeechAgainAfterDiarization() async throws {
    let clock = ManualClock()
    let built = Counter()
    let factory = FakeDiarizationFactory()
    let coordinator = ModelLifecycleCoordinator(
      clock: clock, diarizationFactory: { try await factory.make() },
      factory: {
        _ = await built.increment()
        return ProbeRuntime()
      })
    await coordinator.setKeepLoaded(true)
    try await coordinator.loadIfIdle()
    let lease = try await coordinator.acquire(session: UUID(), workload: .diarization)
    let during = await coordinator.snapshot()
    XCTAssertFalse(during.loaded, "Retention does not license co-residency")
    try await coordinator.finish(lease)
    for _ in 0..<1000 {
      if await coordinator.snapshot().loaded { break }
      await Task.yield()
    }
    let after = await coordinator.snapshot()
    XCTAssertTrue(after.loaded)
    XCTAssertEqual(after.state, .cooling)
    let count = await built.value
    XCTAssertEqual(count, 2)
  }

  func testKeepLoadedStillReleasesOnCancellationAndShutdown() async throws {
    let coordinator = ModelLifecycleCoordinator { ProbeRuntime() }
    await coordinator.setKeepLoaded(true)
    let lease = try await coordinator.acquire(session: UUID())
    await coordinator.cancelAndJoin(lease)
    let cancelled = await coordinator.snapshot()
    XCTAssertFalse(cancelled.loaded)
    try await coordinator.loadIfIdle()
    try await coordinator.shutdownIfIdle()
    let stopped = await coordinator.snapshot()
    XCTAssertFalse(stopped.loaded)
  }

  /// 29.999 seconds must keep the runtime resident; 30 seconds must release it.
  func testRuntimeSurvivesUntilTheThirtySecondDeadline() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator(clock: clock) { runtime }
    let lease = try await coordinator.acquire(session: UUID())
    try await coordinator.finish(lease)
    await clock.waitUntilSleeping(count: 1)
    let requested = await clock.requested
    XCTAssertEqual(requested, [.seconds(30)])

    await clock.advance(to: .milliseconds(29_999))
    await settle()
    let beforeDeadline = await coordinator.state
    XCTAssertEqual(beforeDeadline, .cooling, "The deadline has not elapsed")
    let earlyShutdowns = await runtime.shutdowns
    XCTAssertEqual(earlyShutdowns, 0, "Releasing before 30 seconds discards a reusable runtime")

    await clock.advance(to: .seconds(30))
    for _ in 0..<1000 {
      if await coordinator.state == .unloaded { break }
      await Task.yield()
    }
    let afterDeadline = await coordinator.state
    XCTAssertEqual(afterDeadline, .unloaded)
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  /// A new lease invalidates the previous deadline. The expired timer must not
  /// release the runtime the new session is holding.
  func testExpiredTimerCannotReleaseANewerLease() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator(clock: clock) { runtime }
    let first = try await coordinator.acquire(session: UUID())
    try await coordinator.finish(first)
    await clock.waitUntilSleeping(count: 1)
    let second = try await coordinator.acquire(session: UUID())

    await clock.advance(to: .seconds(60))
    await settle()
    let state = await coordinator.state
    XCTAssertEqual(state, .active, "A stale deadline must not release an active lease")
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 0)
    // The stale generation is rejected even when it is delivered directly.
    await coordinator.releaseIfIdle(generation: first.generation)
    let unchanged = await coordinator.state
    XCTAssertEqual(unchanged, .active)
    let result = try await coordinator.transcribe(second, samples: [0.1])
    XCTAssertEqual(result.text, "test")
    await coordinator.cancelAndJoin(second)
  }

  /// A session arriving while release is running joins that shutdown and then
  /// builds a fresh runtime instead of handing out the one being torn down.
  func testSessionDuringReleaseWaitsThenGetsAFreshRuntime() async throws {
    let clock = ManualClock()
    let gate = PreparationGate()
    let first = CooldownGatedRuntime(gate: gate)
    let second = ProbeRuntime()
    let built = Counter()
    let coordinator = ModelLifecycleCoordinator(clock: clock) {
      let attempt = await built.increment()
      return attempt == 1 ? (first as any TranscriptionRuntime) : second
    }
    let lease = try await coordinator.acquire(session: UUID())
    let release = Task { await coordinator.cancelAndJoin(lease) }
    await gate.waitUntilStarted()

    let acquire = Task { try await coordinator.acquire(session: UUID()) }
    await settle()
    let stillReleasing = await coordinator.state
    XCTAssertEqual(stillReleasing, .releasing, "Acquisition must not overtake an active release")

    await gate.open()
    await release.value
    let fresh = try await acquire.value
    let state = await coordinator.state
    XCTAssertEqual(state, .active)
    let count = await built.value
    XCTAssertEqual(count, 2, "The released runtime cannot be reused")
    await coordinator.cancelAndJoin(fresh)
  }

  /// Every completion restarts the deadline; reuse inside the window keeps the
  /// same runtime rather than paying preparation again.
  func testEachCompletionStartsAFreshCooldown() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let built = Counter()
    let coordinator = ModelLifecycleCoordinator(clock: clock) {
      _ = await built.increment()
      return runtime
    }
    for index in 1...3 {
      let lease = try await coordinator.acquire(session: UUID())
      try await coordinator.finish(lease)
      await clock.waitUntilSleeping(count: index)
      let requested = await clock.requested
      XCTAssertEqual(requested.count, index, "Each completion arms one deadline")
      XCTAssertEqual(requested.last, .seconds(30))
    }
    let preparations = await built.value
    XCTAssertEqual(preparations, 1, "Reuse inside the cooldown must not rebuild the runtime")
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 0)
    await clock.advance(to: .seconds(30))
    for _ in 0..<1000 {
      if await coordinator.state == .unloaded { break }
      await Task.yield()
    }
    let released = await runtime.shutdowns
    XCTAssertEqual(released, 1)
  }

  /// Failure and cancellation release immediately and join the shutdown; they do
  /// not wait for a cooldown deadline that no clock will ever deliver.
  func testFailureAndCancellationReleaseWithoutWaitingForTheDeadline() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator(clock: clock) { runtime }
    let lease = try await coordinator.acquire(session: UUID())
    await coordinator.cancelAndJoin(lease)
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded)
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 1)
    let requested = await clock.requested
    XCTAssertTrue(requested.isEmpty, "Cancellation must not arm a cooldown")

    let failing = ModelLifecycleCoordinator(clock: clock) {
      throw DictationFailure.modelUnavailable
    }
    do {
      _ = try await failing.acquire(session: UUID())
      XCTFail("Expected a load failure")
    } catch { XCTAssertEqual(error as? DictationFailure, .modelUnavailable) }
    let failedState = await failing.state
    XCTAssertEqual(failedState, .unloaded)
    let stillNone = await clock.requested
    XCTAssertTrue(stillNone.isEmpty)
  }
}

actor Counter {
  private(set) var value = 0
  @discardableResult func increment() -> Int {
    value += 1
    return value
  }
}

private actor CooldownGatedRuntime: TranscriptionRuntime {
  let gate: PreparationGate
  init(gate: PreparationGate) { self.gate = gate }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    .init(text: "fixture", tokens: [])
  }
  func shutdown() async { await gate.wait() }
}
