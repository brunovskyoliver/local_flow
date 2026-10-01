import Foundation
import LocalFlowCore
import LocalFlowSpeech

enum IdentificationRunState: String, CaseIterable, Sendable, Codable {
  case pending, running, succeeded, failed, interrupted, superseded
}

/// Derived, never stored (data-model.md "meeting_identification").
enum MeetingIdentificationState: String, CaseIterable, Sendable {
  case notRequested = "not_requested"
  case pending, running, succeeded, failed, interrupted
}

enum CandidateReason: String, CaseIterable, Sendable, Codable {
  case belowMedium = "below_medium"
  case margin, support
  case minSpeech = "min_speech"
  case rejected, disabled
}

/// R1: the model identity stored with every sample and run. Compatibility (FR-028) is
/// equality on engine, model id, revision and dimension; the manifest hash is audit only.
struct VoiceModelIdentity: Sendable, Equatable, Hashable {
  let engine: String
  let modelID: String
  let modelRevision: String
  /// 64 lowercase hex characters.
  let manifestHash: String
  let dimension: Int

  func isCompatible(with other: VoiceModelIdentity) -> Bool {
    engine == other.engine && modelID == other.modelID && modelRevision == other.modelRevision
      && dimension == other.dimension
  }

  var isValid: Bool {
    !engine.isEmpty && !modelID.isEmpty && !modelRevision.isEmpty
      && manifestHash.utf8.count == 64
      && manifestHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      && (1...4_096).contains(dimension)
  }

  /// The first eight characters of the revision, for policy versions.
  var revisionPrefix: String { String(modelRevision.prefix(8)) }
}

enum IdentificationRunLifecycle {
  struct InvalidTransition: Error, Equatable {
    let from: IdentificationRunState
    let to: IdentificationRunState
  }

  /// data-model.md "Run state transitions". Cancel and meeting deletion remove the row.
  static let allowed: Set<String> = [
    "pending>running", "running>succeeded", "running>failed", "pending>failed",
    "pending>succeeded", "running>pending", "running>interrupted", "succeeded>superseded",
  ]

  static func transition(from: IdentificationRunState, to: IdentificationRunState) throws {
    guard allowed.contains("\(from.rawValue)>\(to.rawValue)") else {
      throw InvalidTransition(from: from, to: to)
    }
  }

  /// Same rule as `DiarizationRunLifecycle.meetingState`.
  static func meetingState(
    current: IdentificationRunState?, latest: IdentificationRunState?, hasAccepted: Bool
  ) -> MeetingIdentificationState {
    if let current, let state = MeetingIdentificationState(rawValue: current.rawValue),
      current == .pending || current == .running
    {
      return state
    }
    if latest == .failed { return .failed }
    if latest == .interrupted { return .interrupted }
    return hasAccepted ? .succeeded : .notRequested
  }
}

/// The pipeline version stored with every sample and run: the embedding reduction plus
/// the region selector version, e.g. `embed_offline1spk_dw_v1+regions_v1`.
enum IdentificationPipelineVersion {
  static let embedding = "embed_offline1spk_dw_v1"
  static let maxBytes = 256

  static var current: String {
    let value = [embedding, VoiceRegionSelector.version].joined(separator: "+")
    precondition(value.utf8.count <= maxBytes)
    return value
  }
}

struct IdentificationRun: Sendable, Equatable {
  let id: UUID
  let meetingID: UUID
  let diarizationRunID: UUID
  var state: IdentificationRunState
  let trigger: IdentificationTrigger
  let identity: VoiceModelIdentity
  let pipelineVersion: String
  let thresholdPolicy: String
  let createdAt: Int64
  var startedAt: Int64?
  var completedAt: Int64?
  var failureCategory: IdentificationFailureCategory?
  var failureDetail: String?
  var clusterCount = 0
  var candidateCount = 0
  var regionCount = 0
  var rejectedRegionCount = 0
  var comparisonCount = 0
  var recognizedCount = 0
  var suggestedCount = 0
  var unknownCount = 0
  var preservedManualCount = 0
  var preemptionCount = 0
}

struct MeetingIdentification: Sendable, Equatable {
  let meetingID: UUID
  var acceptedRunID: UUID?
  var currentRunID: UUID?
  var updatedAt: Int64
}

extension FluidAudioVoiceEmbedderFactory {
  /// The identity stored with every sample and run this embedder produces.
  static func identity(descriptor: ModelDescriptor?, manifestHash: String) -> VoiceModelIdentity {
    VoiceModelIdentity(
      engine: engine, modelID: descriptor?.modelID ?? FluidAudioDiarizerFactory.modelID,
      modelRevision: descriptor?.sourceRevision ?? FluidAudioDiarizerFactory.revision,
      manifestHash: manifestHash, dimension: VoiceEmbedding.dimension)
  }
}
