import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
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
    XCTAssertEqual(setup.step, .purpose)
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
    setup.purpose = .dictation
    setup.advance(readiness: readiness)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .aiDetails)
    XCTAssertEqual(setup.aiMode, .local)
    XCTAssertTrue(started.isEmpty, "Nothing downloads before a model is chosen")
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertEqual(started, [true])
    XCTAssertEqual(meetings, 0, "Dictation only asks when the user presses Download")
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

// MARK: Feature 022

extension OnboardingTests {
  /// A throwaway suite; `addTeardownBlock` removes it after the test.
  @MainActor private func preferences() -> (AppPreferences, UserDefaults) {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return (AppPreferences(defaults: defaults), defaults)
  }

  /// Everything every path can ask for, so only the routing decides the steps.
  @MainActor private func everythingReady() -> SettingsViewModel.Snapshot {
    var snapshot = readySnapshot()
    snapshot.meetingModelInstalled = true
    snapshot.speakerModelInstalled = true
    return snapshot
  }

  /// Walks to the end of setup, then checks Back retraces the same steps.
  @MainActor private func walk(
    _ purpose: AppPreferences.Purpose, _ mode: OnboardingCoordinator.AIMode
  ) -> [OnboardingCoordinator.Step] {
    let (preferences, _) = preferences()
    let setup = OnboardingCoordinator(preferences: preferences)
    let ready = everythingReady()
    setup.advance(readiness: ready)
    setup.purpose = purpose
    setup.advance(readiness: ready)
    setup.aiMode = mode
    var steps = [setup.step]
    while setup.step != .test, setup.step != .complete {
      setup.advance(readiness: ready)
      steps.append(setup.step)
    }
    guard setup.step == .test else { return steps }
    XCTAssertEqual(setup.path, [.introduction, .purpose] + steps)
    for step in steps.dropLast().reversed() {
      setup.back()
      XCTAssertEqual(setup.step, step)
    }
    return steps
  }

  @MainActor func testPurposeIsStoredAndMissingMeansBoth() {
    let suite = "LocalFlow-onboarding-purpose-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(AppPreferences(defaults: defaults).purpose, .both)
    defaults.set("nonsense", forKey: "setup.purpose")
    XCTAssertEqual(AppPreferences(defaults: defaults).purpose, .both)
    let preferences = AppPreferences(defaults: defaults)
    preferences.purpose = .meetings
    XCTAssertEqual(defaults.string(forKey: "setup.purpose"), "meetings")
    XCTAssertEqual(AppPreferences(defaults: defaults).purpose, .meetings)
  }

  @MainActor func testMeetingReadinessNeedsStorageAndMicrophoneButNoSystemAudio() {
    var state = SettingsViewModel.Snapshot()
    XCTAssertFalse(state.readyForMeetings)
    state.storageAvailable = true
    XCTAssertFalse(state.readyForMeetings)
    state.microphone = .granted
    state.systemAudio = .denied
    XCTAssertTrue(state.readyForMeetings, "A refused system audio request does not block")
    XCTAssertFalse(state.readyForTest, "No model, Input Monitoring or shortcut needed")
    state.inputMonitoring = .granted
    state.accessibility = .granted
    XCTAssertFalse(state.hasMissingPermissions, "System audio is not a dictation permission")
  }

  @MainActor func testMeetingModelsReadyNeedsSpeechWhisperAndSpeakers() {
    var state = SettingsViewModel.Snapshot()
    state.modelInstalled = true
    state.meetingModelInstalled = true
    XCTAssertFalse(state.meetingModelsReady)
    state.speakerModelInstalled = true
    XCTAssertTrue(state.meetingModelsReady)
    state.modelInstalled = false
    XCTAssertFalse(state.meetingModelsReady)
  }

