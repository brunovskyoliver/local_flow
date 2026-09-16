import XCTest

@testable import LocalFlow

actor ProbeRuntime: TranscriptionRuntime {
  private(set) var calls = 0
  private(set) var shutdowns = 0
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    calls += 1
    return TranscriptionWindow(text: "test", tokens: [])
  }
  func shutdown() async { shutdowns += 1 }
}

final class ModelOwnershipTests: XCTestCase {
  func testExclusiveLeaseAndStaleRelease() async throws {
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator { runtime }
    let first = try await coordinator.acquire(session: UUID())
    do {
      _ = try await coordinator.acquire(session: UUID())
      XCTFail("A second session must not acquire a lease")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(first)
    let second = try await coordinator.acquire(session: UUID())
    await coordinator.releaseIfIdle(generation: first.generation)
    let state = await coordinator.state
    XCTAssertEqual(state, .active)
    do {
      _ = try await coordinator.transcribe(first, samples: [0])
      XCTFail("Stale lease must fail")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    await coordinator.cancelAndJoin(second)
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 1)
    let finalState = await coordinator.state
    XCTAssertEqual(finalState, .unloaded)
  }

  func testCancelledPreparationJoinsBeforeAnotherRuntime() async throws {
    let gate = PreparationGate()
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let session = UUID()
    let load = Task { try await coordinator.acquire(session: session) }
    await gate.waitUntilStarted()
    let cancel = Task { await coordinator.cancelSessionAndJoin(session) }
    // The gate controls an uninterruptible operation. Cancellation must join it.
    for _ in 0..<1000 {
      if await coordinator.state == .releasing { break }
      await Task.yield()
    }
    let cancellingState = await coordinator.state
    XCTAssertEqual(cancellingState, .releasing)
    await gate.open()
    await cancel.value
    do {
      _ = try await load.value
      XCTFail("Cancelled preparation cannot succeed")
    } catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testLoadFailureClearsOwnership() async throws {
    let coordinator = ModelLifecycleCoordinator { throw DictationFailure.modelUnavailable }
    for _ in 0..<2 {
      do {
        _ = try await coordinator.acquire(session: UUID())
        XCTFail("Expected load failure")
      } catch { XCTAssertEqual(error as? DictationFailure, .modelUnavailable) }
    }
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded)
  }

  func testRepeatedCancellationJoinsUninterruptibleShutdown() async throws {
    let shutdownGate = PreparationGate()
    let runtime = ShutdownGatedRuntime(gate: shutdownGate)
    let coordinator = ModelLifecycleCoordinator { runtime }
    let lease = try await coordinator.acquire(session: UUID())
    let first = Task { await coordinator.cancelAndJoin(lease) }
    await shutdownGate.waitUntilStarted()
    let progress = CancellationProgress()
    let second = Task {
      await progress.markStarted()
      await coordinator.cancelAndJoin(lease)
      await progress.markFinished()
    }
    await progress.waitUntilStarted()
    for _ in 0..<100 { await Task.yield() }
    let returnedEarly = await progress.finished
    XCTAssertFalse(returnedEarly, "Repeated cancellation must join the same shutdown")
    await shutdownGate.open()
    await first.value
    await second.value
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded)
  }

