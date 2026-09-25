import AppKit
import XCTest

@testable import LocalFlow

final class AppPreferencesTests: XCTestCase {
  @MainActor func testMeetingTranscriptionDefaultsAndPersists() {
    let suite = "LocalFlow-meetings-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.meetingTranscriptionEnabled)
    preferences.meetingTranscriptionEnabled = false
    // No Settings switch any more: the value lives only for the session.
    XCTAssertNil(defaults.object(forKey: "meetingTranscriptionEnabled"))
    XCTAssertTrue(AppPreferences(defaults: defaults).meetingTranscriptionEnabled)
    XCTAssertFalse(MeetingStartOptions(preferences: preferences).transcription)
    preferences.meetingTranscriptionEnabled = true
    XCTAssertTrue(MeetingStartOptions(preferences: preferences).transcription)
  }

  @MainActor func testMeetingDiarizationDefaultsOnAndPersists() {
    let suite = "LocalFlow-speakers-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.meetingDiarizationEnabled)
    preferences.meetingDiarizationEnabled = false
    XCTAssertTrue(AppPreferences(defaults: defaults).meetingDiarizationEnabled)
  }

  /// Automatic by default under `settings.meetingLanguage`; an unknown stored value
  /// falls back to Automatic rather than failing to load the preferences.
  @MainActor func testMeetingLanguageDefaultsToAutomaticAndPersists() {
    let suite = "LocalFlow-language-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.meetingLanguage, .automatic)
    preferences.meetingLanguage = .slovak
    XCTAssertEqual(defaults.string(forKey: "settings.meetingLanguage"), "slovak")
    XCTAssertEqual(AppPreferences(defaults: defaults).meetingLanguage, .slovak)
    XCTAssertEqual(MeetingLanguage.slovak.whisperCode, "sk")
    XCTAssertEqual(MeetingLanguage.slovak.pipelineTag, "lang_sk_prompt_v1")
    XCTAssertEqual(MeetingLanguage.automatic.whisperCode, "auto")
    defaults.set("klingon", forKey: "settings.meetingLanguage")
    XCTAssertEqual(AppPreferences(defaults: defaults).meetingLanguage, .automatic)
  }

  /// English and Slovak only: a stored Czech choice reads as the default and is
  /// rewritten, and no other language is selectable or has a context sentence.
  @MainActor func testStoredCzechMeetingLanguageMigratesToDefault() {
    let suite = "LocalFlow-language-czech-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("czech", forKey: "settings.meetingLanguage")
    XCTAssertEqual(AppPreferences(defaults: defaults).meetingLanguage, .defaultLanguage)
    XCTAssertEqual(defaults.string(forKey: "settings.meetingLanguage"), "automatic")
    XCTAssertEqual(MeetingLanguage.allCases, [.automatic, .slovak, .english])
    XCTAssertEqual(Set(MeetingLanguage.contextSentences.keys), ["en", "sk"])
    XCTAssertEqual(MeetingLanguage.supportedCodes, ["en", "sk"])
    XCTAssertEqual(MeetingLanguage.automatic.pipelineTag, "lang_auto_prompt_v1+speech_language_v3")
  }

  /// Feature 010 (FR-038): on by default under `settings.speakerIdentificationEnabled`.
  @MainActor func testSpeakerIdentificationDefaultsOnAndPersists() {
    let suite = "LocalFlow-identification-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.speakerIdentificationEnabled)
    preferences.speakerIdentificationEnabled = false
    XCTAssertTrue(AppPreferences(defaults: defaults).speakerIdentificationEnabled)
    XCTAssertNil(defaults.object(forKey: "settings.speakerIdentificationEnabled"))
  }

  /// Feature 011 (FR-035): on by default under `settings.meetingSummariesAutomatic`;
  /// toggling it must not disturb the existing preference defaults.
  @MainActor func testMeetingSummariesDefaultsOnAndPersists() {
    let suite = "LocalFlow-summaries-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.meetingSummariesAutomatic)
    preferences.meetingSummariesAutomatic = false
    XCTAssertTrue(AppPreferences(defaults: defaults).meetingSummariesAutomatic)
    XCTAssertNil(defaults.object(forKey: "settings.meetingSummariesAutomatic"))
    let fresh = AppPreferences(defaults: defaults)
    XCTAssertTrue(fresh.meetingTranscriptionEnabled)
    XCTAssertTrue(fresh.meetingDiarizationEnabled)
    XCTAssertTrue(fresh.speakerIdentificationEnabled)
  }

