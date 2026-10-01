import Foundation

public enum IdentificationTrigger: String, CaseIterable, Sendable, Codable {
  case automatic, manual, retry
  case pastSearch = "past_search"
  case sampleChange = "sample_change"
}

/// FR-009: exactly one per remote display root.
public enum IdentityState: String, CaseIterable, Sendable, Codable {
  case recognized, possible, confirmed
  case rejectedUnknown = "rejected_unknown"
  case unknown
}

/// FR-018.
public enum IdentityOrigin: String, CaseIterable, Sendable, Codable {
  case automaticMatch = "automatic_match"
  case userConfirmation = "user_confirmation"
  case manualProfileSelection = "manual_profile_selection"
  case newProfileCreated = "new_profile_created"
  case manualCorrection = "manual_correction"
  case keptUnknown = "kept_unknown"

  /// Rows adoption never replaces (FR-024).
  public var isManual: Bool { self != .automaticMatch }
}

/// The explicit action that created a sample (FR-001, FR-008).
public enum SampleConsent: String, CaseIterable, Sendable, Codable {
  case remember
  case alsoRemember = "also_remember"
  case localEnroll = "local_enroll"
}

public enum CandidateTier: String, CaseIterable, Sendable, Codable {
  case recognized, possible, below
  case localEvidence = "local_evidence"
}
