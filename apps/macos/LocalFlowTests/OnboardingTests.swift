import XCTest

@testable import LocalFlow

final class OnboardingTests: XCTestCase {
  @MainActor func testCopyOnlyNeedsSuccessfulTestBeforeCompletion() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    var started: [Bool] = []
    let setup = OnboardingCoordinator(
      preferences: preferences, startDownloads: { started.append($0) })
    var readiness = SettingsViewModel.Snapshot()
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .ai)
    setup.skipAI()
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertEqual(started, [false], "Skipping AI still downloads the speech model")
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .downloads)
    readiness.modelInstalled = true
    readiness.storageAvailable = true
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions)
    readiness.microphone = .granted
    readiness.inputMonitoring = .granted
    readiness.shortcutReady = true
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .personalize)
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
    setup.skipAI()
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .test)
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

extension OnboardingTests {
  @MainActor func testLocalAIPathPicksAModelThenDownloadsAndMeetingsStayOptional() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var started: [Bool] = []
    var meetings = 0
    let setup = OnboardingCoordinator(
      preferences: AppPreferences(defaults: defaults), startDownloads: { started.append($0) },
      startMeetingModels: { meetings += 1 })
    var readiness = SettingsViewModel.Snapshot()
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .aiDetails)
    XCTAssertEqual(setup.aiMode, .local)
    XCTAssertTrue(started.isEmpty, "Nothing downloads before a model is chosen")
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertEqual(started, [true])
    setup.downloadMeetingModels()
    setup.downloadMeetingModels()
    XCTAssertEqual(meetings, 1)
    setup.back()
    XCTAssertEqual(setup.step, .aiDetails)
    setup.advance(readiness: readiness)
    readiness.modelInstalled = true
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions, "Local AI may still be downloading")
    setup.back()
    XCTAssertEqual(setup.step, .downloads)
  }
}

extension OnboardingTests {
  @MainActor func testRemoteAIDownloadsOnlyTheSpeechModel() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var started: [Bool] = []
    let setup = OnboardingCoordinator(
      preferences: AppPreferences(defaults: defaults), startDownloads: { started.append($0) })
    let readiness = SettingsViewModel.Snapshot()
    setup.advance(readiness: readiness)
    setup.aiMode = .remote
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .aiDetails)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertEqual(started, [false], "A remote server needs no MTPLX download")
  }

  func testRightControlDefaultIsAValidModifierOnlyShortcut() {
    XCTAssertTrue(ShortcutPreference.rightControl.isValid)
    XCTAssertEqual(ShortcutPreference.rightControl.title, "Right Control")
    XCTAssertTrue(ShortcutPreference.rightOption.isValid)
    XCTAssertFalse(ShortcutPreference.rightControl.includesShift)
  }
}