  @MainActor func testEveryRowOfThePathTable() {
    XCTAssertEqual(
      walk(.meetings, .remote), [.ai, .aiDetails, .permissions, .personalize, .complete])
    XCTAssertEqual(
      walk(.meetings, .local), [.ai, .aiDetails, .downloads, .permissions, .personalize, .complete])
    XCTAssertEqual(walk(.meetings, .off), [.ai, .downloads, .permissions, .personalize, .complete])
    let local: [OnboardingCoordinator.Step] = [
      .ai, .aiDetails, .downloads, .permissions, .personalize, .test,
    ]
    let off: [OnboardingCoordinator.Step] = [.ai, .downloads, .permissions, .personalize, .test]
    for purpose in [AppPreferences.Purpose.dictation, .both] {
      XCTAssertEqual(walk(purpose, .local), local, "\(purpose)")
      XCTAssertEqual(walk(purpose, .remote), local, "\(purpose)")
      XCTAssertEqual(walk(purpose, .off), off, "\(purpose)")
    }
  }

  @MainActor func testPurposeStartsAsBothAndIsStoredOnLeavingTheStep() {
    let (preferences, _) = preferences()
    let setup = OnboardingCoordinator(preferences: preferences)
    let ready = everythingReady()
    XCTAssertEqual(setup.purpose, .both)
    setup.advance(readiness: ready)
    setup.purpose = .meetings
    XCTAssertEqual(preferences.purpose, .both, "Only leaving the step stores the choice")
    setup.advance(readiness: ready)
    XCTAssertEqual(preferences.purpose, .meetings)
    XCTAssertFalse(preferences.onboardingComplete)
  }

  @MainActor func testAMeetingPathFinishesAfterPersonalizeOnlyWithMicrophoneAndStorage() {
    let (preferences, _) = preferences()
    let setup = OnboardingCoordinator(preferences: preferences)
    var readiness = everythingReady()
    readiness.inputMonitoring = .denied
    readiness.shortcutReady = false
    setup.advance(readiness: readiness)
    setup.purpose = .meetings
    setup.advance(readiness: readiness)
    setup.skipAI()
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions)
    readiness.microphone = .denied
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions)
    readiness.microphone = .granted
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .personalize)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .complete)
    XCTAssertTrue(preferences.onboardingComplete)
  }
}

// MARK: Feature 022, User Story 1

extension OnboardingTests {
  @MainActor private func remote(_ preferences: AppPreferences) -> RemoteDictationModel {
    RemoteDictationModel(preferences: preferences, enrollment: { nil }, turnOff: {})
  }

  @MainActor private func enroll(_ preferences: AppPreferences, _ state: RemoteDictationState) {
    preferences.setRemoteServerURL("https://mini.example.com")
    preferences.confirmRemoteConsent()
    preferences.remoteEnabled = true
    preferences.remoteState = state
  }