  /// Older builds persisted the always-on meeting switches; launch removes those keys
  /// and ignores their values.
  @MainActor func testRetiredMeetingSwitchKeysAreRemovedAtLaunch() {
    let suite = "LocalFlow-retired-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for key in AppPreferences.retiredKeys { defaults.set(false, forKey: key) }
    let preferences = AppPreferences(defaults: defaults)
    for key in AppPreferences.retiredKeys { XCTAssertNil(defaults.object(forKey: key), key) }
    XCTAssertTrue(preferences.meetingTranscriptionEnabled)
    XCTAssertTrue(preferences.meetingDiarizationEnabled)
    XCTAssertTrue(preferences.meetingSummariesAutomatic)
    XCTAssertTrue(preferences.speakerIdentificationEnabled)
    preferences.meetingDiarizationEnabled = false
    XCTAssertNil(defaults.object(forKey: "meetingDiarizationEnabled"))
  }

  @MainActor func testRewriteModeDefaultsPersistenceAndUnknownValue() {
    let suite = "LocalFlow-mode-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(AppPreferences(defaults: defaults).rewriteDefaultMode, .clean)
    for mode in RewriteMode.allCases {
      let preferences = AppPreferences(defaults: defaults)
      preferences.rewriteDefaultMode = mode
      XCTAssertEqual(AppPreferences(defaults: defaults).rewriteDefaultMode, mode)
      XCTAssertFalse(SettingsViewModel.rewriteModeDefinition(mode).isEmpty)
    }
    defaults.set("future-mode", forKey: "rewriteDefaultMode")
    XCTAssertEqual(AppPreferences(defaults: defaults).rewriteDefaultMode, .clean)
  }

