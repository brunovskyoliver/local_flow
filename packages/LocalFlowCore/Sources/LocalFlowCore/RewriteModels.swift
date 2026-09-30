import Foundation

public enum RewriteMode: String, Codable, CaseIterable, Sendable {
  case exact, clean, polished, concise
  public var title: String { rawValue.capitalized }
  /// `exact` never produces a request.
  public var sendsRequest: Bool { self != .exact }
}

/// Every numeric limit of the wire contract in one place.
public enum RewriteBounds {
  public static let schemaVersion = 1
  /// Feature 012: v1 plus a required `context` object (ADR 0023).
  public static let contextSchemaVersion = 2
  public static let maximumInputScalars = 20_000
  public static let maximumInputBytes = 65_536
  public static let maximumLineBytes = 8_192
  public static let maximumErrorBodyBytes = 8_192
  /// `en` and `sk`, each at most once: the only languages LocalFlow supports.
  public static let maximumLanguageHints = 2
  public static let maximumIdentityBytes = 128
  public static let placeholderGlyphs: Set<Character> = ["⟦", "⟧"]

  public static func maximumResultBytes(inputBytes: Int) -> Int {
    min(4 * max(0, inputBytes), maximumInputBytes)
  }
  public static func maximumResponseBytes(inputBytes: Int) -> Int {
    min(4 * max(0, inputBytes) + maximumLineBytes, 73_728)
  }
}

/// One canonical set with two halves (`data-model.md`, "Rewrite attempt"): the
/// twelve codes a `rewrite_attempts` row may carry, and the seven pre-admission
/// refusal reasons that are surfaced in notices and counters but never stored.
public enum RewriteFailureCategory: String, Codable, CaseIterable, Sendable, Hashable {
  case serverUnreachable = "server_unreachable"
  case timeout
  case authenticationFailed = "authentication_failed"
  case transportError = "transport_error"
  case backendUnavailable = "backend_unavailable"
  case malformedResponse = "malformed_response"
  case unsupportedSchemaVersion = "unsupported_schema_version"
  case emptyResponse = "empty_response"
  case oversizedResponse = "oversized_response"
  case serverValidationFailed = "server_validation_failed"
  case requestMismatch = "request_mismatch"
  case interrupted
  /// Feature 012: the result copied on-screen text the speaker did not say.
  case contextCopied = "context_copied"

  case inputTooLarge = "input_too_large"
  case missingCredential = "missing_credential"
  case insecureEndpointBlocked = "insecure_endpoint_blocked"
  case concurrencyLimit = "concurrency_limit"
  case attemptLimit = "attempt_limit"
  case capacityExceeded = "capacity_exceeded"
  case invalidSettings = "invalid_settings"

  static let persisted: [RewriteFailureCategory] = [
    .serverUnreachable, .timeout, .authenticationFailed, .transportError, .backendUnavailable,
    .malformedResponse, .unsupportedSchemaVersion, .emptyResponse, .oversizedResponse,
    .serverValidationFailed, .requestMismatch, .interrupted, .contextCopied,
  ]

  /// True for the post-admission half; the storage check constraint admits exactly these.
  public var isPersistable: Bool { Self.persisted.contains(self) }

  /// Server `error` event codes. A code outside the contract is an unusable reply.
  public static func forServerCode(_ code: String) -> RewriteFailureCategory {
    switch code {
    case "shield_restore_failed", "backend_error", "too_large", "invalid_request":
      return .serverValidationFailed
    case "output_too_large": return .oversizedResponse
    case "backend_timeout", "backend_first_token_timeout", "backend_unavailable", "server_busy":
      return .backendUnavailable
    case "unauthorized": return .authenticationFailed
    case "unsupported_version": return .unsupportedSchemaVersion
    default: return .malformedResponse
    }
  }

  /// Non-200 responses. The request was already admitted, so the result is always
  /// a post-admission category, never a local refusal reason.
  public static func forHTTPStatus(_ status: Int, code: String?) -> RewriteFailureCategory {
    switch status {
    case 400:
      return code == "unsupported_version" ? .unsupportedSchemaVersion : .serverValidationFailed
    case 401, 403: return .authenticationFailed
    case 413: return .serverValidationFailed
    case 429, 503: return .backendUnavailable
    default: return .transportError
    }
  }
}

/// A validated `result`: the only thing the rest of the app may insert or store.
public struct RewriteResult: Sendable, Equatable {
  public let text: String
  let unchanged: Bool
  let serverName: String
  let serverVersion: String
  let backendKind: String
  let backendModel: String
  let promptVersion: Int
  let shieldVersion: Int
  let serverQueueMilliseconds: Int?
  public let backendFirstTokenMilliseconds: Int?
  public let backendMilliseconds: Int?
  /// Feature 012: the server's context rules version; nil for v1.
  var contextPromptVersion: Int? = nil

  public init(
    text: String, unchanged: Bool, serverName: String, serverVersion: String, backendKind: String,
    backendModel: String, promptVersion: Int, shieldVersion: Int, serverQueueMilliseconds: Int?,
    backendFirstTokenMilliseconds: Int?, backendMilliseconds: Int?, contextPromptVersion: Int? = nil
  ) {
    self.text = text
    self.unchanged = unchanged
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.backendKind = backendKind
    self.backendModel = backendModel
    self.promptVersion = promptVersion
    self.shieldVersion = shieldVersion
    self.serverQueueMilliseconds = serverQueueMilliseconds
    self.backendFirstTokenMilliseconds = backendFirstTokenMilliseconds
    self.backendMilliseconds = backendMilliseconds
    self.contextPromptVersion = contextPromptVersion
  }
}

/// The error type every rewrite boundary throws. Carries a category only; never a
/// message, URL or body fragment.
public struct RewriteFailure: Error, Equatable, Sendable {
  public let category: RewriteFailureCategory
  public init(_ category: RewriteFailureCategory) { self.category = category }
}