  /// T004 (US1 scenarios 1 to 3, SC-001).
  @MainActor func testMeetingsOnAServerSkipsDownloadsAndFinishesOnNotetaker() {
    let (preferences, _) = preferences()
    var downloads = 0
    var meetingModels = 0
    var notetaker = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, startDownloads: { _ in downloads += 1 },
      startMeetingModels: { meetingModels += 1 }, openNotetaker: { notetaker += 1 })
    var readiness = SettingsViewModel.Snapshot()
    readiness.storageAvailable = true
    readiness.microphone = .granted
    setup.advance(readiness: readiness)
    setup.purpose = .meetings
    setup.advance(readiness: readiness)
    setup.aiMode = .remote
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .aiDetails)
    XCTAssertFalse(preferences.serverOnly, "Choosing the card alone changes nothing")
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .permissions)
    XCTAssertTrue(preferences.serverOnly)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .personalize)
    XCTAssertEqual(notetaker, 0)
    setup.advance(readiness: readiness)
    XCTAssertEqual(setup.step, .complete)
    XCTAssertTrue(preferences.onboardingComplete)
    XCTAssertEqual(notetaker, 1)
    XCTAssertEqual(downloads, 0)
    XCTAssertEqual(meetingModels, 0)
  }

  /// T004: only the path a server serves meetings on may continue, approved or pending.
  @MainActor func testAPendingDeviceContinuesAsAnApprovedOneDoesAndARewriteServerDoesNot() {
    let (preferences, _) = preferences()
    let model = remote(preferences)
    for state in [RemoteDictationState.pinned, .rejected, .revoked] {
      enroll(preferences, state)
      XCTAssertFalse(
        OnboardingView.serverReady(model, purpose: .meetings, legacy: false), "\(state)")
    }
    for state in [RemoteDictationState.pending, .approved] {
      enroll(preferences, state)
      XCTAssertTrue(
        OnboardingView.serverReady(model, purpose: .meetings, legacy: false), "\(state)")
    }
    preferences.resetRemote()
    XCTAssertFalse(OnboardingView.serverReady(model, purpose: .meetings, legacy: true))
    XCTAssertTrue(OnboardingView.serverReady(model, purpose: .both, legacy: true))
    XCTAssertTrue(OnboardingView.serverReady(model, purpose: .dictation, legacy: true))
  }

  @MainActor func testBothOnAServerKeepsServerOnlyOffAndDoesNotOpenNotetaker() {
    let (preferences, _) = preferences()
    var notetaker = 0
    let setup = OnboardingCoordinator(preferences: preferences, openNotetaker: { notetaker += 1 })
    let ready = everythingReady()
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    setup.aiMode = .remote
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertFalse(preferences.serverOnly)
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    setup.skipTest()
    XCTAssertEqual(notetaker, 0)
  }

  /// T006 (FR-012): the variant follows the purpose and the versioned text stays.
  @MainActor func testMeetingConsentIsChosenByPurposeAndStatesRetention() {
    let (preferences, _) = preferences()
    let model = remote(preferences)
    XCTAssertEqual(model.currentConsentText, RemoteDictationModel.consentText)
    preferences.purpose = .dictation
    XCTAssertEqual(model.currentConsentText, RemoteDictationModel.consentText)
    preferences.serverOnly = true
    XCTAssertEqual(model.currentConsentText, RemoteDictationModel.meetingConsentText)
    preferences.serverOnly = false
    preferences.purpose = .meetings
    XCTAssertEqual(model.currentConsentText, RemoteDictationModel.meetingConsentText)
    let text = RemoteDictationModel.meetingConsentText.lowercased()
    for phrase in [
      "meeting audio", "meeting transcripts", "summaries", "administrator can see audio",
      "until they are merged", "at most 7 days", "recordings wait",
      "if you set up dictation later", "this server",
    ] {
      XCTAssertTrue(text.contains(phrase), phrase)
    }
    XCTAssertFalse(text.contains("stays local"), "No local dictation on a server-only path")
    XCTAssertEqual(AppPreferences.remoteConsentVersion, 2, "The versioned text did not change")
  }

  /// T006: confirming the variant is a current consent, so meetings may reach the server.
  @MainActor func testConfirmingTheMeetingConsentAllowsMeetingsOnTheServer() async {
    let (preferences, _) = preferences()
    preferences.purpose = .meetings
    let model = remote(preferences)
    model.serverDraft = "https://mini.example.com"
    await model.confirmConsent()
    XCTAssertTrue(preferences.remoteConsentCurrent)
    XCTAssertFalse(model.needsConsentUpdate)
  }

  /// T006: every server path states the 7-day handoff retention, in every enrollment state.
  @MainActor func testEveryServerPathStatesTheRetention() {
    let (preferences, _) = preferences()
    let model = remote(preferences)
    for purpose in AppPreferences.Purpose.allCases {
      preferences.purpose = purpose
      preferences.resetRemote()
      XCTAssertTrue(OnboardingView.remotePrivacy(model).contains("at most 7 days"), "\(purpose)")
      for state in [RemoteDictationState.pinned, .pending, .approved] {
        enroll(preferences, state)
        XCTAssertTrue(
          OnboardingView.remotePrivacy(model).contains("at most 7 days"), "\(purpose) \(state)")
      }
    }
  }

  @MainActor func testMeetingOnlyPrivacyCopyNeverPromisesLocalDictation() {
    let (preferences, _) = preferences()
    preferences.purpose = .meetings
    let model = remote(preferences)
    for state in [RemoteDictationState.pinned, .pending, .approved] {
      enroll(preferences, state)
      XCTAssertFalse(OnboardingView.remotePrivacy(model).contains("ictation"), "\(state)")
    }
  }

  /// T007: the hint names what a meeting path still needs, never a keyboard permission.
  @MainActor func testMeetingBlockedReasonNeedsOnlyMicrophoneAndStorage() {
    var state = SettingsViewModel.Snapshot()
    XCTAssertEqual(state.meetingBlockedReason, "Allow Microphone access to record.")
    state.microphone = .granted
    XCTAssertEqual(
      state.meetingBlockedReason, "Local storage is not ready. Check Settings before recording.")
    state.storageAvailable = true
    XCTAssertNil(state.meetingBlockedReason)
  }

  /// T009 (FR-007, SC-003).
  @MainActor func testOnlyAMeetingPurposeLandsOnNotetaker() {
    let (preferences, _) = preferences()
    XCTAssertEqual(preferences.landingPage, .history, "A missing purpose keeps today's page")
    preferences.purpose = .dictation
    XCTAssertEqual(preferences.landingPage, .history)
    preferences.purpose = .both
    XCTAssertEqual(preferences.landingPage, .history)
    preferences.purpose = .meetings
    XCTAssertEqual(preferences.landingPage, .meetings)
  }

  /// A meetings-on-a-server setup up to the permissions step.
  @MainActor private func reachServerPermissions(
    _ setup: OnboardingCoordinator, _ preferences: AppPreferences
  ) {
    let ready = everythingReady()
    setup.advance(readiness: ready)
    setup.purpose = .meetings
    setup.advance(readiness: ready)
    setup.aiMode = .remote
    setup.advance(readiness: ready)
    enroll(preferences, .pending)
    preferences.useServerForEverything = true
    preferences.rewriteEnabled = true
    setup.advance(readiness: ready)
    XCTAssertTrue(preferences.serverOnly)
  }

  @MainActor private func assertServerUndone(_ preferences: AppPreferences, abandoned: Int) {
    XCTAssertFalse(preferences.serverOnly)
    XCTAssertFalse(preferences.useServerForEverything)
    XCTAssertFalse(preferences.rewriteEnabled)
    XCTAssertEqual(abandoned, 1)
  }

  /// T010 (FR-011): another location clears what the server path set.
  @MainActor func testBackToAnotherLocationClearsTheServerPath() {
    for skip in [false, true] {
      let (preferences, _) = preferences()
      var abandoned = 0
      var downloads: [Bool] = []
      let setup = OnboardingCoordinator(
        preferences: preferences, startDownloads: { downloads.append($0) },
        abandonServer: {
          abandoned += 1
          preferences.resetRemote()
        })
      reachServerPermissions(setup, preferences)
      setup.back()
      XCTAssertEqual(setup.step, .aiDetails)
      setup.back()
      XCTAssertEqual(setup.step, .ai)
      XCTAssertTrue(preferences.serverOnly, "Nothing changes until another choice is made")
      if skip {
        setup.skipAI()
        XCTAssertEqual(downloads, [false])
      } else {
        setup.aiMode = .local
        setup.advance(readiness: everythingReady())
        XCTAssertEqual(setup.step, .aiDetails)
      }
      assertServerUndone(preferences, abandoned: abandoned)
      XCTAssertFalse(preferences.remoteEnabled)
    }
  }

  /// T010 (FR-011): another purpose clears it too, even with the same location.
  @MainActor func testBackToAnotherPurposeClearsTheServerPath() {
    let (preferences, _) = preferences()
    var abandoned = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, abandonServer: { abandoned += 1 })
    reachServerPermissions(setup, preferences)
    setup.back()
    setup.back()
    setup.back()
    XCTAssertEqual(setup.step, .purpose)
    setup.purpose = .both
    setup.advance(readiness: everythingReady())
    XCTAssertEqual(preferences.purpose, .both)
    assertServerUndone(preferences, abandoned: abandoned)
  }

  /// T010: Back over the same choice keeps the enrolled server.
  @MainActor func testBackOverTheSameChoiceKeepsTheServer() {
    let (preferences, _) = preferences()
    var abandoned = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, abandonServer: { abandoned += 1 })
    reachServerPermissions(setup, preferences)
    let ready = everythingReady()
    setup.back()
    setup.back()
    setup.back()
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    setup.advance(readiness: ready)
    XCTAssertEqual(setup.step, .permissions)
    XCTAssertTrue(preferences.serverOnly)
    XCTAssertEqual(abandoned, 0)
  }

  /// T010 (spec edge case): a quit mid-setup leaves no completed-setup values behind.
  @MainActor func testRestartingAnUnfinishedMeetingSetupClearsTheServerPath() {
    let suite = "LocalFlow-onboarding-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let before = AppPreferences(defaults: defaults)
    reachServerPermissions(OnboardingCoordinator(preferences: before), before)

    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.serverOnly)
    var abandoned = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, abandonServer: { abandoned += 1 })
    setup.resumeUnfinishedSetup()
    assertServerUndone(preferences, abandoned: abandoned)
    XCTAssertEqual(preferences.purpose, .both)
    XCTAssertEqual(setup.purpose, .both)
    XCTAssertEqual(setup.step, .introduction)
  }

  /// T010: a meeting path that only chose its location has nothing on a server to clear.
  @MainActor func testRestartWithoutAServerTouchesNothingElse() {
    let (preferences, _) = preferences()
    preferences.purpose = .meetings
    preferences.rewriteEnabled = true
    var abandoned = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, abandonServer: { abandoned += 1 })
    setup.resumeUnfinishedSetup()
    XCTAssertEqual(abandoned, 0)
    XCTAssertTrue(preferences.rewriteEnabled)
    XCTAssertEqual(preferences.purpose, .both)
  }

  /// T010: a finished setup is never treated as abandoned.
  @MainActor func testAFinishedMeetingSetupKeepsItsServerOnLaunch() {
    let (preferences, _) = preferences()
    preferences.purpose = .meetings
    preferences.serverOnly = true
    preferences.completeOnboarding()
    var abandoned = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, abandonServer: { abandoned += 1 })
    setup.resumeUnfinishedSetup()
    XCTAssertTrue(preferences.serverOnly)
    XCTAssertEqual(preferences.purpose, .meetings)
    XCTAssertEqual(abandoned, 0)
  }
}

