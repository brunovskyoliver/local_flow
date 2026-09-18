import CoreGraphics
import ScreenCaptureKit
import XCTest

/// Launch evidence only. Permission, keyboard and insertion probes require the
/// signed interactive procedure recorded in the feature's acceptance documents.
final class PlatformProbeTests: XCTestCase {
  @MainActor
  func testSignedMenuBarApplicationLaunches() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.terminate()
  }
}

/// Optional platform probe for Feature 004: the ScreenCaptureKit audio-only
/// stream configuration and the screen-recording access calls the design
/// depends on exist on the build SDK. Skipped, not failed, when screen
/// recording is not granted to the test host.
final class MeetingPlatformProbeTests: XCTestCase {
  func testScreenCaptureKitAudioOnlySymbolsAreAvailableOnTheBuildSDK() async throws {
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    XCTAssertTrue(configuration.capturesAudio)
    XCTAssertTrue(configuration.excludesCurrentProcessAudio)
    try XCTSkipUnless(
      CGPreflightScreenCaptureAccess(),
      "Screen & System Audio Recording is not granted to the test host; probe skipped.")
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    XCTAssertFalse(content.displays.isEmpty)
  }
}
