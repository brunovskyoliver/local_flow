import Foundation

/// Every bound of the analysis pipeline in one place (`tasks.md` "Provisional
/// values"). Values are provisional until `acceptance/` records the reference
/// runs; the struct feeds the `policy_v1` version string and the run row's
/// `request_config_json`.
public struct AnalysisPolicy: Sendable, Equatable {
  public static let version = "policy_v1"
  public static let chunkingVersion = "chunking_v2"
  public static let overlayMatchVersion = "overlay_match_v1"
  public static let pipelineVersion = "\(chunkingVersion)/\(overlayMatchVersion)/\(version)"

  /// Segment-text bytes at or under which one `full` request suffices. With
  /// the request envelope Slovak runs ≈ 1.2 B/token (measured 2026-09-22 on
  /// Qwen3.5 4B): 12 KB is ~12k prompt tokens, leaving room for the larger
  /// full-request output inside the backend's real KV pool, which runs well
  /// under the advertised context when the Mac is memory-pressured.
  public var fullBudgetBytes = 12_288
  /// Segment-text bytes per `chunk` request: ~15k prompt tokens at most, plus
  /// the 3,072-token chunk output cap. The planner balances chunks, so most
  /// land well under it.
  public var chunkBudgetBytes = 16_384
  public var maxChunks = 64
  public var partialsPerSynthesis = 16
  public var reduceDepth = 2
  public var requestsInFlight = 1
  public var requestsInFlightMax = 2

  /// Matches the server's `--analysis-timeout`: a ~10k-token chunk needs ~10 s of
  /// prefill and ~20 s of generation on a 4B model here, several times that when
  /// the Mac is also transcribing.
  public var perRequestTimeout: Duration = Duration.seconds(300)
  public var firstTokenTimeout: Duration = Duration.seconds(60)
  /// 60 s + one request timeout per request, clamped to [120 s, 30 min] (research R11).
  public func runDeadline(requestCount: Int) -> Duration {
    let seconds = 60 + Int(perRequestTimeout.components.seconds) * max(1, requestCount)
    let clamped = min(max(seconds, 120), 1_800)
    return .seconds(clamped)
  }

  public var serverQueueWait: Duration = Duration.seconds(30)
  public var preemptionRetries = 3

  public var sourcesPerItem = 10
  public var topicCap = 20
  public var decisionCap = 40
  public var actionItemCap = 60
  public var nextStepCap = 40
  public var openQuestionCap = 40
  public var riskCap = 40
  /// Partial (chunk) results use half of each section cap.
  public func cap(for kind: AnalysisSection, partial: Bool) -> Int {
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

  public var runRowsPerMeeting = 20
  public var overlaysPerMeeting = 500
  public var queueCapacity = 100
  public var evidencePageSize = 200
  public var languageSampleBytes: Int = 32 * 1_024
  public var maxNoteParagraphs = 256
  public var maxNoteParagraphBytes = 8_192
  /// Context estimate: 3 bytes per token against the advertised context.
  public var bytesPerToken = 3
  public var contextTokens = 32_768
  public var maxRequestConfigBytes = 2_048
  public var maxSourcesPerSummary = 10

  /// R9: participants with these certainties may be named in requests and as
  /// owners. Part of the evidence version.
  public var permittedCertainties: Set<ParticipantCertainty> {
    [.confirmed, .recognized, .localName, .localUser]
  }

  /// FR-020: terms that never resolve to a date (English and Slovak).
  public static let vagueTerms: [String] = [
    "soon", "later", "eventually", "at some point", "next time",
    "čoskoro", "neskôr", "niekedy", "nabudúce", "časom",
  ]

  /// R5/R6: English and Slovak function words plus weekday and month names.
  /// Compared folded (lowercase, diacritics stripped); neither the
  /// proper-noun class nor lexical support counts them.
  public static let stopWords: Set<String> = [
    // English function words.
    "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
    "by", "from", "is", "are", "was", "were", "be", "been", "being", "it",
    "its", "this", "that", "these", "those", "we", "you", "they", "he", "she",
    "i", "will", "would", "can", "could", "should", "shall", "must", "may",
    "might", "do", "does", "did", "done", "have", "has", "had", "not", "no",
    "so", "if", "then", "than", "as", "about", "before", "after", "when",
    "what", "who", "how", "why", "which", "all", "any", "each", "every",
    "some", "more", "most", "other", "another", "new", "one", "two", "out",
    "up", "down", "over", "under", "again", "also", "just", "only", "very",
    "there", "here", "now", "us", "our", "ours", "your", "yours", "their",
    "theirs", "his", "her", "hers", "my", "mine", "me", "him", "them", "the",
    "into", "onto", "per", "via", "off", "too", "such", "same", "own", "both",
    "few", "many", "much", "between", "during", "until", "while", "because",
    "through", "against", "without", "within", "next", "last", "still",
    "already", "yet", "back", "well", "even", "really", "let", "lets",
    "make", "makes", "made", "get", "gets", "got", "go", "goes", "going",
    "went", "gone", "say", "says", "said", "see", "seen", "know", "think",
    "take", "took", "need", "needs", "want", "wants", "sure", "yes", "yeah",
    "okay", "ok", "please", "thanks", "ill", "im", "ive", "dont", "wont",
    // Slovak function words.
    "a", "ale", "aj", "aby", "ak", "že", "som", "si", "je", "sme", "ste",
    "sú", "bol", "bola", "bolo", "boli", "byť", "bude", "budem", "budeš",
    "budeme", "budú", "na", "v", "vo", "do", "za", "po", "pod", "nad",
    "pri", "pre", "od", "z", "zo", "so", "s", "k", "ku", "o", "u", "ten",
    "to", "tá", "tí", "tie", "tento", "toto", "táto", "ono", "on", "ona",
    "oni", "ony", "my", "vy", "ja", "ty", "náš", "naša", "naše", "váš",
    "vaša", "vaše", "ich", "jeho", "jej", "nie", "no", "niečo", "nič",
    "všetko", "všetci", "ako", "tak", "takže", "už", "ešte", "len", "veľmi",
    "tu", "tam", "kde", "kedy", "čo", "kto", "prečo", "lebo", "pretože",
    "keď", "potom", "teraz", "dnes", "včera", "mal", "mala", "malo", "mali",
    "má", "mám", "máš", "máme", "máte", "majú", "môže", "môžem", "môžeme",
    "musí", "musím", "musíme", "treba", "chce", "chcem", "chceme", "mne",
    "mi", "ma", "mu", "ho", "nám", "vám", "im", "nej", "nich", "sa", "sa",
    "či", "teda", "tiež", "prosím", "ďakujem",
    // English weekday and month names.
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    "sunday", "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december",
    // Slovak weekday and month names.
    "pondelok", "utorok", "streda", "štvrtok", "piatok", "sobota", "nedeľa",
    "január", "januára", "február", "februára", "marec", "marca", "apríl",
    "apríla", "máj", "mája", "jún", "júna", "júl", "júla", "august",
    "augusta", "september", "septembra", "október", "októbra", "november",
    "novembra", "december", "decembra",
  ]

  /// The policy values recorded on the run row (≤ `maxRequestConfigBytes`).
  public func requestConfigJSON() -> String {
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
    ]
    let body = pairs.map { "\"\($0)\":\($1)" }.joined(separator: ",")
    return
      "{\"policy\":\"\(Self.version)\",\"chunking\":\"\(Self.chunkingVersion)\",\"overlay\":\"\(Self.overlayMatchVersion)\",\(body)}"
  }

