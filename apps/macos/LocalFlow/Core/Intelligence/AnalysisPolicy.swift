import Foundation

/// Every bound of the analysis pipeline in one place (`tasks.md` "Provisional
/// values"). Values are provisional until `acceptance/` records the reference
/// runs; the struct feeds the `policy_v1` version string and the run row's
/// `request_config_json`.
struct AnalysisPolicy: Sendable, Equatable {
  static let version = "policy_v1"
  static let chunkingVersion = "chunking_v1"
  static let overlayMatchVersion = "overlay_match_v1"
  static let pipelineVersion = "\(chunkingVersion)/\(overlayMatchVersion)/\(version)"

  /// Segment-text bytes at or under which one `full` request suffices.
  var fullBudgetBytes = 24_576
  /// Segment-text bytes per `chunk` request.
  var chunkBudgetBytes = 24_576
  var maxChunks = 64
  var partialsPerSynthesis = 16
  var reduceDepth = 2
  var requestsInFlight = 1
  var requestsInFlightMax = 2

  var perRequestTimeout = Duration.seconds(120)
  var firstTokenTimeout = Duration.seconds(15)
  /// 60 s + 90 s per request, clamped to [120 s, 30 min] (research R11).
  func runDeadline(requestCount: Int) -> Duration {
    let seconds = 60 + 90 * max(1, requestCount)
    let clamped = min(max(seconds, 120), 1_800)
    return .seconds(clamped)
  }

  var serverQueueWait = Duration.seconds(30)
  var preemptionRetries = 3
  /// A run fails `unsupported_content` when more than this share of returned
  /// items is dropped (FR-024a).
  var maxDroppedShareNumerator = 1
  var maxDroppedShareDenominator = 3

  var sourcesPerItem = 10
  var topicCap = 20
  var decisionCap = 40
  var actionItemCap = 60
  var nextStepCap = 40
  var openQuestionCap = 40
  var riskCap = 40
  /// Partial (chunk) results use half of each section cap.
  func cap(for kind: AnalysisSection, partial: Bool) -> Int {
    let full: Int
    switch kind {
    case .topics: full = topicCap
    case .decisions: full = decisionCap
    case .actionItems: full = actionItemCap
    case .nextSteps: full = nextStepCap
    case .openQuestions: full = openQuestionCap
    case .risks: full = riskCap
    }
    return partial ? full / 2 : full
  }

  var runRowsPerMeeting = 20
  var overlaysPerMeeting = 500
  var queueCapacity = 100
  var evidencePageSize = 200
  var languageSampleBytes = 32 * 1_024
  var maxNoteParagraphs = 256
  var maxNoteParagraphBytes = 8_192
  /// Context estimate: 3 bytes per token against the advertised context.
  var bytesPerToken = 3
  var contextTokens = 32_768
  var maxRequestConfigBytes = 2_048
  var maxSourcesPerSummary = 10

  /// R9: participants with these certainties may be named in requests and as
  /// owners. Part of the evidence version.
  var permittedCertainties: Set<ParticipantCertainty> {
    [.confirmed, .recognized, .localName, .localUser]
  }

  /// FR-020: terms that never resolve to a date (English and Slovak).
  static let vagueTerms: [String] = [
    "soon", "later", "eventually", "at some point", "next time",
    "čoskoro", "neskôr", "niekedy", "nabudúce", "časom",
  ]

  /// The policy values recorded on the run row (≤ `maxRequestConfigBytes`).
  func requestConfigJSON() -> String {
    let pairs = [
      ("full_budget_bytes", fullBudgetBytes), ("chunk_budget_bytes", chunkBudgetBytes),
      ("max_chunks", maxChunks), ("partials_per_synthesis", partialsPerSynthesis),
      ("reduce_depth", reduceDepth), ("requests_in_flight", requestsInFlight),
      ("preemption_retries", preemptionRetries), ("sources_per_item", sourcesPerItem),
      ("topic_cap", topicCap), ("decision_cap", decisionCap),
      ("action_item_cap", actionItemCap), ("next_step_cap", nextStepCap),
      ("open_question_cap", openQuestionCap), ("risk_cap", riskCap),
      ("evidence_page", evidencePageSize), ("language_sample_bytes", languageSampleBytes),
      ("bytes_per_token", bytesPerToken), ("context_tokens", contextTokens),
      ("dropped_share_num", maxDroppedShareNumerator),
      ("dropped_share_den", maxDroppedShareDenominator),
    ]
    let body = pairs.map { "\"\($0)\":\($1)" }.joined(separator: ",")
    return
      "{\"policy\":\"\(Self.version)\",\"chunking\":\"\(Self.chunkingVersion)\",\"overlay\":\"\(Self.overlayMatchVersion)\",\(body)}"
  }

  /// The health `limits`/`caps` minima: the client lowers its budget to the
  /// smaller advertised value and never raises a cap (protocol contract).
  func lowered(by health: AnalysisHealth) -> AnalysisPolicy {
    var copy = self
    if let input = health.limits?.inputBytes {
      copy.chunkBudgetBytes = min(copy.chunkBudgetBytes, input)
      copy.fullBudgetBytes = min(copy.fullBudgetBytes, input)
    }
    if let context = health.limits?.contextTokens {
      copy.contextTokens = min(copy.contextTokens, context)
    }
    if let caps = health.caps {
      copy.sourcesPerItem = min(copy.sourcesPerItem, caps.sourcesPerItem)
      copy.topicCap = min(copy.topicCap, caps.topics)
      copy.decisionCap = min(copy.decisionCap, caps.decisions)
      copy.actionItemCap = min(copy.actionItemCap, caps.actionItems)
      copy.nextStepCap = min(copy.nextStepCap, caps.nextSteps)
      copy.openQuestionCap = min(copy.openQuestionCap, caps.openQuestions)
      copy.riskCap = min(copy.riskCap, caps.risks)
    }
    return copy
  }
}

enum AnalysisSection: String, Sendable, Equatable, CaseIterable {
  case topics, decisions
  case actionItems = "action_items"
  case nextSteps = "next_steps"
  case openQuestions = "open_questions"
  case risks
}
