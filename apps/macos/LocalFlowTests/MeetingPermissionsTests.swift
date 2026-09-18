import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingPermissionsTests: XCTestCase {
  /// Records every permission call so a test can prove nothing else was touched.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var log: [String] = []
    var microphone: AVAuthorizationStatus
    var screen: Bool
    var microphoneAfterRequest: AVAuthorizationStatus
    var screenAfterRequest: Bool
    init(
      microphone: AVAuthorizationStatus, screen: Bool,
      microphoneAfterRequest: AVAuthorizationStatus? = nil, screenAfterRequest: Bool? = nil
    ) {
      self.microphone = microphone
      self.screen = screen
      self.microphoneAfterRequest = microphoneAfterRequest ?? microphone
      self.screenAfterRequest = screenAfterRequest ?? screen
    }
    func record(_ name: String) { lock.withLock { log.append(name) } }
    var permissions: MeetingPermissions {
      MeetingPermissions(
        microphoneStatus: { [self] in
          record("microphoneStatus")
          return lock.withLock { microphone }
        },
        requestMicrophone: { [self] in
          record("requestMicrophone")
          lock.withLock { microphone = microphoneAfterRequest }
          return lock.withLock { microphone == .authorized }
        },
        screenRecordingGranted: { [self] in
          record("screenPreflight")
          return lock.withLock { screen }
        },
        requestScreenRecording: { [self] in
          record("requestScreen")
          lock.withLock { screen = screenAfterRequest }
          return lock.withLock { screen }
        })
    }
  }

  func testAuthorizedMicrophoneAndGrantedScreenProceedWithoutRequests() async {
    let calls = Calls(microphone: .authorized, screen: true)
    let outcome = await calls.permissions.check()
    XCTAssertEqual(outcome, .granted)
    XCTAssertEqual(calls.log, ["microphoneStatus", "screenPreflight"])
  }

  func testNotDeterminedMicrophoneRequestsOnceThenRechecks() async {
    let calls = Calls(microphone: .notDetermined, screen: true, microphoneAfterRequest: .authorized)
    let outcome = await calls.permissions.check()
    XCTAssertEqual(outcome, .granted)
    XCTAssertEqual(
      calls.log, ["microphoneStatus", "requestMicrophone", "microphoneStatus", "screenPreflight"])
    let refused = Calls(microphone: .notDetermined, screen: true, microphoneAfterRequest: .denied)
    let refusal = await refused.permissions.check()
    XCTAssertEqual(
      refusal, .refused(kind: .microphone, text: MeetingErrorMessage.microphonePermission))
    XCTAssertEqual(refused.log.filter { $0 == "requestMicrophone" }.count, 1)
    XCTAssertFalse(refused.log.contains("screenPreflight"), "the first refusal wins")
  }

  func testDeniedAndRestrictedMicrophoneRefuseWithExistingGuidance() async {
    for status in [AVAuthorizationStatus.denied, .restricted] {
      let calls = Calls(microphone: status, screen: true)
      let outcome = await calls.permissions.check()
      XCTAssertEqual(
        outcome, .refused(kind: .microphone, text: MeetingErrorMessage.microphonePermission))
      XCTAssertEqual(calls.log, ["microphoneStatus"], "no request when already decided")
    }
    XCTAssertEqual(
      MeetingErrorMessage.microphonePermission,
      "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone."
    )
  }

  func testScreenRecordingPreflightFalseRequestsOnceAndRefusesWithExactText() async {
    let granted = Calls(microphone: .authorized, screen: false, screenAfterRequest: true)
    let outcome = await granted.permissions.check()
    XCTAssertEqual(outcome, .granted)
    XCTAssertEqual(
      granted.log, ["microphoneStatus", "screenPreflight", "requestScreen", "screenPreflight"])
    let refused = Calls(microphone: .authorized, screen: false, screenAfterRequest: false)
    let refusal = await refused.permissions.check()
    XCTAssertEqual(
      refusal,
      .refused(
        kind: .system,
        text:
          "System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
      ))
    XCTAssertEqual(refused.log.filter { $0 == "requestScreen" }.count, 1)
    XCTAssertEqual(
      Set(refused.log), ["microphoneStatus", "screenPreflight", "requestScreen"],
      "no other permission API")
  }

  func testSettingsDeepLinksNameTheTwoPanesOnly() {
    XCTAssertEqual(
      MeetingPermissions.settingsURL(for: .microphone)?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    XCTAssertEqual(
      MeetingPermissions.settingsURL(for: .system)?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }
}
