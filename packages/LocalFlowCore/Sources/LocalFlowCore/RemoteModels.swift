import Foundation

/// Failure reason codes a dictation records (`server_failure`, FR-019).
public enum RemoteFailureReason: String, Codable, Sendable, CaseIterable, Error {
  case unreachable, timeout, busy, unauthorized
  case notApproved = "not_approved"
  case revoked
  case pinMismatch = "pin_mismatch"
  case workerUnavailable = "worker_unavailable"
  case protocolError = "protocol_error"
  case limitExceeded = "limit_exceeded"
  case pendingRetry = "pending_retry"
}

/// The server's model identity from `dictation_accepted` (and the worker's `ready`).
public struct RemoteModelIdentity: Codable, Sendable, Equatable {
  let engine: String
  let modelID: String
  let modelRevision: String
  let manifestHash: String
  let sdk: String
  /// Absent when the server has no term booster: boosting did not run.
  public let booster: String?
  let workerBuild: String?

  enum CodingKeys: String, CodingKey {
    case engine
    case modelID = "model_id"
    case modelRevision = "model_revision"
    case manifestHash = "manifest_hash"
    case sdk, booster
    case workerBuild = "worker_build"
  }

  public var boostingRan: Bool { booster != nil }
}