// MARK: Feature 022, User Story 2

extension OnboardingTests {
  /// Introduction to downloads, on the choices the user made.
  @MainActor private func reachDownloads(
    _ setup: OnboardingCoordinator, _ purpose: AppPreferences.Purpose,
    _ mode: OnboardingCoordinator.AIMode
  ) {
    let nothing = SettingsViewModel.Snapshot()
    setup.advance(readiness: nothing)
    setup.purpose = purpose
    setup.advance(readiness: nothing)
    if mode == .off {
      setup.skipAI()
    } else {
      setup.aiMode = mode
      setup.advance(readiness: nothing)
      setup.advance(readiness: nothing)
    }
    XCTAssertEqual(setup.step, .downloads)
  }

  /// T012 (FR-013, US2 scenario 1): the language model never blocks; the other three do.
  @MainActor func testMeetingsOnThisMacRequireTheirModelsAndStartThemAutomatically() {
    for mode in [OnboardingCoordinator.AIMode.local, .off] {
      let (preferences, _) = preferences()
      var started: [Bool] = []
      var meetingModels = 0
      let setup = OnboardingCoordinator(
        preferences: preferences, startDownloads: { started.append($0) },
        startMeetingModels: { meetingModels += 1 })
      reachDownloads(setup, .meetings, mode)
      XCTAssertEqual(started, [mode == .local])
      XCTAssertEqual(meetingModels, 1, "\(mode)")
      XCTAssertTrue(setup.meetingsRequested)
      var readiness = SettingsViewModel.Snapshot()
      readiness.modelInstalled = true
      setup.advance(readiness: readiness)
      XCTAssertEqual(setup.step, .downloads, "Speech alone doesn't record a local meeting")
      readiness.meetingModelInstalled = true
      setup.advance(readiness: readiness)
      XCTAssertEqual(setup.step, .downloads, "Speaker labels are still missing")
      readiness.speakerModelInstalled = true
      setup.advance(readiness: readiness)
      XCTAssertEqual(setup.step, .permissions, "\(mode)")
      setup.back()
      XCTAssertEqual(setup.step, .downloads)
      setup.back()
      XCTAssertNotEqual(setup.step, .downloads)
      if mode == .local { setup.advance(readiness: readiness) } else { setup.skipAI() }
      XCTAssertEqual(setup.step, .downloads)
      XCTAssertEqual(meetingModels, 1, "Coming back asks only once")
    }
  }

