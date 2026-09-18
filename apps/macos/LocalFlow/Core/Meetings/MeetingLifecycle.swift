import Foundation

/// Persisted meeting states. `completed`, `interrupted` and `failed` are terminal.
enum MeetingState: String, CaseIterable, Sendable, Codable {
  case created, preparing, recording, paused, finalizing, completed, interrupted, failed

  /// A row in one of these states blocks a new start and is reconciled at launch.
  var isActive: Bool {
    switch self {
    case .created, .preparing, .recording, .paused, .finalizing: true
    case .completed, .interrupted, .failed: false
    }
  }
  var isTerminal: Bool { !isActive }

  var badgeText: String {
    switch self {
    case .created: "Created"
    case .preparing: "Preparing"
    case .recording: "Recording"
    case .paused: "Paused"
    case .finalizing: "Finalizing"
    case .completed: "Completed"
    case .interrupted: "Interrupted"
    case .failed: "Failed"
    }
  }
}

/// Pure transition table from `data-model.md`. Every pair not listed is rejected
/// and mutates nothing; the store applies the check inside its write transaction.
enum MeetingLifecycle {
  enum Error: Swift.Error, Equatable, Sendable {
    case invalidTransition(from: MeetingState, to: MeetingState)
  }

  private static let table: [MeetingState: Set<MeetingState>] = [
    .created: [.preparing, .failed],
    .preparing: [.recording, .failed, .interrupted],
    .recording: [.paused, .finalizing, .interrupted, .failed],
    .paused: [.recording, .finalizing, .interrupted, .failed],
    .finalizing: [.completed, .interrupted, .failed],
    .completed: [],
    .interrupted: [],
    .failed: [],
  ]

  static func isAllowed(from: MeetingState, to: MeetingState) -> Bool {
    table[from]?.contains(to) ?? false
  }

  @discardableResult
  static func transition(from: MeetingState, to: MeetingState) throws -> MeetingState {
    guard isAllowed(from: from, to: to) else { throw Error.invalidTransition(from: from, to: to) }
    return to
  }
}

/// Shared reason set for meetings, tracks and segments. Raw values are the
/// persisted column values; user-facing text lives in `MeetingErrorMessage`.
enum MeetingFailureReason: String, CaseIterable, Sendable, Codable {
  case notRunningAtLastState = "not_running_at_last_state"
  case storageWriteFailed = "storage_write_failed"
  case storageUnavailable = "storage_unavailable"
  case encoderFailed = "encoder_failed"
  case permissionRevoked = "permission_revoked"
  case deviceLost = "device_lost"
  case streamStopped = "stream_stopped"
  case bothSourcesFailed = "both_sources_failed"
  case recordMissing = "record_missing"
  case fileMissing = "file_missing"
  case segmentOpenFailed = "segment_open_failed"
  case unrecoverableMedia = "unrecoverable_media"
}

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
