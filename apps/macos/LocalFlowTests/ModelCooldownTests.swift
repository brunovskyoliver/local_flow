import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

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

// MARK: Cancelled dictation keeps a healthy runtime

extension ModelCooldownTests {
  /// A cancelled or incomplete dictation ends its lease like a completed one: the
  /// runtime cools (or stays ready) instead of paying a cold load next time.
  func testCancelAndCoolKeepsAHealthyRuntimeForTheNextSession() async throws {
    let clock = ManualClock()
    let runtime = ProbeRuntime()
    let built = Counter()
    let coordinator = ModelLifecycleCoordinator(clock: clock) {
      await built.increment()
      return runtime
    }
    let lease = try await coordinator.acquire(session: UUID())
    await coordinator.cancelAndCool(lease)
    let cooled = await coordinator.state
    XCTAssertEqual(cooled, .cooling)
    await clock.waitUntilSleeping(count: 1)
    let deadlines = await clock.requested
    XCTAssertEqual(deadlines, [.seconds(30)])
    let next = try await coordinator.acquire(session: UUID())
    try await coordinator.finish(next)
    let count = await built.value
    XCTAssertEqual(count, 1)
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 0)

    // Keep model ready holds across a cancellation, too.
    await coordinator.setKeepLoaded(true)
    let kept = try await coordinator.acquire(session: UUID())
    await coordinator.cancelAndCool(kept)
    let snapshot = await coordinator.snapshot()
    XCTAssertTrue(snapshot.loaded)
    XCTAssertTrue(snapshot.controlsAvailable)
    let stale = await coordinator.interruptInference(kept)
    XCTAssertFalse(stale, "an ended lease cannot interrupt anything")
  }

  /// An in-flight window is cancelled and joined; a clean cancellation cools, while a
  /// window that fails for another reason is a runtime fault and releases.
  func testCancelAndCoolInterruptsTheWindowAndReleasesOnlyOnAFault() async throws {
    for faulty in [false, true] {
      let runtime = InterruptibleRuntime(faulty: faulty)
      let coordinator = ModelLifecycleCoordinator { runtime }
      let lease = try await coordinator.acquire(session: UUID())
      let window = Task { try await coordinator.transcribe(lease, samples: [0, 0]) }
      await runtime.waitUntilTranscribing()
      await coordinator.cancelAndCool(lease)
      _ = await window.result
      let state = await coordinator.state
      XCTAssertEqual(state, faulty ? .unloaded : .cooling, "faulty: \(faulty)")
      let shutdowns = await runtime.shutdowns
      XCTAssertEqual(shutdowns, faulty ? 1 : 0, "faulty: \(faulty)")
      if !faulty {
        let next = try await coordinator.acquire(session: UUID())
        let result = try await coordinator.transcribe(next, samples: [0, 0])
        XCTAssertEqual(result.text, "done")
        try await coordinator.finish(next)
      }
    }
  }
}

/// Waits inside a window until cancelled; the fault variant then throws a runtime error.
private actor InterruptibleRuntime: TranscriptionRuntime {
  let faulty: Bool
  private var calls = 0
  private(set) var shutdowns = 0
  private let entered = Gate()
  init(faulty: Bool) { self.faulty = faulty }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    calls += 1
    guard calls == 1 else { return .init(text: "done", tokens: []) }
    await entered.openGate()
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      if faulty { throw DictationFailure.invalidResult }
      throw error
    }
    return .init(text: "late", tokens: [])
  }

  func waitUntilTranscribing() async { await entered.wait() }
  func shutdown() async { shutdowns += 1 }
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

// MARK: Feature 010 identification workload (T008)

extension ModelCooldownTests {
  func testIdentificationFinishReleasesWithoutCooldown() async throws {
    let clock = ManualClock()
    let factory = FakeVoiceEmbeddingFactory()
    let coordinator = ModelLifecycleCoordinator(
      clock: clock, voiceEmbeddingFactory: { try await factory.make() },
      factory: { ProbeRuntime() })
    let lease = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
    try await coordinator.finish(lease)
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded, "Released at finish, not after 30 seconds")
    let shutdowns = await factory.runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)
    let deadlines = await clock.requested
    XCTAssertTrue(deadlines.isEmpty)
  }

  func testKeepModelReadyPreparesSpeechAgainAfterIdentification() async throws {
    let clock = ManualClock()
    let built = Counter()
    let factory = FakeVoiceEmbeddingFactory()
    let coordinator = ModelLifecycleCoordinator(
      clock: clock, voiceEmbeddingFactory: { try await factory.make() },
      factory: {
        _ = await built.increment()
        return ProbeRuntime()
      })
    await coordinator.setKeepLoaded(true)
    try await coordinator.loadIfIdle()
    let lease = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
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
}

