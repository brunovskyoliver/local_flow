import AVFoundation
import CoreGraphics
import Foundation

/// Microphone and screen-recording checks for the start sequence (FR-021).
/// Only these two permissions are ever touched; each request closure runs at
/// most once per start and never when the status is already granted.
struct MeetingPermissions: Sendable {
  enum Outcome: Equatable, Sendable {
    case granted
    case refused(kind: MeetingTrackKind, text: String)
  }

  var microphoneStatus: @Sendable () -> AVAuthorizationStatus
  var requestMicrophone: @Sendable () async -> Bool
  var screenRecordingGranted: @Sendable () -> Bool
  var requestScreenRecording: @Sendable () -> Bool

  static let live = MeetingPermissions(
    microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
    requestMicrophone: { await AVCaptureDevice.requestAccess(for: .audio) },
    screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
    requestScreenRecording: { CGRequestScreenCaptureAccess() })

  /// Microphone first, then screen recording; the first refusal wins.
  func check() async -> Outcome {
    switch microphoneStatus() {
    case .authorized: break
    case .notDetermined:
      _ = await requestMicrophone()
      guard microphoneStatus() == .authorized else {
        return .refused(kind: .microphone, text: MeetingErrorMessage.microphonePermission)
      }
    default:
      return .refused(kind: .microphone, text: MeetingErrorMessage.microphonePermission)
    }
    if !screenRecordingGranted() {
      _ = requestScreenRecording()
      guard screenRecordingGranted() else {
        return .refused(kind: .system, text: MeetingErrorMessage.screenRecordingPermission)
      }
    }
    return .granted
  }

  /// Deep link for the "Open System Settings" action next to a refusal notice.
  static func settingsURL(for kind: MeetingTrackKind) -> URL? {
    let pane = kind == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
  }
}