  /// T012 (FR-011): a request from a path the user left must not start later.
  @MainActor func testLeavingAMeetingsPathWithdrawsItsQueuedModels() {
    for leaveFor in [AppPreferences.Purpose.dictation, .meetings] {
      let (preferences, _) = preferences()
      var meetingModels = 0
      var withdrawn = 0
      let setup = OnboardingCoordinator(
        preferences: preferences, startMeetingModels: { meetingModels += 1 },
        cancelMeetingModels: { withdrawn += 1 })
      reachDownloads(setup, .meetings, .local)
      let nothing = SettingsViewModel.Snapshot()
      setup.back()
      setup.back()
      XCTAssertEqual(setup.step, .ai)
      XCTAssertEqual(withdrawn, 0, "Back alone changes nothing")
      if leaveFor == .dictation {
        setup.back()
        setup.purpose = .dictation
        setup.advance(readiness: nothing)
        setup.advance(readiness: nothing)
        setup.advance(readiness: nothing)
        XCTAssertEqual(setup.step, .downloads)
      } else {
        setup.aiMode = .remote
        setup.advance(readiness: nothing)
        setup.advance(readiness: nothing)
        XCTAssertEqual(setup.step, .permissions)
      }
      XCTAssertEqual(withdrawn, 1, "\(leaveFor)")
      XCTAssertFalse(setup.meetingsRequested)
      XCTAssertEqual(meetingModels, 1)
    }
  }

