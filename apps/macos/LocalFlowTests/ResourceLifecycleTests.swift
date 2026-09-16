import XCTest

@testable import LocalFlow

/// Terminal cleanup across the real coordinator. Recorder loss and rotation are
/// covered by ResourceRecorderTests; spool and mailbox units by their own suites.
/// This suite checks what only the integrated session can show: that every
/// terminal path frees the runtime and the private audio, and that a failed
/// cleanup blocks the next capture instead of silently recording again.
@MainActor
final class ResourceLifecycleTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedDirectories: [URL] = []
  private var restorePermissions: [URL] = []

  override func tearDown() async throws {
    let (directories, permissions) = await MainActor.run {
      let result = (ownedDirectories, restorePermissions)
      ownedDirectories.removeAll()
      restorePermissions.removeAll()
      return result
    }
    for url in permissions { chmod(url.path, 0o700) }
    for directory in directories.reversed() { try? FileManager.default.removeItem(at: directory) }
  }

  /// Success, cancellation and capture failure must all leave the spool root
  /// holding nothing but its owner lock, and must leave no runtime resident.
  func testEveryTerminalPathReleasesAudioAndRuntime() async throws {
    // Only a clean completion keeps the runtime for reuse. Cancellation and a
    // failed capture release it immediately, joined, on the same terminal path.
    let cases: [(String, AudioCaptureStopReason, Bool, ModelLifecycleCoordinator.State)] = [
      ("success", .keyRelease, false, .cooling),
      ("cancellation", .keyRelease, true, .unloaded),
      ("device loss", .failure(.deviceLost), false, .unloaded),
    ]
    for (name, reason, cancels, expected) in cases {
      let runtime = FakeRuntime()
      let lifecycle = ModelLifecycleCoordinator { runtime }
      let capture = FakeCapture(reason: reason)
      let root = try makeOwnedSpoolRoot()
      let coordinator = try makeCoordinator(lifecycle: lifecycle, capture: capture, spoolRoot: root)

      coordinator.begin()
      try await waitUntil { coordinator.state == .recording || !coordinator.busy }
      if cancels { coordinator.cancel() } else { coordinator.release() }
      try await waitUntil { !coordinator.busy }

      XCTAssertEqual(
        try sessionDirectories(in: root), [],
        "\(name) left temporary audio behind")
      for _ in 0..<1000 where await lifecycle.state == .releasing { await Task.yield() }
      let state = await lifecycle.state
      XCTAssertEqual(state, expected, "\(name) left an unexpected state")
      if expected == .cooling {
        await lifecycle.releaseIfIdle(generation: lifecycle.generation)
      }
      let finalState = await lifecycle.state
      XCTAssertEqual(finalState, .unloaded, "\(name) did not release the runtime")
      let shutdowns = await runtime.shutdownCount
      XCTAssertEqual(shutdowns, 1, "\(name) did not shut the runtime down exactly once")
    }
  }

  /// Cancelling at preparation, recording and transcription each joins the
  /// runtime and removes the audio rather than returning while work is alive.
  func testCancellationAtEveryPhaseJoinsBeforeReturning() async throws {
    let phases: [DictationSession.State] = [.preparing, .recording, .transcribing]
    for phase in phases {
      let loadGate = Gate()
      let decodeGate = Gate()
      let runtime = FakeRuntime(gate: phase == .transcribing ? decodeGate : nil)
      let lifecycle = ModelLifecycleCoordinator {
        if phase == .preparing { await loadGate.wait() }
        return runtime
      }
      let capture = FakeCapture()
      let root = try makeOwnedSpoolRoot()
      let coordinator = try makeCoordinator(lifecycle: lifecycle, capture: capture, spoolRoot: root)

      coordinator.begin()
      switch phase {
      case .preparing:
        try await waitUntil { coordinator.state == .preparing }
        coordinator.cancel()
        await loadGate.openGate()
      case .recording:
        try await waitUntil { coordinator.state == .recording }
        coordinator.cancel()
      default:
        coordinator.release()
        try await waitUntil { coordinator.state == .transcribing || !coordinator.busy }
        coordinator.cancel()
        await decodeGate.openGate()
      }
      try await waitUntil { !coordinator.busy }

      for _ in 0..<1000 where await lifecycle.state != .unloaded { await Task.yield() }
      let state = await lifecycle.state
      XCTAssertEqual(state, .unloaded, "Cancelling at \(phase) left the runtime resident")
      XCTAssertEqual(
        try sessionDirectories(in: root), [],
        "Cancelling at \(phase) left temporary audio behind")
      XCTAssertTrue(coordinator.canBegin, "Cancelling at \(phase) must not block the next session")
    }
  }

  /// A cleanup failure is not recoverable inside the process: the app must stop
  /// recording rather than accumulate private audio it cannot remove.
  func testCleanupFailureBlocksFurtherCapture() async throws {
    let capture = FakeCapture()
    let root = try makeOwnedSpoolRoot()
    let coordinator = try makeCoordinator(capture: capture, spoolRoot: root)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    // Removing the session directory needs write access to its parent.
    XCTAssertEqual(chmod(root.path, 0o500), 0)
    restorePermissions.append(root)
    coordinator.release()
    try await waitUntil { !coordinator.busy }

    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("cleanup failed"), coordinator.status)
    XCTAssertFalse(coordinator.canBegin, "Blocked cleanup must prevent another recording")
    let startsBefore = await capture.starts
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let startsAfter = await capture.starts
    XCTAssertEqual(startsAfter, startsBefore, "A blocked coordinator must not start capture")
    XCTAssertEqual(chmod(root.path, 0o700), 0)
  }

  private func sessionDirectories(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0 != ".owner.lock" }
      .sorted()
  }

  private func makeOwnedSpoolRoot() throws -> URL {
    let root = try makeSpoolRoot()
    ownedDirectories.append(root)
    return root
  }

  private func makeCoordinator(
    lifecycle: ModelLifecycleCoordinator? = nil,
    capture: any AudioCapturing,
    spoolRoot: URL
  ) throws -> DictationCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalFlowLifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    let store = try TranscriptionStore(
      path: directory.appendingPathComponent("history.sqlite").path)
    return DictationCoordinator(
      store: store, lifecycle: lifecycle ?? ModelLifecycleCoordinator { FakeRuntime() },
      capture: capture, insertion: FakeInsertion(), spoolRoot: spoolRoot)
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard clock.now < deadline else {
        XCTFail("timed out")
        throw TestTimeout.expired
      }
      await Task.yield()
    }
  }

  /// The driver must record one measured row per cycle, including the reuse
  /// series, with real queue capacities rather than placeholder values.
  func testBenchmarkRecordsEveryCycleWithMeasuredValues() async throws {
    let built = Counter()
    let bridge = CooldownBridge()
    let lifecycle = ModelLifecycleCoordinator(clock: BridgedCooldownClock(bridge: bridge)) {
      _ = await built.increment()
      return FakeRuntime()
    }
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: FakeCapture(), spoolRoot: try makeOwnedSpoolRoot())
    let samples = SampleSource(values: Array(repeating: UInt64(120_000_000), count: 512))
    let benchmark = DictationBenchmark(
      coordinator: coordinator, lifecycle: lifecycle,
      clock: BridgedBenchmarkClock(bridge: bridge), sample: { samples.next() })
    var configuration = DictationBenchmark.Configuration()
    configuration.cycles = 3
    configuration.rapidReuseCycles = 1
    configuration.settledSamples = 3
    configuration.baselineSamples = 3

    let report = try await benchmark.run(configuration)

    XCTAssertEqual(report.rows.count, 4, "Three cycles plus one reuse cycle")
    XCTAssertEqual(report.baselineBytes, 120_000_000)
    XCTAssertEqual(report.baselineMegabytes, 120, accuracy: 0.001, "RSS is reported in decimal MB")
    for row in report.rows {
      XCTAssertGreaterThan(row.settledBytes, 0)
      XCTAssertEqual(row.controlQueueCapacity, UInt32(ControlMailbox.capacity))
      XCTAssertLessThanOrEqual(row.controlQueuePeak, row.controlQueueCapacity)
      XCTAssertGreaterThan(row.recordNanoseconds, 0, "Cycle \(row.index) recorded no phase time")
    }
    XCTAssertEqual(report.rows.filter(\.rapidReuse).count, 1)
    XCTAssertEqual(report.slopeMegabytesPerCycle, 0, accuracy: 0.001)
    XCTAssertEqual(report.modelID, "unavailable", "An unidentified model is stated, not blank")
    // Three cycles each load once; the reuse cycle runs before its cooldown
    // expires, so it must not pay another preparation.
    let preparations = await built.value
    XCTAssertEqual(preparations, 3, "The reuse cycle must reuse the cooling runtime")
  }

  /// A run without a measurement is not a run with a missing row: it fails.
  func testMissingSampleFailsTheRun() async throws {
    let lifecycle = ModelLifecycleCoordinator(clock: InstantClock()) { FakeRuntime() }
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: FakeCapture(), spoolRoot: try makeOwnedSpoolRoot())
    let samples = SampleSource(values: [200_000_000, 200_000_000])
    let benchmark = DictationBenchmark(
      coordinator: coordinator, lifecycle: lifecycle, clock: InstantClock(),
      sample: { samples.next() })
    var configuration = DictationBenchmark.Configuration()
    configuration.cycles = 1
    configuration.baselineSamples = 3

    do {
      _ = try await benchmark.run(configuration)
      XCTFail("A missing RSS sample must fail the run")
    } catch {
      XCTAssertEqual(error as? DictationBenchmark.Failure, .sampleUnavailable(cycle: 0))
    }
  }

  /// A release that outlives its 10-second allowance invalidates the cycle
  /// instead of sampling a still-resident runtime as settled memory.
  func testReleaseTimeoutFailsTheRun() async throws {
    let lifecycle = ModelLifecycleCoordinator(clock: NeverClock()) { FakeRuntime() }
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: FakeCapture(), spoolRoot: try makeOwnedSpoolRoot())
    let samples = SampleSource(values: Array(repeating: UInt64(150_000_000), count: 64))
    let benchmark = DictationBenchmark(
      coordinator: coordinator, lifecycle: lifecycle, clock: InstantClock(),
      sample: { samples.next() })
    var configuration = DictationBenchmark.Configuration()
    configuration.cycles = 1
    configuration.baselineSamples = 1
    configuration.settledSamples = 1
    configuration.releaseTimeout = .milliseconds(200)

    do {
      _ = try await benchmark.run(configuration)
      XCTFail("An unreleased runtime must fail the cycle")
    } catch {
      XCTAssertEqual(error as? DictationBenchmark.Failure, .releaseTimedOut(cycle: 1))
    }
  }

  /// A lossy measurement export cannot be acceptance evidence, so the driver
  /// fails the run rather than returning rows backed by an incomplete record.
  func testIncompleteMeasurementExportFailsTheRun() async throws {
    let directory = try makeOwnedSpoolRoot().appendingPathComponent("Measurements")
    let identity = try ResourceRecorder.Identity(
      build: "test", model: "test", hardware: "Mac-test", os: "14.0", conditions: .development)
    let recorder = try ResourceRecorder(directory: directory, identity: identity)
    // An invalid queue measurement is counted as loss, which invalidates export.
    XCTAssertFalse(recorder.record(phase: .idle, queueSource: .audioRaw))
    let lifecycle = ModelLifecycleCoordinator(clock: InstantClock()) { FakeRuntime() }
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: FakeCapture(), spoolRoot: try makeOwnedSpoolRoot())
    let samples = SampleSource(values: Array(repeating: UInt64(100_000_000), count: 64))
    let benchmark = DictationBenchmark(
      coordinator: coordinator, lifecycle: lifecycle, recorder: recorder, clock: InstantClock(),
      sample: { samples.next() })
    var configuration = DictationBenchmark.Configuration()
    configuration.cycles = 1
    configuration.rapidReuseCycles = 0
    configuration.baselineSamples = 1
    configuration.settledSamples = 1

    do {
      _ = try await benchmark.run(configuration)
      XCTFail("A lossy export must fail the run")
    } catch {
      XCTAssertEqual(error as? DictationBenchmark.Failure, .incompleteExport)
    }
  }

}

