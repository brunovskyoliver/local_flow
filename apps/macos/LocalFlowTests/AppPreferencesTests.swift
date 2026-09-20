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
    XCTAssertFalse(AppPreferences(defaults: defaults).meetingTranscriptionEnabled)
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
    XCTAssertFalse(AppPreferences(defaults: defaults).meetingDiarizationEnabled)
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
}
