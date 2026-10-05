import Foundation
import LocalFlowCore

/// Exact user-facing texts from `contracts/meeting-storage.md`. Nothing here
/// carries a path, a title or an OS description beyond a numeric code.
enum MeetingErrorMessage {
  static let microphonePermission =
    "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone."
  static let screenRecordingPermission =
    "System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
  static let notEnoughFreeSpace = "Not enough free space to record (needs at least 500 MB)"
  static let lowFreeSpaceWarning = "Less than 2 GB free"
  static let dictationInProgress = "Dictation in progress"
  static let meetingInProgress = "Meeting in progress"
  static let pausedForSleep = "Paused because the Mac went to sleep"
  static let notesNotSaved = "Notes not saved"
  static let deletionIncomplete = "Deletion incomplete"
  static let noPlayableAudio = "No playable audio"

  /// `permissionRevoked` names the track; every other reason has one fixed text.
  static func text(for reason: MeetingFailureReason, track: MeetingTrackKind? = nil) -> String {
    switch reason {
    case .storageWriteFailed:
      return
        "Recording stopped: audio could not be written to disk. What was recorded so far was kept."
    case .storageUnavailable: return "Recording stopped: the meeting folder is unavailable."
    case .encoderFailed:
      return "Recording stopped: the audio encoder failed. What was recorded so far was kept."
    case .notRunningAtLastState:
      return
        "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible."
    case .deviceLost: return "The microphone disconnected. The meeting continued with system audio."
    case .streamStopped: return "System audio stopped. The meeting continued with the microphone."
    case .permissionRevoked:
      let name: String
      switch track {
      case .microphone: name = "Microphone"
      case .system: name = "System audio"
      case nil: name = "Audio"
      }
      return "\(name) permission was revoked during the meeting."
    case .bothSourcesFailed: return "Recording stopped because both audio sources failed."
    case .recordMissing:
      return "Files were found without a meeting record. They were kept and listed here."
    case .fileMissing: return "The audio file for this segment is missing."
    case .segmentOpenFailed:
      return "The meeting could not start because an audio file could not be created."
    case .unrecoverableMedia: return "This track could not be made playable. The file was kept."
    }
  }

  static func notPlayable(_ reason: MeetingFailureReason) -> String {
    "Not playable: " + text(for: reason)
  }
}
