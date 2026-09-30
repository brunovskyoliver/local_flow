import Foundation

/// One generation attempt for one meeting (data-model.md `analysis_runs`).
/// Content-free: the row never holds summary or item text.
public enum AnalysisRunState: String, Sendable, Equatable, CaseIterable {
  case pending, running, succeeded, failed, cancelled
  case timedOut = "timed_out"
  case interrupted, superseded

  public var isTerminal: Bool {
    switch self {
    case .pending, .running: return false
    case .succeeded, .failed, .cancelled, .timedOut, .interrupted, .superseded: return true
    }
  }

  /// data-model.md transition table.
  public func canTransition(to next: AnalysisRunState) -> Bool {
    switch (self, next) {
    case (.pending, .running), (.pending, .cancelled), (.pending, .interrupted),
      (.running, .succeeded), (.running, .failed), (.running, .timedOut),
      (.running, .cancelled), (.running, .interrupted), (.running, .superseded),
      (.succeeded, .superseded):
      return true
    default: return false
    }
  }
}

public enum AnalysisTrigger: String, Sendable, Equatable, CaseIterable {
  case automatic, manual, retry, regenerate, restart
}

/// The persisted failure categories (data-model.md). `failure_detail` carries a
/// content-free code (e.g. `evidence_changed`), never text.
public enum AnalysisFailureCategory: String, Sendable, Equatable, CaseIterable {
  case notEligible = "not_eligible"
  case serverUnreachable = "server_unreachable"
  case authenticationFailed = "authentication_failed"
  case serverUnavailable = "server_unavailable"
  case backendUnavailable = "backend_unavailable"
  case backendBusy = "backend_busy"
  case backendTimeout = "backend_timeout"
  case unsupportedVersion = "unsupported_version"
  case malformedResponse = "malformed_response"
  case oversizedResponse = "oversized_response"
  case meetingMismatch = "meeting_mismatch"
  case sourceValidation = "source_validation"
  case protectedLiteral = "protected_literal"
  case unsupportedContent = "unsupported_content"
  case overCap = "over_cap"
  case tooLong = "too_long"
  case timeout
  case persistenceFailure = "persistence_failure"
  case persistenceCapacity = "persistence_capacity"
  case interrupted

  /// Server `error` event codes and pre-stream HTTP statuses (protocol contract).
  public static func forServerCode(_ code: String) -> AnalysisFailureCategory {
    switch code {
    case "unauthorized": return .authenticationFailed
    case "unsupported_version": return .unsupportedVersion
    case "invalid_request", "output_invalid": return .malformedResponse
    case "too_large": return .tooLong
    case "output_too_large": return .oversizedResponse
    case "server_busy": return .serverUnavailable
    case "queue_timeout", "preempted": return .backendBusy
    case "backend_unavailable", "backend_error": return .backendUnavailable
    case "backend_timeout", "backend_first_token_timeout": return .backendTimeout
    case "source_validation": return .sourceValidation
    default: return .malformedResponse
    }
  }

  /// Non-200 responses before the stream opens.
  public static func forHTTPStatus(_ status: Int, code: String?) -> AnalysisFailureCategory {
    if let code { return forServerCode(code) }
    switch status {
    case 401, 403: return .authenticationFailed
    case 404: return .serverUnavailable
    case 413: return .tooLong
    case 429: return .serverUnavailable
    case 503: return .backendUnavailable
    default: return .serverUnreachable
    }
  }
}

public enum AnalysisLanguage: String, Sendable, Equatable, Codable, CaseIterable {
  case sk, en, mixed
}

public enum AnalysisItemKind: String, Sendable, Equatable, CaseIterable {
  case decision
  case actionItem = "action_item"
  case nextStep = "next_step"
  case openQuestion = "open_question"
  case risk
}

public enum OverlayField: String, Sendable, Equatable, CaseIterable {
  case summaryText = "summary_text"
  case taskText = "task_text"
  case decisionText = "decision_text"
  case nextStepText = "next_step_text"
  case owner
  case dueDate = "due_date"
  case status
}
