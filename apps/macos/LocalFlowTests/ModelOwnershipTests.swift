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
  func testMeetingRuntimeSwitchAndBoundsLeaveDictationUnchanged() async throws {
    let speech = ProbeRuntime()
    let meeting = ProbeRuntime()
    let lifecycle = ModelLifecycleCoordinator(meetingFactory: { _ in meeting }, factory: { speech })
    let speechLease = try await lifecycle.acquire(session: UUID())
    do {
      _ = try await lifecycle.transcribe(speechLease, samples: Array(repeating: 0, count: 239_361))
      XCTFail("Dictation must retain its bound")
    } catch { XCTAssertEqual(error as? DictationFailure, .invalidAudio) }
    try await lifecycle.finish(speechLease)
    let meetingLease = try await lifecycle.acquire(session: UUID(), workload: .meetingTranscription)
    let shutdowns = await speech.shutdowns
    XCTAssertEqual(shutdowns, 1)
    _ = try await lifecycle.transcribe(meetingLease, samples: Array(repeating: 0, count: 1_920_000))
    do {
      _ = try await lifecycle.transcribe(
        meetingLease, samples: Array(repeating: 0, count: 1_920_001))
      XCTFail("Meeting requests must remain bounded")
    } catch { XCTAssertEqual(error as? DictationFailure, .invalidAudio) }
    try await lifecycle.finish(meetingLease)
    let state = await lifecycle.state
    let meetingShutdowns = await meeting.shutdowns
    XCTAssertEqual(state, .unloaded)
    XCTAssertEqual(meetingShutdowns, 1)
  }

  /// The meeting runtime is built for the language the acquiring pass names, and a
  /// resident runtime for another language is never reused.
  func testMeetingRuntimeIsBuiltForTheRequestedLanguage() async throws {
    let languages = LanguageLog()
    let lifecycle = ModelLifecycleCoordinator(
      meetingFactory: { language in
        await languages.append(language)
        return ProbeRuntime()
      }, factory: { ProbeRuntime() })
    for language in [MeetingLanguage.slovak, .english] {
      let lease = try await lifecycle.acquire(
        session: UUID(), workload: .meetingTranscription, meetingLanguage: language)
      try await lifecycle.finish(lease)
    }
    let lease = try await lifecycle.acquire(session: UUID(), workload: .meetingTranscription)
    try await lifecycle.finish(lease)
    let recorded = await languages.values
    XCTAssertEqual(recorded, [.slovak, .english, .defaultLanguage])
  }

  func testMeetingPreemptsDiarizationAndKeepReadyRestoresSpeech() async throws {
    let speech = ProbeRuntime()
    let meeting = ProbeRuntime()
    let diarizer = FakeDiarizationRuntime()
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: { diarizer }, meetingFactory: { _ in meeting }, factory: { speech })
    await lifecycle.setKeepLoaded(true)
    let diarizationLease = try await lifecycle.acquire(session: UUID(), workload: .diarization)
    let meetingLease = try await lifecycle.acquire(session: UUID(), workload: .meetingTranscription)
    let diarizerShutdowns = await diarizer.shutdownCount
    XCTAssertEqual(diarizerShutdowns, 1)
    do {
      try await lifecycle.finish(diarizationLease)
      XCTFail("Preempted lease must be stale")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    try await lifecycle.finish(meetingLease)
    for _ in 0..<1_000 {
      if await lifecycle.snapshot().loaded { break }
      await Task.yield()
    }
    let snapshot = await lifecycle.snapshot()
    XCTAssertTrue(snapshot.loaded, "Keep ready warms Parakeet after releasing Turbo")
    let meetingShutdowns = await meeting.shutdowns
    XCTAssertEqual(meetingShutdowns, 1)
    await lifecycle.setKeepLoaded(false)
    try await lifecycle.shutdownIfIdle()
  }

  func testMissingMeetingFactoryNeverFallsBackToSpeech() async throws {
    let speech = ProbeRuntime()
    let lifecycle = ModelLifecycleCoordinator { speech }
    do {
      _ = try await lifecycle.acquire(session: UUID(), workload: .meetingTranscription)
      XCTFail("Missing Turbo must fail explicitly")
    } catch { XCTAssertEqual(error as? DictationFailure, .modelUnavailable) }
    let calls = await speech.calls
    XCTAssertEqual(calls, 0)
  }

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

  // MARK: Feature 007 workloads (FR-032)

  func testWorkloadSwitchReleasesSpeechBeforeTheDiarizerPrepares() async throws {
    let speech = ProbeRuntime()
    let diarizer = FakeDiarizationFactory()
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: {
        // Never co-resident: the speech runtime is already shut down here.
        let shutdowns = await speech.shutdowns
        XCTAssertEqual(shutdowns, 1)
        return try await diarizer.make()
      }, factory: { speech })
    let asr = try await coordinator.acquire(session: UUID())
    try await coordinator.finish(asr)
    let cooling = await coordinator.snapshot()
    XCTAssertTrue(cooling.loaded)
    let lease = try await coordinator.acquire(session: UUID(), workload: .diarization)
    XCTAssertEqual(lease.workload, .diarization)
    let made = await diarizer.makeCount
    XCTAssertEqual(made, 1)
    let active = await coordinator.snapshot()
    XCTAssertFalse(active.loaded, "The speech model is not resident during diarization")
    await coordinator.cancelAndJoin(lease)
  }

  func testDiarizationAcquireIsRefusedWhileAnyLeaseIsHeldOrInstalling() async throws {
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await FakeDiarizationFactory().make() },
      factory: { ProbeRuntime() })
    let asr = try await coordinator.acquire(session: UUID())
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .diarization)
      XCTFail("Diarization must not preempt speech recognition")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(asr)
    let diarization = try await coordinator.acquire(session: UUID(), workload: .diarization)
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .diarization)
      XCTFail("A second diarization lease must be refused")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(diarization)

    let gate = PreparationGate()
    let install = Task { try await coordinator.installModel { await gate.wait() } }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .diarization)
      XCTFail("Installation excludes diarization")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    try await install.value
  }

  func testSpeechRecognitionPreemptsDiarizationAndJoinsTheInFlightWindow() async throws {
    let gate = PreparationGate()
    let runtime = FakeDiarizationRuntime(scripts: [DiarizationScripts.window([(0, 0, 1)])])
    await runtime.hold(gate)
    let factory = FakeDiarizationFactory(runtime: runtime)
    let speech = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await factory.make() }, factory: { speech })
    let lease = try await coordinator.acquire(session: UUID(), workload: .diarization)
    let window = Task {
      try await coordinator.diarize(
        lease, window: .init(samples: [Float](repeating: 0, count: 16_000), numSpeakers: nil))
    }
    await gate.waitUntilStarted()
    let asr = Task { try await coordinator.acquire(session: UUID()) }
    for _ in 0..<1000 {
      if await coordinator.state == .releasing { break }
      await Task.yield()
    }
    let releasing = await coordinator.state
    XCTAssertEqual(releasing, .releasing, "Preemption waits for the in-flight window")
    let shutdownsWhileRunning = await runtime.shutdownCount
    XCTAssertEqual(shutdownsWhileRunning, 0)
    await gate.open()
    let speechLease = try await asr.value
    XCTAssertEqual(speechLease.workload, .speechRecognition)
    do {
      _ = try await window.value
      XCTFail("A preempted window must not return a result")
    } catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
    let shutdowns = await runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)
    do {
      _ = try await coordinator.diarize(
        lease, window: .init(samples: [0], numSpeakers: nil))
      XCTFail("The revoked lease is stale")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    do {
      try await coordinator.finish(lease)
      XCTFail("The revoked lease cannot finish")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    let result = try await coordinator.transcribe(speechLease, samples: [0])
    XCTAssertEqual(result.text, "test")
    await coordinator.cancelAndJoin(speechLease)
  }

  func testLeasesAreBoundToTheirWorkload() async throws {
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await FakeDiarizationFactory().make() },
      factory: { ProbeRuntime() })
    let diarization = try await coordinator.acquire(session: UUID(), workload: .diarization)
    do {
      _ = try await coordinator.transcribe(diarization, samples: [0])
      XCTFail("A diarization lease cannot transcribe")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    try await coordinator.finish(diarization)
    let speech = try await coordinator.acquire(session: UUID())
    do {
      _ = try await coordinator.diarize(speech, window: .init(samples: [0], numSpeakers: nil))
      XCTFail("A speech lease cannot diarize")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    await coordinator.cancelAndJoin(speech)
  }

  func testDiarizeValidatesBoundsAndRunsOneWindowAtATime() async throws {
    let gate = PreparationGate()
    let runtime = FakeDiarizationRuntime()
    let factory = FakeDiarizationFactory(runtime: runtime)
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await factory.make() }, factory: { ProbeRuntime() })
    let lease = try await coordinator.acquire(session: UUID(), workload: .diarization)
    let invalid: [DiarizationWindowRequest] = [
      .init(samples: [], numSpeakers: nil),
      .init(samples: [Float](repeating: 0, count: 9_600_001), numSpeakers: nil),
      .init(samples: [0, .nan], numSpeakers: nil),
      .init(samples: [0, .infinity], numSpeakers: nil),
      .init(samples: [0], numSpeakers: 0),
    ]
    for request in invalid {
      do {
        _ = try await coordinator.diarize(lease, window: request)
        XCTFail("Out-of-bounds request accepted")
      } catch { XCTAssertEqual(error as? DictationFailure, .invalidAudio) }
    }
    let requests = await runtime.requests
    XCTAssertTrue(requests.isEmpty, "Invalid requests never reach the runtime")
    await runtime.hold(gate)
    let first = Task {
      try await coordinator.diarize(lease, window: .init(samples: [0], numSpeakers: 1))
    }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.diarize(lease, window: .init(samples: [0], numSpeakers: 1))
      XCTFail("A second concurrent window must be refused")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    let result = try await first.value
    XCTAssertEqual(result, .empty)
    let recorded = await runtime.requests
    XCTAssertEqual(recorded, [.init(sampleCount: 1, numSpeakers: 1)])
    try await coordinator.finish(lease)
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