  /// The health `limits`/`caps` minima: the client lowers its budget to the
  /// smaller advertised value and never raises a cap (protocol contract).
  public func lowered(by health: AnalysisHealth) -> AnalysisPolicy {
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

  public init(
    fullBudgetBytes: Int = 12_288, chunkBudgetBytes: Int = 16_384, maxChunks: Int = 64,
    partialsPerSynthesis: Int = 16, reduceDepth: Int = 2, requestsInFlight: Int = 1,
    requestsInFlightMax: Int = 2, perRequestTimeout: Duration = Duration.seconds(300),
    firstTokenTimeout: Duration = Duration.seconds(60),
    serverQueueWait: Duration = Duration.seconds(30), preemptionRetries: Int = 3,
    sourcesPerItem: Int = 10, topicCap: Int = 20, decisionCap: Int = 40, actionItemCap: Int = 60,
    nextStepCap: Int = 40, openQuestionCap: Int = 40, riskCap: Int = 40,
    runRowsPerMeeting: Int = 20, overlaysPerMeeting: Int = 500, queueCapacity: Int = 100,
    evidencePageSize: Int = 200, languageSampleBytes: Int = 32 * 1_024,
    maxNoteParagraphs: Int = 256, maxNoteParagraphBytes: Int = 8_192, bytesPerToken: Int = 3,
    contextTokens: Int = 32_768, maxRequestConfigBytes: Int = 2_048, maxSourcesPerSummary: Int = 10
  ) {
    self.fullBudgetBytes = fullBudgetBytes
    self.chunkBudgetBytes = chunkBudgetBytes
    self.maxChunks = maxChunks
    self.partialsPerSynthesis = partialsPerSynthesis
    self.reduceDepth = reduceDepth
    self.requestsInFlight = requestsInFlight
    self.requestsInFlightMax = requestsInFlightMax
    self.perRequestTimeout = perRequestTimeout
    self.firstTokenTimeout = firstTokenTimeout
    self.serverQueueWait = serverQueueWait
    self.preemptionRetries = preemptionRetries
    self.sourcesPerItem = sourcesPerItem
    self.topicCap = topicCap
    self.decisionCap = decisionCap
    self.actionItemCap = actionItemCap
    self.nextStepCap = nextStepCap
    self.openQuestionCap = openQuestionCap
    self.riskCap = riskCap
    self.runRowsPerMeeting = runRowsPerMeeting
    self.overlaysPerMeeting = overlaysPerMeeting
    self.queueCapacity = queueCapacity
    self.evidencePageSize = evidencePageSize
    self.languageSampleBytes = languageSampleBytes
    self.maxNoteParagraphs = maxNoteParagraphs
    self.maxNoteParagraphBytes = maxNoteParagraphBytes
    self.bytesPerToken = bytesPerToken
    self.contextTokens = contextTokens
    self.maxRequestConfigBytes = maxRequestConfigBytes
    self.maxSourcesPerSummary = maxSourcesPerSummary
  }
}

public enum AnalysisSection: String, Sendable, Equatable, CaseIterable {
  case topics, decisions
  case actionItems = "action_items"
  case nextSteps = "next_steps"
  case openQuestions = "open_questions"
  case risks
}
