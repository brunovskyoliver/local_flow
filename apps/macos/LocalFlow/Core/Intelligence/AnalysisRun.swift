import Foundation

/// One generation attempt for one meeting (data-model.md `analysis_runs`).
/// Content-free: the row never holds summary or item text.
enum AnalysisRunState: String, Sendable, Equatable, CaseIterable {
  case pending, running, succeeded, failed, cancelled
  case timedOut = "timed_out"
  case interrupted, superseded

  var isTerminal: Bool {
    switch self {
    case .pending, .running: return false
    case .succeeded, .failed, .cancelled, .timedOut, .interrupted, .superseded: return true
    }
  }

  /// data-model.md transition table.
  func canTransition(to next: AnalysisRunState) -> Bool {
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

enum AnalysisTrigger: String, Sendable, Equatable, CaseIterable {
  case automatic, manual, retry, regenerate, restart
}

/// The persisted failure categories (data-model.md). `failure_detail` carries a
/// content-free code (e.g. `evidence_changed`), never text.
enum AnalysisFailureCategory: String, Sendable, Equatable, CaseIterable {
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
  static func forServerCode(_ code: String) -> AnalysisFailureCategory {
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
  static func forHTTPStatus(_ status: Int, code: String?) -> AnalysisFailureCategory {
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

/// The error type every intelligence boundary throws. `detail` is a bounded,
/// content-free code (≤ 512 bytes), never transcript, note or model text.
struct AnalysisFailure: Error, Equatable, Sendable {
  let category: AnalysisFailureCategory
  let detail: String?
  init(_ category: AnalysisFailureCategory, detail: String? = nil) {
    self.category = category
    self.detail = detail
  }
}

/// The reproducibility identity stored on every run (FR-004).
struct RunIdentity: Sendable, Equatable {
  var serverVersion: String
  var protocolVersion = 1
  var schemaVersion = 1
  var backendKind: String
  var backendModel: String
  /// `chunk=…,synthesis=…,full=…` form.
  var promptVersions: String
  /// `chunking_v1/overlay_match_v1/policy_v1` form.
  var pipelineVersion: String
}

/// One `analysis_runs` row.
struct AnalysisRun: Sendable, Equatable, Identifiable {
  let id: UUID
  let meetingID: UUID
  var state: AnalysisRunState
  let trigger: AnalysisTrigger
  var evidenceVersion: String
  var transcriptPassID: UUID? = nil
  var serverVersion: String? = nil
  var protocolVersion = 1
  var schemaVersion = 1
  var backendKind: String? = nil
  var backendModel: String? = nil
  var promptVersions: String? = nil
  var pipelineVersion: String? = nil
  var languagePolicy: AnalysisLanguage? = nil
  var requestConfigJSON: String? = nil
  let createdAt: Int64
  var startedAt: Int64? = nil
  var completedAt: Int64? = nil
  var failureCategory: AnalysisFailureCategory? = nil
  var failureDetail: String? = nil
  var chunkCount = 0
  var requestCount = 0
  var retryCount = 0
  var preemptionCount = 0
  var inputBytes = 0
  var outputBytes = 0
  var itemCount = 0
  var droppedLiteralCount = 0
  var droppedUnsupportedCount = 0
  var identityDowngradeCount = 0
  var unresolvedOwnerCount = 0
  var durationMs = 0
}
