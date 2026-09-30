import Foundation

/// Persisted meeting states. `completed`, `interrupted` and `failed` are terminal.
public enum MeetingState: String, CaseIterable, Sendable, Codable {
  case created, preparing, recording, paused, finalizing, completed, interrupted, failed

  /// A row in one of these states blocks a new start and is reconciled at launch.
  public var isActive: Bool {
    switch self {
    case .created, .preparing, .recording, .paused, .finalizing: true
    case .completed, .interrupted, .failed: false
    }
  }
  public var isTerminal: Bool { !isActive }

  public var badgeText: String {
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

/// Shared reason set for meetings, tracks and segments. Raw values are the
/// persisted column values; user-facing text lives in `MeetingErrorMessage`.
public enum MeetingFailureReason: String, CaseIterable, Sendable, Codable {
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