/// Benchmark sleeps are contract calls; the deterministic run must not wait.
private struct InstantClock: DictationClock {
  func sleep(for duration: Duration) async throws {}
}

/// Links the two clocks the way real time does: the lifecycle's 30-second
/// deadline elapses only once the benchmark has waited out its cooldown, so a
/// reuse cycle started before that still finds the cooling runtime.
private actor CooldownBridge {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    await withCheckedContinuation { waiters.append($0) }
  }
  /// Firing releases the deadlines that are already armed. It never latches, so
  /// a later cycle cannot inherit an earlier cycle's elapsed cooldown.
  func fire() {
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

private struct BridgedCooldownClock: DictationClock {
  let bridge: CooldownBridge
  func sleep(for duration: Duration) async throws { await bridge.wait() }
}

private struct BridgedBenchmarkClock: DictationClock {
  let bridge: CooldownBridge
  func sleep(for duration: Duration) async throws {
    if duration >= .seconds(30) { await bridge.fire() }
  }
}

/// Models a cooldown deadline that never arrives, so release never completes.
private struct NeverClock: DictationClock {
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: .seconds(3600))
  }
}

private final class SampleSource: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]
  init(values: [UInt64]) { self.values = values }
  func next() -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? nil : values.removeFirst()
  }
}