  /// T013: Download pressed by hand is the user's choice, on any later path.
  @MainActor func testAManualMeetingDownloadIsNeverWithdrawn() {
    let (preferences, _) = preferences()
    var withdrawn = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, cancelMeetingModels: { withdrawn += 1 })
    reachDownloads(setup, .dictation, .local)
    setup.downloadMeetingModels()
    setup.back()
    setup.advance(readiness: .init())
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertTrue(setup.meetingsRequested)
    XCTAssertEqual(withdrawn, 0)
  }

  /// T013 (US2 scenario 2): Retry asks again, and only on the downloads step.
  @MainActor func testRetryRequestsTheMeetingModelsAgain() {
    let (preferences, _) = preferences()
    var meetingModels = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, startMeetingModels: { meetingModels += 1 })
    setup.retryMeetingModels()
    XCTAssertEqual(meetingModels, 0, "Nothing to retry before the downloads step")
    reachDownloads(setup, .meetings, .off)
    XCTAssertEqual(meetingModels, 1)
    setup.retryMeetingModels()
    XCTAssertEqual(meetingModels, 2)
    XCTAssertTrue(setup.meetingsRequested)
  }

  /// T014 (FR-013): the Skip says what a meeting-only user gives up.
  func testMeetingSkipCopySaysSummariesWontBeAvailable() {
    XCTAssertTrue(OnboardingView.meetingSkipCopy.contains("summaries won't be available"))
  }

  /// T013: the step's gate is the coordinator's, so the button and `advance` can't disagree.
  @MainActor func testDownloadsGateFollowsThePurpose() {
    let (preferences, _) = preferences()
    let setup = OnboardingCoordinator(preferences: preferences)
    var readiness = SettingsViewModel.Snapshot()
    readiness.modelInstalled = true
    XCTAssertTrue(setup.downloadsReady(readiness))
    setup.purpose = .meetings
    XCTAssertFalse(setup.downloadsReady(readiness))
    readiness.meetingModelInstalled = true
    readiness.speakerModelInstalled = true
    XCTAssertTrue(setup.downloadsReady(readiness))
  }
}

