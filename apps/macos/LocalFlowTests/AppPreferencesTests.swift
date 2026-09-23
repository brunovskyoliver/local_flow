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
    XCTAssertFalse(defaults.bool(forKey: "meetingTranscriptionEnabled"))
    // No Settings switch any more: a stored `false` from an older build is ignored.
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

  /// Feature 010 (FR-038): on by default under `settings.speakerIdentificationEnabled`.
  @MainActor func testSpeakerIdentificationDefaultsOnAndPersists() {
    let suite = "LocalFlow-identification-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.speakerIdentificationEnabled)
    preferences.speakerIdentificationEnabled = false
    XCTAssertTrue(AppPreferences(defaults: defaults).speakerIdentificationEnabled)
    XCTAssertEqual(defaults.object(forKey: "settings.speakerIdentificationEnabled") as? Bool, false)
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
    XCTAssertEqual(defaults.object(forKey: "settings.meetingSummariesAutomatic") as? Bool, false)
    let fresh = AppPreferences(defaults: defaults)
    XCTAssertTrue(fresh.meetingTranscriptionEnabled)
    XCTAssertTrue(fresh.meetingDiarizationEnabled)
    XCTAssertTrue(fresh.speakerIdentificationEnabled)
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
}
