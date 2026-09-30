import Foundation

public enum DiarizationFailureCategory: String, CaseIterable, Sendable, Codable, Error {
  case modelUnavailable = "model_unavailable"
  case osUnsupported = "os_unsupported"
  case modelLoadFailure = "model_load_failure"
  case audioMissing = "audio_missing"
  case audioDecodeFailure = "audio_decode_failure"
  case runtimeFailure = "runtime_failure"
  case transcriptChanged = "transcript_changed"
  case persistenceFailure = "persistence_failure"
  case persistenceCapacity = "persistence_capacity"
  case interrupted
}
