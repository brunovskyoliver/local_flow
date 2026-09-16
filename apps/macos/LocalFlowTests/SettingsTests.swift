import XCTest

@testable import LocalFlow

final class SettingsTests: XCTestCase {
  func testManualLoadCoolsAndRejectsUnloadWhileLeased() async throws {
    let runtime = ProbeRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    try await lifecycle.loadIfIdle()
    let loaded = await lifecycle.snapshot()
    XCTAssertEqual(loaded.state, .cooling)
    XCTAssertTrue(loaded.loaded)
    let lease = try await lifecycle.acquire(session: UUID())
    do {
      try await lifecycle.unloadIfIdle()
      XCTFail("Must reject active ownership")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await lifecycle.finish(lease)
    try await lifecycle.unloadIfIdle()
    let unloaded = await lifecycle.snapshot()
    XCTAssertFalse(unloaded.loaded)
  }

  @MainActor func testViewingSettingsOnlyObserves() async {
    var operations = 0
    let model = SettingsViewModel(observe: { .init() }, perform: { _ in operations += 1 })
    await model.refresh()
    XCTAssertEqual(operations, 0)
    XCTAssertEqual(model.snapshot.modelIdentity, nil)
    XCTAssertFalse(model.readyForTest)
  }

  @MainActor func testBusyActionDoesNotBlamePermissionsOrModelFiles() async {
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in throw DictationFailure.busy })
    await model.run(.load)
    XCTAssertEqual(
      model.error, "Another dictation or model operation is still running. Wait for it to finish.")
  }

  func testUnknownFailureDoesNotExposeUserInfo() {
    let error = NSError(
      domain: "fixture", code: 42, userInfo: [NSLocalizedDescriptionKey: "private transcript"])
    let message = DictationErrorMessage.describe(error)
    XCTAssertFalse(message.contains("private transcript"))
    XCTAssertTrue(message.contains("42"))
  }

  @MainActor func testFailureCanRetry() async {
    var attempts = 0
    let model = SettingsViewModel(
      observe: { .init() },
      perform: { _ in
        attempts += 1
        if attempts == 1 { throw DictationFailure.modelUnavailable }
      })
    await model.run(.download)
    XCTAssertEqual(model.error, DictationErrorMessage.describe(DictationFailure.modelUnavailable))
    await model.run(.download)
    XCTAssertNil(model.error)
    XCTAssertEqual(attempts, 2)
  }
}

extension SettingsTests {
  func testLoadAdmissionRejectsRacedManualCommands() async throws {
    let gate = PreparationGate()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return ProbeRuntime()
    }
    let loading = Task { try await lifecycle.loadIfIdle() }
    await gate.waitUntilStarted()
    let state = await lifecycle.snapshot()
    XCTAssertTrue(state.leased)
    XCTAssertFalse(state.controlsAvailable)
    do {
      try await lifecycle.loadIfIdle()
      XCTFail("A second manual load must not queue")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    do {
      try await lifecycle.unloadIfIdle()
      XCTFail("Unload must not revoke loading ownership")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    try await loading.value
    try await lifecycle.unloadIfIdle()
  }

  func testManualLoadStartsThirtySecondCooldown() async throws {
    let clock = SettingsClock()
    let lifecycle = ModelLifecycleCoordinator(clock: clock) { ProbeRuntime() }
    try await lifecycle.loadIfIdle()
    for _ in 0..<1000 {
      if await clock.duration != nil { break }
      await Task.yield()
    }
    let duration = await clock.duration
    XCTAssertEqual(duration, .seconds(30))
    let generation = await lifecycle.generation
    await lifecycle.releaseIfIdle(generation: generation)
    let state = await lifecycle.snapshot()
    XCTAssertEqual(state.state, .unloaded)
  }
}

private actor SettingsClock: DictationClock {
  private(set) var duration: Duration?
  func sleep(for duration: Duration) async throws {
    self.duration = duration
    try await Task.sleep(for: .seconds(3600))
  }
}

extension SettingsTests {
  func testGrantedPermissionsDisappearAndRevokedPermissionReturns() {
    var snapshot = SettingsViewModel.Snapshot()
    XCTAssertTrue(snapshot.hasMissingPermissions)
    snapshot.microphone = .granted
    snapshot.inputMonitoring = .granted
    snapshot.accessibility = .granted
    XCTAssertFalse(snapshot.hasMissingPermissions)
    snapshot.accessibility = .denied
    XCTAssertTrue(snapshot.hasMissingPermissions)
  }
}
