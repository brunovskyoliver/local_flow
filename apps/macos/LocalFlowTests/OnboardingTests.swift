import XCTest

@testable import LocalFlow

final class OnboardingTests: XCTestCase {
  @MainActor func testCopyOnlyNeedsSuccessfulTestBeforeCompletion() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let setup = OnboardingCoordinator(preferences: preferences)
    var readiness = SettingsViewModel.Snapshot()
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .model)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .model)
    readiness.modelInstalled = true
    readiness.storageAvailable = true
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions)
    readiness.microphone = .granted
    readiness.inputMonitoring = .granted
    readiness.shortcutReady = true
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .test)
    setup.complete()
    XCTAssertFalse(preferences.onboardingComplete)
    setup.startTest(readiness: readiness)
    let session = UUID()
    setup.dictationStarted(id: session)
    setup.recordSuccessfulDictation(id: session)
    setup.complete()
    XCTAssertTrue(preferences.onboardingComplete)
  }
}

extension OnboardingTests {
  @MainActor func testReadinessRequiresEveryLocalPrerequisiteButNotAccessibility() {
    var state = SettingsViewModel.Snapshot()
    state.modelInstalled = true
    state.microphone = .granted
    state.inputMonitoring = .granted
    state.shortcutReady = true
    state.storageAvailable = true
    state.accessibility = .denied
    XCTAssertTrue(state.readyForTest)
    state.modelInstalled = false
    XCTAssertFalse(state.readyForTest, "Missing or corrupt model blocks recording")
    state.modelInstalled = true
    state.microphone = .denied
    XCTAssertFalse(state.readyForTest)
    state.microphone = .granted
    state.inputMonitoring = .denied
    XCTAssertFalse(state.readyForTest)
    state.inputMonitoring = .granted
    state.shortcutReady = false
    XCTAssertFalse(state.readyForTest)
    state.shortcutReady = true
    state.storageAvailable = false
    XCTAssertFalse(state.readyForTest)
  }

  @MainActor func testOldHistoryCannotCompleteUnarmedTest() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let setup = OnboardingCoordinator(preferences: preferences)
    setup.recordSuccessfulDictation(id: UUID())
    XCTAssertFalse(setup.testSucceeded)
    XCTAssertFalse(preferences.onboardingComplete)
  }
}

extension OnboardingTests {
  @MainActor func testLiveArmingRejectsBusyAndIgnoresPreexistingSession() async {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var readiness = SettingsViewModel.Snapshot()
    readiness.modelInstalled = true
    readiness.storageAvailable = true
    readiness.microphone = .granted
    readiness.inputMonitoring = .granted
    readiness.shortcutReady = true
    let setup = OnboardingCoordinator(
      preferences: AppPreferences(defaults: defaults), liveReadiness: { readiness })
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    let previous = UUID()
    setup.dictationStarted(id: previous)
    readiness.busy = true
    await setup.armTest()
    XCTAssertFalse(setup.testArmed)
    readiness.busy = false
    await setup.armTest()
    setup.recordSuccessfulDictation(id: previous)
    XCTAssertFalse(setup.testSucceeded)
    let current = UUID()
    setup.dictationStarted(id: current)
    setup.recordSuccessfulDictation(id: previous)
    XCTAssertFalse(setup.testSucceeded)
    setup.recordSuccessfulDictation(id: current)
    XCTAssertTrue(setup.testSucceeded)
  }

  @MainActor func testManualModelPreparationBlocksTestReadiness() {
    var readiness = SettingsViewModel.Snapshot()
    readiness.modelInstalled = true
    readiness.storageAvailable = true
    readiness.microphone = .granted
    readiness.inputMonitoring = .granted
    readiness.shortcutReady = true
    readiness.runtime = .init(state: .preparing, loaded: false, leased: true, installing: false)
    XCTAssertFalse(readiness.readyForTest)
    readiness.runtime = .init(state: .releasing, loaded: false, leased: false, installing: false)
    XCTAssertFalse(readiness.readyForTest)
  }
}
