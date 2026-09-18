import Foundation

enum TranscriptState: String, CaseIterable, Codable, Sendable {
  case notRequested = "not_requested"
  case pending, live, finalizing, final, failed, interrupted
  var isActive: Bool { self == .pending || self == .live || self == .finalizing }
  var isStable: Bool { !isActive }
}
enum LiveState: String, CaseIterable, Codable, Sendable {
  case live, degraded, suspended, stopped
  case catchingUp = "catching_up"
}
enum TranscriptLifecycle {
  static func transition(from: TranscriptState, to: TranscriptState) throws {
    let allowed: [TranscriptState: Set<TranscriptState>] = [
      .notRequested: [.pending], .pending: [.live, .finalizing, .failed, .interrupted],
      .live: [.finalizing, .failed, .interrupted], .finalizing: [.final, .failed, .interrupted],
      .final: [.finalizing], .failed: [.finalizing], .interrupted: [.finalizing],
    ]
    guard allowed[from, default: []].contains(to) else {
      throw TranscriptStore.Error.invalidTransition(from: from, to: to)
    }
  }
}
enum TranscriptFailureCategory: String, CaseIterable, Codable, Sendable {
  case modelUnavailable = "model_unavailable"
  case modelProvisioning = "model_provisioning"
  case modelLoadFailure = "model_load_failure"
  case audioDecodeFailure = "audio_decode_failure"
  case analysisStreamFailure = "analysis_stream_failure"
  case runtimeFailure = "runtime_failure"
  case finalizationInterrupted = "finalization_interrupted"
  case persistenceFailure = "persistence_failure"
  case persistenceCapacity = "persistence_capacity"
}
extension TranscriptFailureCategory {
  /// Lease acquisition errors: no verified model, a model that failed verification,
  /// or a factory that threw while loading.
  static func acquisition(_ error: Error) -> TranscriptFailureCategory {
    if let failure = error as? DictationFailure, failure == .modelUnavailable {
      return .modelUnavailable
    }
    if let provisioning = error as? ModelProvisioner.Error {
      switch provisioning {
      case .unavailable, .fileMissing: return .modelUnavailable
      default: return .modelProvisioning
      }
    }
    return .modelLoadFailure
  }
}
enum TranscriptErrorMessage {
  static let finalizing = "Meeting transcript is finalizing. Wait for it to finish."
  static let noSourceAudio = "No recorded audio is available to transcribe."
  static let tooManyWaiting = "Too many transcripts waiting"
  static let changed = "The transcript changed. Try again."
  static func message(
    for category: TranscriptFailureCategory, keptCount: Int = 0, resumesAutomatically: Bool = true
  ) -> String {
    switch category {
    case .modelUnavailable:
      "The speech model is not installed. Install it in Settings to transcribe."
    case .modelProvisioning: "The speech model could not be verified. Reinstall it in Settings."
    case .modelLoadFailure: "The speech model failed to load. The recording was not affected."
    case .audioDecodeFailure: "A recorded track could not be decoded. The recording was kept."
    case .analysisStreamFailure:
      "Audio could not be prepared for transcription. The recording was kept."
    case .runtimeFailure:
      "Transcription stopped because the speech model failed. The recording continues."
    case .finalizationInterrupted:
      resumesAutomatically
        ? "Finalization was interrupted. It will resume automatically."
        : "Finalization was interrupted. Choose Retry to finish it."
    case .persistenceFailure: "Transcript could not be saved. The recording continues; retry later."
    case .persistenceCapacity:
      "Transcript storage limit reached (\(keptCount) segments kept). Delete old meetings to free space."
    }
  }
}
