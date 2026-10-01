import Foundation

/// Feature 018 (research R4): the failures the meeting runtimes throw, beside them so the
/// app and the `flowd-speech` worker share one copy.

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

public enum IdentificationFailureCategory: String, CaseIterable, Sendable, Codable, Error {
  case modelUnavailable = "model_unavailable"
  case osUnsupported = "os_unsupported"
  case modelLoadFailure = "model_load_failure"
  case audioMissing = "audio_missing"
  case audioDecodeFailure = "audio_decode_failure"
  case runtimeFailure = "runtime_failure"
  case diarizationChanged = "diarization_changed"
  case persistenceFailure = "persistence_failure"
  case persistenceCapacity = "persistence_capacity"
  case interrupted
}

/// The Dictionary's per-term byte limit (`VocabularyEntry.maximumTermBytes`), which the
/// Whisper runtime also applies to its prompt terms.
public enum VocabularyLimits {
  public static let maximumTermBytes = 256
}