// MARK: Feature 022, User Story 3

extension OnboardingTests {
  /// T015 (SC-002): today's steps plus the purpose step, and the same gate at each.
  @MainActor func testDictationIsTodaysFlowPlusThePurposeStep() {
    let today: [(OnboardingCoordinator.AIMode, [OnboardingCoordinator.Step])] = [
      (.local, [.introduction, .ai, .aiDetails, .downloads, .permissions, .personalize, .test]),
      (.remote, [.introduction, .ai, .aiDetails, .downloads, .permissions, .personalize, .test]),
      (.off, [.introduction, .ai, .downloads, .permissions, .personalize, .test]),
    ]
    for (mode, steps) in today {
      let (preferences, _) = preferences()
      var meetingModels = 0
      let setup = OnboardingCoordinator(
        preferences: preferences, startMeetingModels: { meetingModels += 1 })
      reachDownloads(setup, .dictation, mode)
      XCTAssertEqual(setup.path.filter { $0 != .purpose }, steps, "\(mode)")
      XCTAssertEqual(setup.path.count, steps.count + 1)
      XCTAssertEqual(meetingModels, 0, "\(mode)")
      let ready = readySnapshot()
      XCTAssertFalse(ready.meetingModelsReady)
      setup.advance(readiness: ready)
      XCTAssertEqual(setup.step, .permissions, "Meeting models stay optional")
      setup.advance(readiness: ready)
      setup.advance(readiness: ready)
      XCTAssertEqual(setup.step, .test)
      XCTAssertFalse(preferences.serverOnly)
      setup.skipTest()
      XCTAssertEqual(preferences.landingPage, .history)
    }
  }

  /// T016 (US3 scenario 2): Both asks for the meeting models itself, but doesn't wait for them.
  @MainActor func testBothOnThisMacStartsMeetingModelsAutomatically() {
    for mode in [OnboardingCoordinator.AIMode.local, .off] {
      let (preferences, _) = preferences()
      var meetingModels = 0
      let setup = OnboardingCoordinator(
        preferences: preferences, startMeetingModels: { meetingModels += 1 })
      reachDownloads(setup, .both, mode)
      XCTAssertEqual(meetingModels, 1, "\(mode)")
      XCTAssertTrue(setup.meetingsRequested)
      setup.advance(readiness: readySnapshot())
      XCTAssertEqual(setup.step, .permissions, "Only meeting notes alone need them first")
      XCTAssertFalse(preferences.serverOnly)
    }
  }

