import Foundation
import LocalFlowCore

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
