import Foundation

/// `tiers_v1` (research R6, FR-012): the calibrated values for one model identity.
/// Provisional until `acceptance/calibration.md` records the corpus run (T014). No UI
/// code reads these; they reach the user only as Recognized, Possible match or Unknown.
struct IdentificationThresholds: Sendable, Equatable {
  static let policy = "tiers_v1"
  /// The engine string of the model these values were calibrated for.
  static let wespeakerEngine = "wespeaker_resnet34lm_256"

  let high: Float
  let medium: Float
  let margin: Float
  let minSupport: Int
  let minQuerySpeechMs: Int64
  /// `tiers_v1@<engine>/<revision8>`, stored with every automatic assignment (FR-019).
  let policyVersion: String

  /// Provisional WeSpeaker values: τ_high 0.72, τ_medium 0.55, δ 0.10, support 2, 6 s.
  static func current(for identity: VoiceModelIdentity) -> IdentificationThresholds? {
    guard identity.engine == wespeakerEngine, identity.dimension == VoiceEmbedding.dimension
    else { return nil }
    return IdentificationThresholds(
      high: 0.72, medium: 0.55, margin: 0.10, minSupport: 2, minQuerySpeechMs: 6_000,
      policyVersion: policyVersion(for: identity))
  }

  static func policyVersion(for identity: VoiceModelIdentity) -> String {
    "\(policy)@\(identity.engine)/\(identity.revisionPrefix)"
  }
}