  /// T016 (FR-014): the server handles meetings; the speech model stays as the fallback.
  @MainActor func testBothOnAServerRequestsNoMeetingModelsAndKeepsServerOnlyOff() {
    let (preferences, _) = preferences()
    var started: [Bool] = []
    var meetingModels = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, startDownloads: { started.append($0) },
      startMeetingModels: { meetingModels += 1 })
    reachDownloads(setup, .both, .remote)
    XCTAssertEqual(started, [false])
    XCTAssertEqual(meetingModels, 0)
    XCTAssertFalse(setup.meetingsRequested)
    XCTAssertFalse(preferences.serverOnly)
  }

  /// T016 (FR-011): Both on this Mac, then Back to a server, drops what hasn't started.
  @MainActor func testChangingBothToAServerWithdrawsQueuedMeetingModels() {
    let (preferences, _) = preferences()
    var withdrawn = 0
    let setup = OnboardingCoordinator(
      preferences: preferences, cancelMeetingModels: { withdrawn += 1 })
    reachDownloads(setup, .both, .local)
    setup.back()
    setup.back()
    setup.aiMode = .remote
    setup.advance(readiness: .init())
    setup.advance(readiness: .init())
    XCTAssertEqual(setup.step, .downloads)
    XCTAssertEqual(withdrawn, 1)
    XCTAssertFalse(setup.meetingsRequested)
    XCTAssertFalse(preferences.serverOnly)
  }

  /// T017 (FR-008, SC-003): updating changes nothing for a finished setup with no purpose.
  @MainActor func testAFinishedInstallWithNoStoredPurposeKeepsItsPageAndShortcut() {
    let (preferences, defaults) = preferences()
    preferences.completeOnboarding()
    XCTAssertNil(defaults.string(forKey: "setup.purpose"))
    let updated = AppPreferences(defaults: defaults)
    OnboardingCoordinator(preferences: updated).resumeUnfinishedSetup()
    XCTAssertTrue(updated.onboardingComplete)
    XCTAssertEqual(updated.purpose, .both)
    XCTAssertEqual(updated.landingPage, .history)
    XCTAssertNotEqual(updated.purpose, .meetings, "Every shortcut guard tests for this purpose")
    XCTAssertFalse(updated.serverOnly)
    XCTAssertNil(defaults.string(forKey: "setup.purpose"), "Launch stores no purpose for them")
  }
}

// MARK: Feature 022, User Story 4

extension OnboardingTests {
  /// T018 (FR-010): the shortcut guards read the purpose, so it changes before the install.
  @MainActor func testSetUpDictationAllowsTheShortcutAndKeepsTheMeetingSetup() {
    let (preferences, _) = preferences()
    preferences.purpose = .meetings
    preferences.serverOnly = true
    preferences.completeOnboarding()
    var purposeAtInstall: [AppPreferences.Purpose] = []
    let setup = OnboardingCoordinator(
      preferences: preferences, installShortcut: { purposeAtInstall.append(preferences.purpose) })
    setup.setUpDictation()
    XCTAssertEqual(purposeAtInstall, [.both])
    XCTAssertEqual(preferences.purpose, .both)
    XCTAssertEqual(setup.purpose, .both)
    XCTAssertTrue(preferences.serverOnly, "The meeting consent already covers later dictation")
    XCTAssertTrue(preferences.onboardingComplete)
    XCTAssertEqual(setup.step, .introduction, "Nothing else in setup repeats")
    setup.setUpDictation()
    XCTAssertEqual(purposeAtInstall, [.both], "Only a meeting-only user has this to do")
  }

  /// T018: the Settings row reaches the composition root.
  @MainActor func testTheSetUpDictationActionReachesPerform() async {
    var received = 0
    let model = SettingsViewModel(
      observe: { .init() },
      perform: { action in
        if case .setUpDictation = action { received += 1 }
      })
    await model.run(.setUpDictation)
    XCTAssertEqual(received, 1)
  }
}