  @MainActor func testAppearanceAndSetupSurviveRelaunch() {
    let suite = "LocalFlow-preferences-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.appearance, .system)
    XCTAssertFalse(preferences.onboardingComplete)
    XCTAssertFalse(preferences.keepModelReady)
    preferences.keepModelReady = true
    preferences.appearance = .dark
    preferences.completeOnboarding()
    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.appearance, .dark)
    XCTAssertTrue(restored.onboardingComplete)
    XCTAssertTrue(restored.keepModelReady)
    restored.keepModelReady = false
    XCTAssertFalse(AppPreferences(defaults: defaults).keepModelReady)
  }

  /// Light and Dark pin a native appearance; System must stay unset so the app
  /// keeps following the OS instead of freezing at the value read on launch.
  @MainActor func testAppearanceMapsToNativeValuesAndSystemFollowsTheOS() {
    XCTAssertNil(AppPreferences.Appearance.system.nsAppearance)
    XCTAssertEqual(AppPreferences.Appearance.light.nsAppearance?.name, .aqua)
    XCTAssertEqual(AppPreferences.Appearance.dark.nsAppearance?.name, .darkAqua)
    // Panels adopt the same value, so one assignment covers every native window.
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
    panel.appearance = AppPreferences.Appearance.dark.nsAppearance
    XCTAssertEqual(panel.effectiveAppearance.name, .darkAqua)
    panel.appearance = AppPreferences.Appearance.system.nsAppearance
    XCTAssertNil(panel.appearance, "System mode must not pin a panel appearance")
  }

  /// Settings writes the summary server; the analysis client reads it back as
  /// flowd's primary-backend headers, and only when Remote is complete.
  @MainActor func testSummaryServerBecomesPrimaryHeaders() throws {
    let suite = "LocalFlow-summary-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = FakeRewriteCredentialStore()
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.summaryServer, .local)
    preferences.summaryServerURL = " http://10.0.0.1:8000/v1 "
    preferences.summaryServerModel = "qwen3-8b"
    XCTAssertEqual(SummaryServer.headers(defaults: defaults, credentials: credentials), [:])
    preferences.summaryServer = .remote
    XCTAssertEqual(
      SummaryServer.headers(defaults: defaults, credentials: credentials),
      [
        "X-LocalFlow-Primary-URL": "http://10.0.0.1:8000/v1",
        "X-LocalFlow-Primary-Model": "qwen3-8b",
      ])
    try credentials.write(origin: SummaryServer.credentialAccount, secret: "key")
    XCTAssertEqual(
      SummaryServer.headers(defaults: defaults, credentials: credentials)[
        "X-LocalFlow-Primary-Key"],
      "key")
    preferences.summaryServerModel = ""
    XCTAssertEqual(SummaryServer.headers(defaults: defaults, credentials: credentials), [:])
    XCTAssertEqual(AppPreferences(defaults: defaults).summaryServer, .remote)
  }

  // MARK: Feature 012 context preferences (T010)

  @MainActor func testContextPreferencesDefaultOffOnFreshAndUpgradedProfiles() {
    for upgraded in [false, true] {
      let suite = "LocalFlow-context-\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      if upgraded {
        defaults.set(true, forKey: "rewriteEnabled")
        defaults.set(1, forKey: "setupVersion")
      }
      let preferences = AppPreferences(defaults: defaults)
      XCTAssertFalse(preferences.contextEnabled)
      XCTAssertFalse(preferences.contextRewriteEnabled)
      XCTAssertFalse(preferences.contextStyleEnabled)
      XCTAssertEqual(preferences.contextCategoryOverrides, [:])
      XCTAssertEqual(
        Set(preferences.contextExcludedBundleIDs),
        AppCategory.defaultExclusions.union([AppCategory.ownBundleID]))
      let settings = preferences.contextSettings()
      XCTAssertFalse(settings.enabled)
      XCTAssertFalse(settings.rewriteEnabled)
    }
  }

  @MainActor func testContextRulesAreCappedAndOwnBundleCannotBeRemoved() {
    let suite = "LocalFlow-context-caps-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.removeContextExclusion(AppCategory.ownBundleID)
    XCTAssertTrue(preferences.contextExcludedBundleIDs.contains(AppCategory.ownBundleID))
    XCTAssertFalse(preferences.addContextExclusion(""))
    XCTAssertFalse(preferences.addContextExclusion("has space"))
    var index = 0
    while preferences.contextExcludedBundleIDs.count < AppPreferences.maximumContextRules {
      XCTAssertTrue(preferences.addContextExclusion("com.example.app\(index)"))
      index += 1
    }
    XCTAssertFalse(preferences.addContextExclusion("com.example.one-more"))
    XCTAssertEqual(preferences.contextExcludedBundleIDs.count, 200)
    for index in 0..<200 {
      XCTAssertTrue(preferences.setContextCategory(.code, for: "com.example.editor\(index)"))
    }
    XCTAssertFalse(preferences.setContextCategory(.code, for: "com.example.editor200"))
    XCTAssertTrue(preferences.setContextCategory(.document, for: "com.example.editor0"))
    let reloaded = AppPreferences(defaults: defaults)
    XCTAssertEqual(reloaded.contextExcludedBundleIDs.count, 200)
    XCTAssertEqual(reloaded.contextCategoryOverrides.count, 200)
    XCTAssertEqual(reloaded.contextCategoryOverrides["com.example.editor0"], .document)
    XCTAssertTrue(reloaded.contextExcludedBundleIDs.contains(AppCategory.ownBundleID))
  }

  @MainActor func testContextSettingsSeeChangesWithoutRelaunch() {
    let suite = "LocalFlow-context-live-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.contextRewriteEnabled = true
    XCTAssertFalse(preferences.contextSettings().rewriteEnabled, "needs contextEnabled")
    preferences.contextEnabled = true
    preferences.addContextExclusion("com.example.chat")
    preferences.setContextCategory(.workChat, for: "com.example.chat2")
    let settings = preferences.contextSettings()
    XCTAssertTrue(settings.enabled)
    XCTAssertTrue(settings.rewriteEnabled)
    XCTAssertTrue(settings.isExcluded("com.example.chat"))
    XCTAssertEqual(settings.categoryOverrides["com.example.chat2"], .workChat)
    preferences.contextEnabled = false
    XCTAssertFalse(preferences.contextSettings().enabled)
    XCTAssertFalse(preferences.contextSettings().rewriteEnabled)
  }
}
