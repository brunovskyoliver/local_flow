import Foundation

public struct TranscriptionEntry: Identifiable, Sendable, Equatable {
  public enum DeliveryState: String, Sendable, Codable {
    case notAttempted = "not_attempted"
    case attempting
    case confirmed
    case notInserted = "not_inserted"
    case uncertain
  }

  public enum RecoveryState: String, Sendable, Codable {
    case needsReview = "needs_review"
    case resolved
  }

  public enum Quality: String, Sendable, Codable {
    case complete
    case durationLimited = "duration_limited"
    case incomplete
  }

  public enum StopReason: String, Sendable, Codable {
    case keyRelease = "key_release"
    case durationLimit = "duration_limit"
    case cancel
    case overflow
    case deviceLoss = "device_loss"
    case permissionRevoked = "permission_revoked"
    case sleep
    case failure
  }

  public let id: UUID
  public let text: String
  public let createdAtMilliseconds: Int64
  public let deliveryState: DeliveryState
  public let recoveryState: RecoveryState
  public let quality: Quality
  public let stopReason: StopReason
  public let targetBundleID: String?
  public let attemptID: UUID?
  public let attemptStartedAtMilliseconds: Int64?
  public let revision: Int64

  public init(
    id: UUID,
    text: String,
    createdAtMilliseconds: Int64,
    deliveryState: DeliveryState = .notAttempted,
    recoveryState: RecoveryState = .needsReview,
    quality: Quality,
    stopReason: StopReason,
    targetBundleID: String? = nil,
    attemptID: UUID? = nil,
    attemptStartedAtMilliseconds: Int64? = nil,
    revision: Int64 = 0
  ) throws {
    let bytes = text.data(using: .utf8)?.count ?? Int.max
    guard !text.isEmpty, bytes <= TranscriptionStore.maximumTextBytes else {
      throw TranscriptionStore.Error.invalidText
    }
    if let targetBundleID, (targetBundleID.data(using: .utf8)?.count ?? Int.max) > 255 {
      throw TranscriptionStore.Error.invalidTargetBundleID
    }
    guard revision >= 0 else { throw TranscriptionStore.Error.invalidRevision }
    self.id = id
    self.text = text
    self.createdAtMilliseconds = createdAtMilliseconds
    self.deliveryState = deliveryState
    self.recoveryState = recoveryState
    self.quality = quality
    self.stopReason = stopReason
    self.targetBundleID = targetBundleID
    self.attemptID = attemptID
    self.attemptStartedAtMilliseconds = attemptStartedAtMilliseconds
    self.revision = revision
  }
}