/// Keep model ready after speaker work: queued speaker demand defers the reload, the
/// reload yields to speaker work, and busy callers wake on release instead of polling.
extension ModelCooldownTests {
  private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<2000 {
      if await condition() { return }
      await Task.yield()
    }
  }

  func testQueuedSpeakerDemandDefersTheKeepReadyReload() async throws {
    let built = Counter()
    let factory = FakeDiarizationFactory()
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await factory.make() },
      factory: {
        _ = await built.increment()
        return ProbeRuntime()
      })
    await coordinator.setKeepLoaded(true)
    let token = UUID()
    await coordinator.setSpeakerDemand(token, pending: true, sequence: 1)
    let first = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(first)
    for _ in 0..<200 { await Task.yield() }
    let deferred = await coordinator.snapshot()
    XCTAssertEqual(deferred.state, .unloaded, "No reload while speaker work is queued")
    XCTAssertFalse(deferred.leased)
    let second = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(second)
    var count = await built.value
    XCTAssertEqual(count, 0)
    // An older update arriving late cannot withdraw newer demand.
    await coordinator.setSpeakerDemand(token, pending: false, sequence: 1)
    for _ in 0..<200 { await Task.yield() }
    count = await built.value
    XCTAssertEqual(count, 0)
    await coordinator.setSpeakerDemand(token, pending: false, sequence: 2)
    await waitUntil { await coordinator.snapshot().loaded }
    let after = await coordinator.snapshot()
    XCTAssertTrue(after.loaded, "The last withdrawal re-prepares live speech")
    XCTAssertEqual(after.state, .cooling)
    count = await built.value
    XCTAssertEqual(count, 1)
  }

  func testSpeakerWorkPreemptsTheKeepReadyReload() async throws {
    let gate = PreparationGate()
    let speech = ProbeRuntime()
    let factory = FakeDiarizationFactory()
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await factory.make() },
      factory: {
        await gate.wait()
        return speech
      })
    await coordinator.setKeepLoaded(true)
    let first = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(first)
    await gate.waitUntilStarted()
    let warming = await coordinator.snapshot()
    XCTAssertTrue(warming.leased, "The keep-ready reload holds a lease while it loads")
    let next = Task { try await coordinator.acquire(session: UUID(), workload: .diarization) }
    for _ in 0..<50 { await Task.yield() }
    await gate.open()
    let lease = try await next.value
    XCTAssertEqual(lease.workload, .diarization)
    let shutdowns = await speech.shutdowns
    XCTAssertEqual(shutdowns, 1, "The abandoned reload is shut down, never co-resident")
    await coordinator.setKeepLoaded(false)
    try await coordinator.finish(lease)
  }

  func testDictationStillCannotBePreemptedBySpeakerWork() async throws {
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await FakeDiarizationFactory().make() },
      factory: { ProbeRuntime() })
    let lease = try await coordinator.acquire(session: UUID())
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .diarization)
      XCTFail("A live speech lease is not preemptible")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(lease)
  }

  func testWaitUntilAvailableWakesOnReleaseAndOnCancellation() async throws {
    let coordinator = ModelLifecycleCoordinator { ProbeRuntime() }
    await coordinator.waitUntilAvailable()  // Idle: returns at once.
    let lease = try await coordinator.acquire(session: UUID())
    let woke = Counter()
    let waiter = Task {
      await coordinator.waitUntilAvailable()
      _ = await woke.increment()
    }
    for _ in 0..<200 { await Task.yield() }
    var count = await woke.value
    XCTAssertEqual(count, 0, "Still leased")
    try await coordinator.finish(lease)
    await waiter.value
    count = await woke.value
    XCTAssertEqual(count, 1)

    let held = try await coordinator.acquire(session: UUID())
    let cancelled = Task { await coordinator.waitUntilAvailable() }
    for _ in 0..<50 { await Task.yield() }
    cancelled.cancel()
    await cancelled.value
    try await coordinator.finish(held)
  }
}

// MARK: Server meeting worker retention (contracts/meeting-worker-ipc.md)

/// Records factory calls and shutdowns in order, so a test can prove the old runtime
/// was released before the next one was built.
private actor RetentionEvents {
  private(set) var events: [String] = []
  func record(_ event: String) { events.append(event) }
  func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

private actor RecordingRuntime: TranscriptionRuntime {
  let name: String
  let events: RetentionEvents
  init(name: String, events: RetentionEvents) {
    self.name = name
    self.events = events
  }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    .init(text: name, tokens: [])
  }
  func shutdown() async { await events.record("shutdown \(name)") }
}

extension ModelCooldownTests {
  private func serverCoordinator(
    clock: ManualClock, events: RetentionEvents, diarization: FakeDiarizationFactory? = nil
  ) -> ModelLifecycleCoordinator {
    ModelLifecycleCoordinator(
      clock: clock, retention: .meetingWorker,
      diarizationFactory: {
        await events.record("make diarization")
        guard let diarization else { throw DictationFailure.modelUnavailable }
        return try await diarization.make()
      },
      meetingFactory: { language in
        await events.record("make meeting \(language.rawValue)")
        return RecordingRuntime(name: "meeting \(language.rawValue)", events: events)
      },
      factory: {
        await events.record("make speech")
        throw DictationFailure.modelUnavailable
      })
  }

