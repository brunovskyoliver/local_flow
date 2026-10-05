import Foundation

/// The error type every intelligence boundary throws. `detail` is a bounded,
/// content-free code (≤ 512 bytes), never transcript, note or model text.
public struct AnalysisFailure: Error, Equatable, Sendable {
  public let category: AnalysisFailureCategory
  public let detail: String?
  public init(_ category: AnalysisFailureCategory, detail: String? = nil) {
    self.category = category
    self.detail = detail
  }
}

/// The reproducibility identity stored on every run (FR-004).
public struct RunIdentity: Sendable, Equatable {
  public var serverVersion: String
  public var protocolVersion = 1
  public var schemaVersion = 1
  public var backendKind: String
  public var backendModel: String
  /// `chunk=…,synthesis=…,full=…` form.
  public var promptVersions: String
  /// `chunking_v1/overlay_match_v1/policy_v1` form.
  public var pipelineVersion: String

  public init(
    serverVersion: String, protocolVersion: Int = 1, schemaVersion: Int = 1, backendKind: String,
    backendModel: String, promptVersions: String, pipelineVersion: String
  ) {
    self.serverVersion = serverVersion
    self.protocolVersion = protocolVersion
    self.schemaVersion = schemaVersion
    self.backendKind = backendKind
    self.backendModel = backendModel
    self.promptVersions = promptVersions
    self.pipelineVersion = pipelineVersion
  }
}

/// One `analysis_runs` row.
public struct AnalysisRun: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let meetingID: UUID
  public var state: AnalysisRunState
  public let trigger: AnalysisTrigger
  public var evidenceVersion: String
  public var transcriptPassID: UUID? = nil
  public var serverVersion: String? = nil
  public var protocolVersion = 1
  public var schemaVersion = 1
  public var backendKind: String? = nil
  public var backendModel: String? = nil
  public var promptVersions: String? = nil
  public var pipelineVersion: String? = nil
  public var languagePolicy: AnalysisLanguage? = nil
  public var requestConfigJSON: String? = nil
  public let createdAt: Int64
  public var startedAt: Int64? = nil
  public var completedAt: Int64? = nil
  public var failureCategory: AnalysisFailureCategory? = nil
  public var failureDetail: String? = nil
  public var chunkCount = 0
  public var requestCount = 0
  public var retryCount = 0
  public var preemptionCount = 0
  public var inputBytes = 0
  public var outputBytes = 0
  public var itemCount = 0
  public var droppedLiteralCount = 0
  public var droppedUnsupportedCount = 0
  public var identityDowngradeCount = 0
  public var unresolvedOwnerCount = 0
  public var durationMs = 0

  public init(
    id: UUID, meetingID: UUID, state: AnalysisRunState, trigger: AnalysisTrigger,
    evidenceVersion: String, transcriptPassID: UUID? = nil, serverVersion: String? = nil,
    protocolVersion: Int = 1, schemaVersion: Int = 1, backendKind: String? = nil,
    backendModel: String? = nil, promptVersions: String? = nil, pipelineVersion: String? = nil,
    languagePolicy: AnalysisLanguage? = nil, requestConfigJSON: String? = nil, createdAt: Int64,
    startedAt: Int64? = nil, completedAt: Int64? = nil,
    failureCategory: AnalysisFailureCategory? = nil, failureDetail: String? = nil,
    chunkCount: Int = 0, requestCount: Int = 0, retryCount: Int = 0, preemptionCount: Int = 0,
    inputBytes: Int = 0, outputBytes: Int = 0, itemCount: Int = 0, droppedLiteralCount: Int = 0,
    droppedUnsupportedCount: Int = 0, identityDowngradeCount: Int = 0,
    unresolvedOwnerCount: Int = 0, durationMs: Int = 0
  ) {
    self.id = id
    self.meetingID = meetingID
    self.state = state
    self.trigger = trigger
    self.evidenceVersion = evidenceVersion
    self.transcriptPassID = transcriptPassID
    self.serverVersion = serverVersion
    self.protocolVersion = protocolVersion
    self.schemaVersion = schemaVersion
    self.backendKind = backendKind
    self.backendModel = backendModel
    self.promptVersions = promptVersions
    self.pipelineVersion = pipelineVersion
    self.languagePolicy = languagePolicy
    self.requestConfigJSON = requestConfigJSON
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.failureCategory = failureCategory
    self.failureDetail = failureDetail
    self.chunkCount = chunkCount
    self.requestCount = requestCount
    self.retryCount = retryCount
    self.preemptionCount = preemptionCount
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
    self.itemCount = itemCount
    self.droppedLiteralCount = droppedLiteralCount
    self.droppedUnsupportedCount = droppedUnsupportedCount
    self.identityDowngradeCount = identityDowngradeCount
    self.unresolvedOwnerCount = unresolvedOwnerCount
    self.durationMs = durationMs
  }
}
