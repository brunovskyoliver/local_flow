import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

final class OnboardingTests: XCTestCase {
  @MainActor func testSuccessfulDictationCompletesOnboarding() {
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

  @MainActor func testMicrophoneTestCanBeSkipped() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let setup = OnboardingCoordinator(preferences: preferences)
    var readiness = SettingsViewModel.Snapshot()
    setup.advance(readiness: readiness)
    setup.skipAI()
    readiness.modelInstalled = true
    readiness.storageAvailable = true
    setup.advance(readiness: readiness)
    readiness.microphone = .granted
    readiness.inputMonitoring = .granted
    readiness.shortcutReady = true
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .test)

    setup.skipTest()

    XCTAssertEqual(setup.step, .complete)
    XCTAssertTrue(preferences.onboardingComplete)
  }
}

extension OnboardingTests {
  @MainActor private func readySnapshot() -> SettingsViewModel.Snapshot {
    var snapshot = SettingsViewModel.Snapshot()
    snapshot.modelInstalled = true
    snapshot.storageAvailable = true
    snapshot.microphone = .granted
    snapshot.inputMonitoring = .granted
    snapshot.shortcutReady = true
    return snapshot
  }

  @MainActor private func reachTest(_ setup: OnboardingCoordinator) {
    let ready = readySnapshot()
    setup.advance(readiness: ready)
    setup.skipAI()
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    XCTAssertEqual(setup.step, .test)
  }

  @MainActor func testFailedOrCancelledRecordingCanRetryWithoutRestart() {
    let suite = "LocalFlow-onboarding-retry-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let setup = OnboardingCoordinator(preferences: preferences)
    reachTest(setup)
    for message in ["Microphone did not respond.", "Cancelled"] {
      setup.startTest(readiness: readySnapshot())
      let id = UUID()
      setup.dictationStarted(id: id)
      setup.dictationEnded(id: UUID(), message: "Old session")
      XCTAssertTrue(setup.testArmed)
      setup.dictationEnded(id: id, message: message)
      XCTAssertFalse(setup.testArmed)
      XCTAssertFalse(setup.testSucceeded)
      XCTAssertEqual(setup.testError, message)
      XCTAssertFalse(preferences.onboardingComplete)
    }
    setup.startTest(readiness: readySnapshot())
    XCTAssertNil(setup.testError)
    let id = UUID()
    setup.dictationStarted(id: id)
    setup.recordSuccessfulDictation(id: id)
    setup.dictationEnded(id: id, message: "Ready")
    XCTAssertTrue(setup.testSucceeded)
    setup.complete()
    XCTAssertTrue(preferences.onboardingComplete)
  }

  @MainActor func testSpeechModelPreparationFailureCanRetryBeforeArming() async {
    let suite = "LocalFlow-onboarding-prepare-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let ready = readySnapshot()
    var attempts = 0
    let setup = OnboardingCoordinator(
      preferences: AppPreferences(defaults: defaults), liveReadiness: { ready },
      prepareTest: {
        attempts += 1
        if attempts == 1 { throw DictationFailure.modelUnavailable }
      })
    reachTest(setup)
    await setup.armTest()
    XCTAssertFalse(setup.testArmed)
    XCTAssertFalse(setup.preparingTest)
    XCTAssertNotNil(setup.testError)
    await setup.armTest()
    XCTAssertTrue(setup.testArmed)
    XCTAssertFalse(setup.preparingTest)
    XCTAssertNil(setup.testError)
    XCTAssertEqual(attempts, 2)
  }

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

  @MainActor func testModelWorkDoesNotMislabelGrantedPermissions() {
    var readiness = readySnapshot()
    readiness.runtime = .init(state: .unloaded, loaded: false, leased: false, installing: true)
    XCTAssertFalse(readiness.readyForTest)
    XCTAssertEqual(readiness.testBlockedReason, "Wait for the model operation to finish.")
    readiness.runtime = .init(state: .unloaded, loaded: false, leased: false, installing: false)
    XCTAssertTrue(readiness.readyForTest)
    XCTAssertNil(readiness.testBlockedReason)
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