  private func waitUntilUnloaded(_ coordinator: ModelLifecycleCoordinator) async {
    for _ in 0..<1000 {
      if await coordinator.state == .unloaded { return }
      await Task.yield()
    }
  }

  /// Consecutive windows of one meeting load Whisper once; the runtime is released 600 s
  /// after the last job, and the worker never tries to warm its unavailable live speech.
  func testServerRetentionKeepsTheSameWorkloadUntilIdleExpiry() async throws {
    let clock = ManualClock()
    let events = RetentionEvents()
    let coordinator = serverCoordinator(clock: clock, events: events)
    for index in 1...2 {
      let lease = try await coordinator.acquire(
        session: UUID(), workload: .meetingTranscription, meetingLanguage: .english)
      let window = try await coordinator.transcribe(lease, samples: [0.1])
      XCTAssertEqual(window.text, "meeting english")
      try await coordinator.finish(lease)
      await clock.waitUntilSleeping(count: index)
      let state = await coordinator.state
      XCTAssertEqual(state, .cooling)
    }
    await settle()
    let requested = await clock.requested
    XCTAssertEqual(requested, [.seconds(600), .seconds(600)])
    let makes = await events.count("make meeting english")
    XCTAssertEqual(makes, 1, "The second window reuses the resident runtime")
    let early = await events.count("shutdown meeting english")
    XCTAssertEqual(early, 0)

    await clock.advance(to: .milliseconds(599_999))
    await settle()
    let beforeDeadline = await coordinator.state
    XCTAssertEqual(beforeDeadline, .cooling)

    await clock.advance(to: .seconds(600))
    await waitUntilUnloaded(coordinator)
    let after = await coordinator.state
    XCTAssertEqual(after, .unloaded)
    let shutdowns = await events.count("shutdown meeting english")
    XCTAssertEqual(shutdowns, 1)
    await settle()
    let speech = await events.count("make speech")
    XCTAssertEqual(speech, 0, "No attempt to warm live speech the worker does not have")
  }

  /// A language or workload switch releases the resident runtime before the next loads.
  func testServerRetentionReleasesOnLanguageAndWorkloadSwitch() async throws {
    let clock = ManualClock()
    let events = RetentionEvents()
    let diarization = FakeDiarizationFactory()
    let coordinator = serverCoordinator(clock: clock, events: events, diarization: diarization)
    let english = try await coordinator.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .english)
    try await coordinator.finish(english)
    let slovak = try await coordinator.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .slovak)
    try await coordinator.finish(slovak)
    let diarize = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(diarize)
    let resident = await coordinator.state
    XCTAssertEqual(resident, .cooling, "Diarization is retained too")
    let again = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(again)
    let makes = await diarization.makeCount
    XCTAssertEqual(makes, 1)
    let log = await events.events
    XCTAssertEqual(
      log,
      [
        "make meeting english", "shutdown meeting english", "make meeting slovak",
        "shutdown meeting slovak", "make diarization",
      ])
    let shutdowns = await diarization.runtime.shutdownCount
    XCTAssertEqual(shutdowns, 0)
    try await coordinator.shutdownIfIdle()
    let stopped = await diarization.runtime.shutdownCount
    XCTAssertEqual(stopped, 1)
  }

  /// A failed or cancelled job still releases at once; an explicit unload (new prompt
  /// terms) releases a retained runtime.
  func testServerRetentionReleasesOnFailureAndExplicitUnload() async throws {
    let clock = ManualClock()
    let events = RetentionEvents()
    let coordinator = serverCoordinator(clock: clock, events: events)
    let failed = try await coordinator.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .english)
    await coordinator.cancelAndJoin(failed)
    let afterFailure = await coordinator.state
    XCTAssertEqual(afterFailure, .unloaded)
    let retained = try await coordinator.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .english)
    try await coordinator.finish(retained)
    try await coordinator.unloadIfIdle()
    let afterUnload = await coordinator.state
    XCTAssertEqual(afterUnload, .unloaded)
    let shutdowns = await events.count("shutdown meeting english")
    XCTAssertEqual(shutdowns, 2)
    let speech = await events.count("make speech")
    XCTAssertEqual(speech, 0)
  }

  /// Keep model ready cannot suspend a server worker's idle deadline.
  func testServerRetentionIgnoresKeepLoadedForTheIdleDeadline() async throws {
    let clock = ManualClock()
    let events = RetentionEvents()
    let coordinator = serverCoordinator(clock: clock, events: events)
    let lease = try await coordinator.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .english)
    try await coordinator.finish(lease)
    await clock.waitUntilSleeping(count: 1)
    await coordinator.setKeepLoaded(true)
    await clock.waitUntilSleeping(count: 2)
    await clock.advance(to: .seconds(600))
    await waitUntilUnloaded(coordinator)
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded)
  }
}