// MARK: Feature 010 identification workload (T008)

extension ModelOwnershipTests {
  private static var region: VoiceRegionRequest {
    VoiceRegionRequest(samples: [Float](repeating: 0.1, count: VoiceRegionRequest.minSamples))
  }

  func testWorkloadSwitchReleasesTheDiarizerBeforeTheEmbedderPrepares() async throws {
    let diarizer = FakeDiarizationFactory()
    let embedder = FakeVoiceEmbeddingFactory()
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await diarizer.make() },
      voiceEmbeddingFactory: {
        // Never co-resident: the diarizer is already shut down here.
        let shutdowns = await diarizer.runtime.shutdownCount
        XCTAssertEqual(shutdowns, 1)
        return try await embedder.make()
      }, factory: { ProbeRuntime() })
    let diarization = try await coordinator.acquire(session: UUID(), workload: .diarization)
    try await coordinator.finish(diarization)
    let lease = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
    XCTAssertEqual(lease.workload, .speakerIdentification)
    let made = await embedder.makeCount
    XCTAssertEqual(made, 1)
    let active = await coordinator.snapshot()
    XCTAssertFalse(active.loaded, "The speech model is not resident during identification")
    do {
      _ = try await coordinator.embed(lease, region: Self.region)
      XCTFail("No script: the fake throws noSpeech, which passes through unchanged")
    } catch { XCTAssertEqual(error as? VoiceEmbeddingFailure, .noSpeech) }
    try await coordinator.finish(lease)
    let released = await coordinator.state
    XCTAssertEqual(released, .unloaded)
  }

  func testIdentificationAcquireIsRefusedWhileAnyLeaseIsHeldOrInstalling() async throws {
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await FakeDiarizationFactory().make() },
      voiceEmbeddingFactory: { try await FakeVoiceEmbeddingFactory().make() },
      factory: { ProbeRuntime() })
    let asr = try await coordinator.acquire(session: UUID())
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
      XCTFail("Identification must not preempt speech recognition")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(asr)
    let diarization = try await coordinator.acquire(session: UUID(), workload: .diarization)
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
      XCTFail("Identification must not preempt diarization")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(diarization)
    let identification = try await coordinator.acquire(
      session: UUID(), workload: .speakerIdentification)
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
      XCTFail("A second identification lease must be refused")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .diarization)
      XCTFail("Diarization never preempts identification")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await coordinator.finish(identification)

    let gate = PreparationGate()
    let install = Task { try await coordinator.installModel { await gate.wait() } }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
      XCTFail("Installation excludes identification")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    try await install.value
  }

  func testSpeechRecognitionPreemptsIdentificationAndJoinsTheInFlightRegion() async throws {
    let gate = PreparationGate()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 0)])
    await runtime.hold(gate)
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    let speech = ProbeRuntime()
    let coordinator = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: { try await factory.make() }, factory: { speech })
    let lease = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
    let request = Self.region
    let region = Task { try await coordinator.embed(lease, region: request) }
    await gate.waitUntilStarted()
    let asr = Task { try await coordinator.acquire(session: UUID()) }
    for _ in 0..<1000 {
      if await coordinator.state == .releasing { break }
      await Task.yield()
    }
    let releasing = await coordinator.state
    XCTAssertEqual(releasing, .releasing, "Preemption waits for the in-flight region")
    let shutdownsWhileRunning = await runtime.shutdownCount
    XCTAssertEqual(shutdownsWhileRunning, 0)
    await gate.open()
    let speechLease = try await asr.value
    XCTAssertEqual(speechLease.workload, .speechRecognition)
    do {
      _ = try await region.value
      XCTFail("A preempted region must not return a result")
    } catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
    let shutdowns = await runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)
    do {
      _ = try await coordinator.embed(lease, region: Self.region)
      XCTFail("The revoked lease is stale")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    do {
      try await coordinator.finish(lease)
      XCTFail("The revoked lease cannot finish")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    await coordinator.cancelAndJoin(speechLease)
  }

  func testEmbedIsBoundToTheIdentificationWorkload() async throws {
    let coordinator = ModelLifecycleCoordinator(
      diarizationFactory: { try await FakeDiarizationFactory().make() },
      voiceEmbeddingFactory: { try await FakeVoiceEmbeddingFactory().make() },
      factory: { ProbeRuntime() })
    let diarization = try await coordinator.acquire(session: UUID(), workload: .diarization)
    do {
      _ = try await coordinator.embed(diarization, region: Self.region)
      XCTFail("A diarization lease cannot embed")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    try await coordinator.finish(diarization)
    let identification = try await coordinator.acquire(
      session: UUID(), workload: .speakerIdentification)
    do {
      _ = try await coordinator.diarize(
        identification, window: .init(samples: [0], numSpeakers: nil))
      XCTFail("An identification lease cannot diarize")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    do {
      _ = try await coordinator.transcribe(identification, samples: [0])
      XCTFail("An identification lease cannot transcribe")
    } catch { XCTAssertEqual(error as? DictationFailure, .staleLease) }
    try await coordinator.finish(identification)
  }

  func testEmbedValidatesBoundsAndRunsOneRegionAtATime() async throws {
    let gate = PreparationGate()
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [[Float](repeating: 0.5, count: 4)])
    let factory = FakeVoiceEmbeddingFactory(runtime: runtime)
    let coordinator = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: { try await factory.make() }, factory: { ProbeRuntime() })
    let lease = try await coordinator.acquire(session: UUID(), workload: .speakerIdentification)
    let invalid: [VoiceRegionRequest] = [
      .init(samples: []),
      .init(samples: [Float](repeating: 0, count: VoiceRegionRequest.minSamples - 1)),
      .init(samples: [Float](repeating: 0, count: VoiceRegionRequest.maxSamples + 1)),
      .init(samples: [Float](repeating: .nan, count: VoiceRegionRequest.minSamples)),
    ]
    for request in invalid {
      do {
        _ = try await coordinator.embed(lease, region: request)
        XCTFail("Out-of-bounds request accepted")
      } catch { XCTAssertEqual(error as? DictationFailure, .invalidAudio) }
    }
    let requests = await runtime.requests
    XCTAssertTrue(requests.isEmpty, "Invalid requests never reach the runtime")
    // A 4-value vector is not a valid embedding.
    do {
      _ = try await coordinator.embed(lease, region: Self.region)
      XCTFail("An invalid result must be refused")
    } catch { XCTAssertEqual(error as? DictationFailure, .invalidResult) }
    await runtime.setScripts([VoiceVectors.unit(axis: 3)])
    await runtime.hold(gate)
    let request = Self.region
    let first = Task { try await coordinator.embed(lease, region: request) }
    await gate.waitUntilStarted()
    do {
      _ = try await coordinator.embed(lease, region: Self.region)
      XCTFail("A second concurrent region must be refused")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    let result = try await first.value
    XCTAssertEqual(result.vector, VoiceVectors.unit(axis: 3))
    XCTAssertEqual(result.speechSeconds, 3, accuracy: 0.001)
    let recorded = await runtime.requests
    XCTAssertEqual(recorded, [VoiceRegionRequest.minSamples, VoiceRegionRequest.minSamples])
    try await coordinator.finish(lease)
  }
}

private actor LanguageLog {
  private(set) var values: [MeetingLanguage] = []
  func append(_ language: MeetingLanguage) { values.append(language) }
}