  func testInstallationCannotReplaceActivelyLeasedModel() async throws {
    let runtime = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator { runtime }
    let lease = try await coordinator.acquire(session: UUID())
    do {
      try await coordinator.installModel {
        XCTFail("Replacement must not run with an active lease")
      }
      XCTFail("Active ownership must reject replacement")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    let result = try await coordinator.transcribe(lease, samples: [0])
    XCTAssertEqual(result.text, "test")
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(shutdowns, 0)
    await coordinator.cancelAndJoin(lease)
  }

  func testInstallationExcludesNewLeasesUntilOperationCompletes() async throws {
    let gate = PreparationGate()
    let coordinator = ModelLifecycleCoordinator { ProbeRuntime() }
    let install = Task { try await coordinator.installModel { await gate.wait() } }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.acquire(session: UUID())
      XCTFail("Model replacement must exclude capture leases")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    try await install.value
    let lease = try await coordinator.acquire(session: UUID())
    await coordinator.cancelAndJoin(lease)
  }

  func testCancellingAcquireCancelsCooperativeFactoryAndClearsOwnership() async throws {
    let started = CancellationProgress()
    let coordinator = ModelLifecycleCoordinator {
      await started.markStarted()
      try await Task.sleep(for: .seconds(60))
      return ProbeRuntime()
    }
    let acquire = Task { try await coordinator.acquire(session: UUID()) }
    await started.waitUntilStarted()
    acquire.cancel()
    do {
      _ = try await acquire.value
      XCTFail("Cancelled acquisition must not return a lease")
    } catch {
      XCTAssertTrue(error is CancellationError || error as? DictationFailure == .cancelled)
    }
    await coordinator.cancelSessionAndJoin(UUID())
    let state = await coordinator.state
    XCTAssertEqual(state, .unloaded)
  }

  func testPreparationRejectsSecondAcquireWithoutStartingAnotherRuntime() async throws {
    let gate = PreparationGate()
    let runtime = ProbeRuntime()
    let factory = RuntimeFactoryProbe(runtime: runtime, gate: gate)
    let coordinator = ModelLifecycleCoordinator { await factory.make() }
    let session = UUID()
    let first = Task { try await coordinator.acquire(session: session) }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.acquire(session: UUID())
      XCTFail("Preparation has one admitted owner")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    let calls = await factory.calls
    XCTAssertEqual(calls, 1)
    await gate.open()
    let lease = try await first.value
    await coordinator.cancelAndJoin(lease)
  }

  func testInferenceIsExclusiveAndCancellationJoinsBeforeShutdown() async throws {
    let gate = PreparationGate()
    let runtime = InferenceGatedRuntime(gate: gate)
    let coordinator = ModelLifecycleCoordinator { runtime }
    let lease = try await coordinator.acquire(session: UUID())
    let inference = Task { try await coordinator.transcribe(lease, samples: [0]) }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.transcribe(lease, samples: [0])
      XCTFail("Only one inference operation may run")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    do {
      try await coordinator.finish(lease)
      XCTFail("Finish must not detach an active inference")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    let cancel = Task { await coordinator.cancelAndJoin(lease) }
    for _ in 0..<1000 {
      if await coordinator.state == .releasing { break }
      await Task.yield()
    }
    let state = await coordinator.state
    let shutdowns = await runtime.shutdowns
    XCTAssertEqual(state, .releasing)
    XCTAssertEqual(shutdowns, 0, "Uninterruptible inference must finish before shutdown")
    await gate.open()
    await cancel.value
    do {
      _ = try await inference.value
      XCTFail("A cancelled lease cannot deliver its late result")
    } catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
    let finalShutdowns = await runtime.shutdowns
    XCTAssertEqual(finalShutdowns, 1)
  }

  func testAcquireRacingReleaseWaitsAndRejectsAdditionalWaiters() async throws {
    let gate = PreparationGate()
    let runtime = ShutdownGatedRuntime(gate: gate)
    let factory = ReleaseRaceFactory(first: runtime)
    let coordinator = ModelLifecycleCoordinator { await factory.make() }
    let first = try await coordinator.acquire(session: UUID())
    let cancel = Task { await coordinator.cancelAndJoin(first) }
    await gate.waitUntilStarted()
    let session = UUID()
    let next = Task { try await coordinator.acquire(session: session) }
    // Acquire's generation advances synchronously before it waits on release.
    // A third request must be busy once the one waiting owner has been admitted.
    for _ in 0..<1000 {
      if await coordinator.generation > first.generation { break }
      await Task.yield()
    }
    guard await coordinator.generation > first.generation else {
      await gate.open()
      await cancel.value
      let lease = try await next.value
      await coordinator.cancelAndJoin(lease)
      return XCTFail("Waiting acquisition was not scheduled")
    }
    do {
      _ = try await coordinator.acquire(session: UUID())
      XCTFail("Only one acquisition may wait for release")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    let callsBeforeRelease = await factory.calls
    XCTAssertEqual(callsBeforeRelease, 1)
    await gate.open()
    await cancel.value
    let second = try await next.value
    XCTAssertEqual(second.sessionID, session)
    let callsAfterRelease = await factory.calls
    XCTAssertEqual(callsAfterRelease, 2)
    let result = try await coordinator.transcribe(second, samples: [0])
    XCTAssertEqual(result.text, "test")
    await coordinator.cancelAndJoin(second)
  }

}

actor PreparationGate {
  private var started = false
  private var work: CheckedContinuation<Void, Never>?
  private var start: CheckedContinuation<Void, Never>?
  func wait() async {
    started = true
    start?.resume()
    start = nil
    await withCheckedContinuation { work = $0 }
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { start = $0 }
  }
  func open() {
    work?.resume()
    work = nil
  }
}

private actor ShutdownGatedRuntime: TranscriptionRuntime {
  let gate: PreparationGate
  init(gate: PreparationGate) { self.gate = gate }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    .init(text: "fixture", tokens: [])
  }
  func shutdown() async { await gate.wait() }
}

private actor CancellationProgress {
  private var started = false
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var finished = false
  func markStarted() {
    started = true
    waiter?.resume()
    waiter = nil
  }
  func markFinished() { finished = true }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

private actor RuntimeFactoryProbe {
  let runtime: ProbeRuntime
  let gate: PreparationGate
  private(set) var calls = 0
  init(runtime: ProbeRuntime, gate: PreparationGate) {
    self.runtime = runtime
    self.gate = gate
  }
  func make() async -> any TranscriptionRuntime {
    calls += 1
    await gate.wait()
    return runtime
  }
}

private actor InferenceGatedRuntime: TranscriptionRuntime {
  let gate: PreparationGate
  private(set) var shutdowns = 0
  init(gate: PreparationGate) { self.gate = gate }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    await gate.wait()
    return .init(text: "late result", tokens: [])
  }
  func shutdown() async { shutdowns += 1 }
}

private actor ReleaseRaceFactory {
  let first: ShutdownGatedRuntime
  private(set) var calls = 0
  init(first: ShutdownGatedRuntime) { self.first = first }
  func make() -> any TranscriptionRuntime {
    calls += 1
    if calls == 1 { return first }
    return ProbeRuntime()
  }
}

extension ModelOwnershipTests {
  func testApplicationShutdownJoinsExistingReleaseAndBlocksNewLease() async throws {
    let gate = PreparationGate()
    let runtime = ShutdownGatedRuntime(gate: gate)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    try await lifecycle.finish(lease)
    let release = Task { await lifecycle.releaseIfIdle(generation: lease.generation) }
    await gate.waitUntilStarted()
    let shutdown = Task { try await lifecycle.shutdownIfIdle() }
    for _ in 0..<1000 {
      if await lifecycle.snapshot().installing { break }
      await Task.yield()
    }
    let during = await lifecycle.snapshot()
    XCTAssertTrue(during.installing)
    XCTAssertEqual(during.state, .releasing)
    do {
      _ = try await lifecycle.acquire(session: UUID())
      XCTFail("Shutdown must block new runtime ownership")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    await release.value
    try await shutdown.value
    let after = await lifecycle.snapshot()
    XCTAssertEqual(after.state, .unloaded)
    XCTAssertFalse(after.loaded)
    XCTAssertFalse(after.installing)
  }
}
