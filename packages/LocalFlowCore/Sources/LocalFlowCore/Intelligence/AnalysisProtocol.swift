import Foundation

/// LocalFlow meeting analysis protocol v1 types and the client-side bounded
/// decoder (`specs/011-meeting-intelligence/contracts/analysis-protocol.md`).
/// Nothing here talks to the network; `AnalysisClient` reads bytes and hands
/// lines to `AnalysisEvent.decode`.
public enum AnalysisBounds {
  public static let schemaVersion = 1
  public static let maxRequestBodyBytes = 262_144
  public static let maxLineBytes = 98_304
  /// Whole response stream. flowd sends a ~110-byte `progress` line every
  /// 250 ms while generating, so a request that runs the full 300 s
  /// per-request timeout carries ~1,200 of them (~132 KB) before its result
  /// line (≤ `maxLineBytes`). 512 KiB leaves more than twice that room.
  public static let maxStreamBytes = 524_288
  public static let maxErrorBodyBytes = 8_192
  public static let maxIdentityBytes = 128
  public static let maxTitleBytes = 256
  public static let maxTimeZoneBytes = 64
  public static let maxParticipantNameBytes = 80
  public static let maxOriginBytes = 32
  public static let maxParticipants = 64
  public static let maxSegments = 4_096
  public static let maxSegmentTextBytes = 4_096
  public static let maxNotes = 256
  public static let maxNoteTextBytes = 8_192
  public static let maxPartials = 16
  public static let maxChunks = 64
  public static let maxSummaryBytes = 4_000
  public static let maxTopicTitleBytes = 200
  public static let maxTopicSummaryBytes = 2_000
  public static let maxTopicBullets = 12
  public static let maxTopicBulletBytes = 500
  public static let maxItemTextBytes = 1_000
  public static let maxOwnerNameBytes = 80
  public static let maxDueOriginalBytes = 80
  public static let maxSourcesPerItem = 10
}

// MARK: - Request

public enum AnalysisStage: String, Sendable, Equatable, Encodable {
  case full, chunk, synthesis
}

/// Body of `POST /v1/analysis/meeting`. The closed `CodingKeys` set is the only
/// thing the encoder can emit; optional keys are absent when nil.
public struct AnalysisRequest: Encodable, Sendable, Equatable {
  public struct Meeting: Encodable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    /// RFC 3339 with offset.
    public let startedAt: String
    public let durationMs: Int64
    public let timeZone: String
    public let languagePolicy: LanguagePolicyValue

    public enum CodingKeys: String, CodingKey {
      case id, title
      case startedAt = "started_at"
      case durationMs = "duration_ms"
      case timeZone = "time_zone"
      case languagePolicy = "language_policy"
    }

    public init(
      id: UUID, title: String, startedAt: String, durationMs: Int64, timeZone: String,
      languagePolicy: LanguagePolicyValue
    ) {
      self.id = id
      self.title = title
      self.startedAt = startedAt
      self.durationMs = durationMs
      self.timeZone = timeZone
      self.languagePolicy = languagePolicy
    }
  }

  public struct LanguagePolicyValue: Encodable, Sendable, Equatable {
    public let output: AnalysisLanguage
    public let preserveTerms: Bool

    public enum CodingKeys: String, CodingKey {
      case output
      case preserveTerms = "preserve_terms"
    }

    public init(output: AnalysisLanguage, preserveTerms: Bool) {
      self.output = output
      self.preserveTerms = preserveTerms
    }
  }

  public struct Participant: Encodable, Sendable, Equatable {
    public let speakerID: UUID
    public let certainty: ParticipantCertainty
    public let origin: String
    public let knownSpeakerID: UUID?
    public let name: String?
    public var label: String? = nil

    public enum CodingKeys: String, CodingKey {
      case speakerID = "speaker_id"
      case certainty, origin
      case knownSpeakerID = "known_speaker_id"
      case name, label
    }

    public init(
      speakerID: UUID, certainty: ParticipantCertainty, origin: String, knownSpeakerID: UUID?,
      name: String?, label: String? = nil
    ) {
      self.speakerID = speakerID
      self.certainty = certainty
      self.origin = origin
      self.knownSpeakerID = knownSpeakerID
      self.name = name
      self.label = label
    }
  }

  public struct Segment: Encodable, Sendable, Equatable {
    public let id: UUID
    public let startMs: Int64
    public let endMs: Int64
    /// nil encodes as `null`, never omitted.
    public let speakerID: UUID?
    public let text: String

    public enum CodingKeys: String, CodingKey {
      case id
      case startMs = "start_ms"
      case endMs = "end_ms"
      case speakerID = "speaker_id"
      case text
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id.uuidString, forKey: .id)
      try container.encode(startMs, forKey: .startMs)
      try container.encode(endMs, forKey: .endMs)
      if let speakerID {
        try container.encode(speakerID.uuidString, forKey: .speakerID)
      } else {
        try container.encodeNil(forKey: .speakerID)
      }
      try container.encode(text, forKey: .text)
    }

    public init(id: UUID, startMs: Int64, endMs: Int64, speakerID: UUID?, text: String) {
      self.id = id
      self.startMs = startMs
      self.endMs = endMs
      self.speakerID = speakerID
      self.text = text
    }
  }

  public struct Note: Encodable, Sendable, Equatable {
    public let ordinal: Int
    public let text: String

    public enum CodingKeys: String, CodingKey {
      case id, text
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("note:\(ordinal)", forKey: .id)
      try container.encode(text, forKey: .text)
    }

    public init(ordinal: Int, text: String) {
      self.ordinal = ordinal
      self.text = text
    }
  }

  public struct Chunk: Encodable, Sendable, Equatable {
    public let index: Int
    public let count: Int

    public init(index: Int, count: Int) {
      self.index = index
      self.count = count
    }
  }

  public let schemaVersion = AnalysisBounds.schemaVersion
  public let requestID: UUID
  public let runID: UUID
  public let stage: AnalysisStage
  public let chunk: Chunk?
  public let meeting: Meeting
  public let participants: [Participant]
  public let segments: [Segment]?
  public let notes: [Note]?
  public let partials: [AnalysisResult]?

  public enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case runID = "run_id"
    case priority, stage, chunk, meeting, participants, segments, notes, partials
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID.uuidString, forKey: .requestID)
    try container.encode(runID.uuidString, forKey: .runID)
    try container.encode("background", forKey: .priority)
    try container.encode(stage.rawValue, forKey: .stage)
    try container.encodeIfPresent(chunk, forKey: .chunk)
    try container.encode(meeting, forKey: .meeting)
    try container.encode(participants, forKey: .participants)
    try container.encodeIfPresent(segments, forKey: .segments)
    try container.encodeIfPresent(notes, forKey: .notes)
    try container.encodeIfPresent(partials, forKey: .partials)
  }

  public init(
    requestID: UUID, runID: UUID, stage: AnalysisStage, chunk: Chunk?, meeting: Meeting,
    participants: [Participant], segments: [Segment]?, notes: [Note]?, partials: [AnalysisResult]?
  ) {
    self.requestID = requestID
    self.runID = runID
    self.stage = stage
    self.chunk = chunk
    self.meeting = meeting
    self.participants = participants
    self.segments = segments
    self.notes = notes
    self.partials = partials
  }
}

// MARK: - Result wire types

public struct WireSummary: Sendable, Equatable, Encodable {
  public var text: String
  public var sources: [WireSourceRef]
  public var wholeMeeting: Bool

  public enum CodingKeys: String, CodingKey {
    case text, sources
    case wholeMeeting = "whole_meeting"
  }

  public init(text: String, sources: [WireSourceRef], wholeMeeting: Bool) {
    self.text = text
    self.sources = sources
    self.wholeMeeting = wholeMeeting
  }
}

public struct WireTopic: Sendable, Equatable, Encodable {
  public var title: String
  public var summary: String
  public var bullets: [String]
  public var sources: [WireSourceRef]

  public init(title: String, summary: String, bullets: [String], sources: [WireSourceRef]) {
    self.title = title
    self.summary = summary
    self.bullets = bullets
    self.sources = sources
  }
}

public struct WireItem: Sendable, Equatable, Encodable {
  public var text: String
  public var evidenceClass: EvidenceClass?
  public var sources: [WireSourceRef]

  public enum CodingKeys: String, CodingKey {
    case text
    case evidenceClass = "evidence_class"
    case sources
  }

  public init(text: String, evidenceClass: EvidenceClass? = nil, sources: [WireSourceRef]) {
    self.text = text
    self.evidenceClass = evidenceClass
    self.sources = sources
  }
}

public enum WireOwnerKind: String, Sendable, Equatable, Encodable {
  case participant, mentioned, none
}

public struct WireOwner: Sendable, Equatable, Encodable {
  public var kind: WireOwnerKind
  public var speakerID: UUID?
  public var name: String?

  public enum CodingKeys: String, CodingKey {
    case kind
    case speakerID = "speaker_id"
    case name
  }

  public init(kind: WireOwnerKind, speakerID: UUID? = nil, name: String? = nil) {
    self.kind = kind
    self.speakerID = speakerID
    self.name = name
  }
}

public struct WireDue: Sendable, Equatable, Encodable {
  public var state: DueState
  public var date: String?
  public var original: String?
  public var source: WireSourceRef?

  public init(
    state: DueState, date: String? = nil, original: String? = nil, source: WireSourceRef? = nil
  ) {
    self.state = state
    self.date = date
    self.original = original
    self.source = source
  }
}

public struct WireActionItem: Sendable, Equatable, Encodable {
  public var text: String
  public var owner: WireOwner
  public var ownershipState: OwnershipState
  public var due: WireDue
  public var sources: [WireSourceRef]

  public enum CodingKeys: String, CodingKey {
    case text, owner
    case ownershipState = "ownership_state"
    case due, sources
  }

  public init(
    text: String, owner: WireOwner, ownershipState: OwnershipState, due: WireDue,
    sources: [WireSourceRef]
  ) {
    self.text = text
    self.owner = owner
    self.ownershipState = ownershipState
    self.due = due
    self.sources = sources
  }
}

/// The `analysis` object of a `result` event, after the bounded decoder ran.
/// Also the value a `synthesis` request carries in `partials`.
public struct AnalysisResult: Sendable, Equatable, Encodable {
  public var schemaVersion: Int
  public var meetingID: UUID
  public var partial: Bool
  public var language: AnalysisLanguage
  public var summary: WireSummary
  public var topics: [WireTopic]
  public var decisions: [WireItem]
  public var actionItems: [WireActionItem]
  public var nextSteps: [WireItem]
  public var openQuestions: [WireItem]
  public var risks: [WireItem]

  /// Decode a `result` event's `analysis` object with every structural rule of
  /// the contract. `partial == true` applies the halved section caps.
  public static func decode(_ value: Any?, partial: Bool) throws -> AnalysisResult {
    let object = try object(
      value,
      allowed: [
        "schema_version", "meeting_id", "partial", "language", "summary", "topics",
        "decisions", "action_items", "next_steps", "open_questions", "risks",
      ])
    guard try requiredInt(object, "schema_version") == AnalysisBounds.schemaVersion else {
      throw AnalysisFailure(.unsupportedVersion)
    }
    guard let meetingID = UUID(uuidString: try requiredString(object, "meeting_id")) else {
      throw AnalysisFailure(.malformedResponse)
    }
    guard let isPartial = object["partial"] as? Bool,
      let language = AnalysisLanguage(rawValue: try requiredString(object, "language"))
    else { throw AnalysisFailure(.malformedResponse) }
    let policy = AnalysisPolicy()
    let summary = try decodeSummary(object["summary"])
    let topics = try decodeArray(object, "topics", cap: policy.cap(for: .topics, partial: partial))
    {
      try decodeTopic($0)
    }
    let decisions = try decodeArray(
      object, "decisions", cap: policy.cap(for: .decisions, partial: partial)
    ) { try decodeItem($0, evidenceAllowed: true) }
    let actions = try decodeArray(
      object, "action_items", cap: policy.cap(for: .actionItems, partial: partial)
    ) { try decodeActionItem($0) }
    let nextSteps = try decodeArray(
      object, "next_steps", cap: policy.cap(for: .nextSteps, partial: partial)
    ) { try decodeItem($0, evidenceAllowed: false) }
    let questions = try decodeArray(
      object, "open_questions", cap: policy.cap(for: .openQuestions, partial: partial)
    ) { try decodeItem($0, evidenceAllowed: true) }
    let risks = try decodeArray(
      object, "risks", cap: policy.cap(for: .risks, partial: partial)
    ) { try decodeItem($0, evidenceAllowed: true) }
    return AnalysisResult(
      schemaVersion: 1, meetingID: meetingID, partial: isPartial, language: language,
      summary: summary, topics: topics, decisions: decisions, actionItems: actions,
      nextSteps: nextSteps, openQuestions: questions, risks: risks)
  }

  /// CodingKeys is the closed key set of the `analysis` object; used for both
  /// decoding partials and encoding them into synthesis requests.
  public enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case meetingID = "meeting_id"
    case partial, language, summary, topics, decisions
    case actionItems = "action_items"
    case nextSteps = "next_steps"
    case openQuestions = "open_questions"
    case risks
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(meetingID.uuidString, forKey: .meetingID)
    try container.encode(partial, forKey: .partial)
    try container.encode(language.rawValue, forKey: .language)
    try container.encode(summary, forKey: .summary)
    try container.encode(topics, forKey: .topics)
    try container.encode(decisions, forKey: .decisions)
    try container.encode(actionItems, forKey: .actionItems)
    try container.encode(nextSteps, forKey: .nextSteps)
    try container.encode(openQuestions, forKey: .openQuestions)
    try container.encode(risks, forKey: .risks)
  }

  // MARK: Decoding helpers (strict: unknown keys, wrong types, closed enums)

  private static func object(_ value: Any?, allowed: Set<String>) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
      throw AnalysisFailure(.malformedResponse)
    }
    for key in object.keys where !allowed.contains(key) {
      throw AnalysisFailure(.malformedResponse)
    }
    return object
  }

  private static func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else { throw AnalysisFailure(.malformedResponse) }
    return value
  }

  private static func requiredInt(_ object: [String: Any], _ key: String) throws -> Int {
    guard let value = JSONField.int(object[key]) else {
      throw AnalysisFailure(.malformedResponse)
    }
    return value
  }

  private static func boundedString(
    _ object: [String: Any], _ key: String, min: Int, max: Int
  ) throws -> String {
    let value = try requiredString(object, key)
    guard value.utf8.count >= min, value.utf8.count <= max else {
      throw AnalysisFailure(.malformedResponse)
    }
    return value
  }

  private static func decodeArray<T>(
    _ object: [String: Any], _ key: String, cap: Int, _ decode: (Any) throws -> T
  ) throws -> [T] {
    guard let array = object[key] as? [Any] else { throw AnalysisFailure(.malformedResponse) }
    if array.count > cap { throw AnalysisFailure(.overCap) }
    return try array.map(decode)
  }

  private static func decodeSource(_ value: Any) throws -> WireSourceRef {
    let object = try object(value, allowed: ["kind", "id"])
    guard let kind = WireSourceRef.Kind(rawValue: try requiredString(object, "kind")) else {
      throw AnalysisFailure(.malformedResponse)
    }
    let id = try requiredString(object, "id")
    switch kind {
    case .segment:
      guard UUID(uuidString: id) != nil else { throw AnalysisFailure(.malformedResponse) }
    case .note:
      guard id.hasPrefix("note:"), Int(id.dropFirst(5)) != nil else {
        throw AnalysisFailure(.malformedResponse)
      }
    }
    return WireSourceRef(kind: kind, id: id)
  }

  private static func decodeSources(
    _ object: [String: Any], min: Int
  ) throws -> [WireSourceRef] {
    guard let array = object["sources"] as? [Any] else {
      throw AnalysisFailure(.malformedResponse)
    }
    if array.count < min || array.count > AnalysisBounds.maxSourcesPerItem {
      throw AnalysisFailure(.malformedResponse)
    }
    let refs = try array.map(decodeSource)
    if Set(refs.map { "\($0.kind.rawValue):\($0.id)" }).count != refs.count {
      throw AnalysisFailure(.malformedResponse)
    }
    return refs
  }

  private static func decodeSummary(_ value: Any?) throws -> WireSummary {
    let object = try object(value, allowed: ["text", "sources", "whole_meeting"])
    let text = try boundedString(
      object, "text", min: 1, max: AnalysisBounds.maxSummaryBytes)
    let sources = try decodeSources(object, min: 0)
    guard let whole = object["whole_meeting"] as? Bool else {
      throw AnalysisFailure(.malformedResponse)
    }
    return WireSummary(text: text, sources: sources, wholeMeeting: whole)
  }

  private static func decodeTopic(_ value: Any) throws -> WireTopic {
    let object = try object(value, allowed: ["title", "summary", "bullets", "sources"])
    let title = try boundedString(
      object, "title", min: 1, max: AnalysisBounds.maxTopicTitleBytes)
    let summary = try boundedString(
      object, "summary", min: 0, max: AnalysisBounds.maxTopicSummaryBytes)
    guard let bullets = object["bullets"] as? [Any],
      bullets.count <= AnalysisBounds.maxTopicBullets
    else { throw AnalysisFailure(.malformedResponse) }
    var decoded: [String] = []
    for bullet in bullets {
      guard let text = bullet as? String,
        text.utf8.count <= AnalysisBounds.maxTopicBulletBytes
      else { throw AnalysisFailure(.malformedResponse) }
      decoded.append(text)
    }
    return WireTopic(
      title: title, summary: summary, bullets: decoded,
      sources: try decodeSources(object, min: 0))
  }

  private static func decodeItem(_ value: Any, evidenceAllowed: Bool) throws -> WireItem {
    var allowed: Set<String> = ["text", "sources"]
    if evidenceAllowed { allowed.insert("evidence_class") }
    let object = try object(value, allowed: allowed)
    let text = try boundedString(object, "text", min: 1, max: AnalysisBounds.maxItemTextBytes)
    var evidenceClass: EvidenceClass?
    if let raw = object["evidence_class"] {
      guard let string = raw as? String, let parsed = EvidenceClass(rawValue: string) else {
        throw AnalysisFailure(.malformedResponse)
      }
      evidenceClass = parsed
    }
    return WireItem(
      text: text, evidenceClass: evidenceClass, sources: try decodeSources(object, min: 1))
  }

  private static func decodeOwner(_ value: Any?) throws -> WireOwner {
    let object = try object(value, allowed: ["kind", "speaker_id", "name"])
    guard let kind = WireOwnerKind(rawValue: try requiredString(object, "kind")) else {
      throw AnalysisFailure(.malformedResponse)
    }
    switch kind {
    case .participant:
      guard let raw = object["speaker_id"] as? String, let id = UUID(uuidString: raw),
        object["name"] == nil
      else { throw AnalysisFailure(.malformedResponse) }
      return WireOwner(kind: kind, speakerID: id, name: nil)
    case .mentioned:
      let name = try boundedString(
        object, "name", min: 1, max: AnalysisBounds.maxOwnerNameBytes)
      guard object["speaker_id"] == nil else { throw AnalysisFailure(.malformedResponse) }
      return WireOwner(kind: kind, speakerID: nil, name: name)
    case .none:
      guard object["speaker_id"] == nil, object["name"] == nil else {
        throw AnalysisFailure(.malformedResponse)
      }
      return WireOwner(kind: kind, speakerID: nil, name: nil)
    }
  }

  /// `YYYY-MM-DD` shape only; calendar validity is the resolver's job.
  private static func isDueDateShape(_ string: String) -> Bool {
    let parts = string.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2,
      parts[2].count == 2
    else { return false }
    return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
  }

  private static func decodeDue(_ value: Any?) throws -> WireDue {
    let object = try object(value, allowed: ["state", "date", "original", "source"])
    guard let state = DueState(rawValue: try requiredString(object, "state")) else {
      throw AnalysisFailure(.malformedResponse)
    }
    let date = object["date"] as? String
    if let date, !isDueDateShape(date) {
      throw AnalysisFailure(.malformedResponse)
    }
    let original = object["original"] as? String
    if let original,
      original.isEmpty
        || original.utf8.count > AnalysisBounds.maxDueOriginalBytes
    {
      throw AnalysisFailure(.malformedResponse)
    }
    var source: WireSourceRef?
    if let raw = object["source"] { source = try decodeSource(raw) }
    switch state {
    case .explicitAbsolute, .explicitRelativeResolved:
      guard date != nil, original != nil, source != nil else {
        throw AnalysisFailure(.malformedResponse)
      }
    case .unresolved:
      guard date == nil, original != nil, source != nil else {
        throw AnalysisFailure(.malformedResponse)
      }
    case .absent:
      guard date == nil, original == nil, source == nil else {
        throw AnalysisFailure(.malformedResponse)
      }
    }
    return WireDue(state: state, date: date, original: original, source: source)
  }

  private static func decodeActionItem(_ value: Any) throws -> WireActionItem {
    let object = try object(
      value, allowed: ["text", "owner", "ownership_state", "due", "sources"])
    let text = try boundedString(object, "text", min: 1, max: AnalysisBounds.maxItemTextBytes)
    guard let state = OwnershipState(rawValue: try requiredString(object, "ownership_state"))
    else { throw AnalysisFailure(.malformedResponse) }
    return WireActionItem(
      text: text, owner: try decodeOwner(object["owner"]), ownershipState: state,
      due: try decodeDue(object["due"]), sources: try decodeSources(object, min: 1))
  }

  public init(
    schemaVersion: Int, meetingID: UUID, partial: Bool, language: AnalysisLanguage,
    summary: WireSummary, topics: [WireTopic], decisions: [WireItem], actionItems: [WireActionItem],
    nextSteps: [WireItem], openQuestions: [WireItem], risks: [WireItem]
  ) {
    self.schemaVersion = schemaVersion
    self.meetingID = meetingID
    self.partial = partial
    self.language = language
    self.summary = summary
    self.topics = topics
    self.decisions = decisions
    self.actionItems = actionItems
    self.nextSteps = nextSteps
    self.openQuestions = openQuestions
    self.risks = risks
  }
}

// MARK: - Events

public enum AnalysisEvent: Sendable, Equatable {
  public struct Identity: Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
      self.name = name
      self.version = version
    }
  }
  public struct Backend: Sendable, Equatable {
    public let kind: String
    public let model: String

    public init(kind: String, model: String) {
      self.kind = kind
      self.model = model
    }
  }
  public struct Timing: Sendable, Equatable {
    public let queueMs: Int?
    public let firstTokenMs: Int?
    public let backendMs: Int?

    public init(queueMs: Int?, firstTokenMs: Int?, backendMs: Int?) {
      self.queueMs = queueMs
      self.firstTokenMs = firstTokenMs
      self.backendMs = backendMs
    }
  }
  public struct ResultPayload: Sendable, Equatable {
    public let requestID: String?
    public let runID: String?
    public let stage: String?
    public let server: Identity?
    public let backend: Backend?
    public let promptVersion: Int?
    public let pipelineVersion: String?
    public let timing: Timing?
    public let preemptions: Int?
    public let analysis: AnalysisResult

    public init(
      requestID: String?, runID: String?, stage: String?, server: Identity?, backend: Backend?,
      promptVersion: Int?, pipelineVersion: String?, timing: Timing?, preemptions: Int?,
      analysis: AnalysisResult
    ) {
      self.requestID = requestID
      self.runID = runID
      self.stage = stage
      self.server = server
      self.backend = backend
      self.promptVersion = promptVersion
      self.pipelineVersion = pipelineVersion
      self.timing = timing
      self.preemptions = preemptions
      self.analysis = analysis
    }
  }

  case accepted(requestID: String?, server: Identity?)
  case progress(requestID: String?, stage: String?, chars: Int)
  case result(ResultPayload)
  case error(requestID: String?, code: String)

  public var requestID: String? {
    switch self {
    case .accepted(let id, _), .progress(let id, _, _), .error(let id, _): return id
    case .result(let payload): return payload.requestID
    }
  }

  /// One NDJSON line. Lines over `AnalysisBounds.maxLineBytes` never reach this:
  /// the transport stops with `oversized_response` first.
  public static func decode(line: Data) throws -> AnalysisEvent {
    guard line.count <= AnalysisBounds.maxLineBytes else {
      throw AnalysisFailure(.oversizedResponse)
    }
    guard let raw = try? JSONSerialization.jsonObject(with: line),
      let object = raw as? [String: Any], let type = object["type"] as? String
    else { throw AnalysisFailure(.malformedResponse) }
    guard JSONField.int(object["schema_version"]) == AnalysisBounds.schemaVersion else {
      throw AnalysisFailure(.unsupportedVersion)
    }
    let id = object["request_id"] as? String
    func identity(_ value: Any?) -> Identity? {
      guard let dict = value as? [String: Any],
        let name = dict["name"] as? String, let version = dict["version"] as? String,
        name.utf8.count <= AnalysisBounds.maxIdentityBytes,
        version.utf8.count <= AnalysisBounds.maxIdentityBytes
      else { return nil }
      return Identity(name: name, version: version)
    }
    switch type {
    case "accepted":
      return .accepted(requestID: id, server: identity(object["server"]))
    case "progress":
      return .progress(
        requestID: id, stage: object["stage"] as? String,
        chars: JSONField.int(object["chars"]) ?? 0)
    case "result":
      guard let stage = object["stage"] as? String,
        let analysisStage = AnalysisStage(rawValue: stage)
      else { throw AnalysisFailure(.malformedResponse) }
      let analysis = try AnalysisResult.decode(
        object["analysis"], partial: analysisStage == .chunk)
      let backend = (object["backend"] as? [String: Any]).flatMap { dict -> Backend? in
        guard let kind = dict["kind"] as? String, let model = dict["model"] as? String
        else { return nil }
        return Backend(kind: kind, model: model)
      }
      let timing = (object["timing"] as? [String: Any]).map { dict in
        Timing(
          queueMs: JSONField.int(dict["queue_ms"]),
          firstTokenMs: JSONField.int(dict["first_token_ms"]),
          backendMs: JSONField.int(dict["backend_ms"]))
      }
      return .result(
        ResultPayload(
          requestID: id, runID: object["run_id"] as? String, stage: stage,
          server: identity(object["server"]), backend: backend,
          promptVersion: JSONField.int(object["prompt_version"]),
          pipelineVersion: object["pipeline_version"] as? String, timing: timing,
          preemptions: JSONField.int(object["preemptions"]), analysis: analysis))
    case "error":
      guard let code = object["code"] as? String else {
        throw AnalysisFailure(.malformedResponse)
      }
      return .error(requestID: id, code: code)
    default:
      throw AnalysisFailure(.malformedResponse)
    }
  }
}

// MARK: - Health

/// `GET /v1/analysis/health`. `limits`/`caps` are optional so a partial body
/// maps to a category instead of a decode error.
public struct AnalysisHealth: Sendable, Equatable {
  public struct Backend: Sendable, Equatable {
    public let state: String
    public let kind: String?
    public let model: String?
    public let jsonSchema: Bool

    public init(state: String, kind: String?, model: String?, jsonSchema: Bool) {
      self.state = state
      self.kind = kind
      self.model = model
      self.jsonSchema = jsonSchema
    }
  }
  public struct Limits: Sendable, Equatable {
    public var inputBytes: Int
    public var outputBytes: Int
    public var contextTokens: Int
    public var concurrency: Int

    public init(inputBytes: Int, outputBytes: Int, contextTokens: Int, concurrency: Int) {
      self.inputBytes = inputBytes
      self.outputBytes = outputBytes
      self.contextTokens = contextTokens
      self.concurrency = concurrency
    }
  }
  public struct Caps: Sendable, Equatable {
    public var sourcesPerItem: Int
    public var topics: Int
    public var decisions: Int
    public var actionItems: Int
    public var nextSteps: Int
    public var openQuestions: Int
    public var risks: Int

    public init(
      sourcesPerItem: Int, topics: Int, decisions: Int, actionItems: Int, nextSteps: Int,
      openQuestions: Int, risks: Int
    ) {
      self.sourcesPerItem = sourcesPerItem
      self.topics = topics
      self.decisions = decisions
      self.actionItems = actionItems
      self.nextSteps = nextSteps
      self.openQuestions = openQuestions
      self.risks = risks
    }
  }

  public let schemaVersion: Int?
  public let service: String?
  public let protocolVersions: [Int]
  public let serverName: String?
  public let serverVersion: String?
  public let backend: Backend?
  public let promptVersions: [String: Int]
  public let resultSchemaVersion: Int?
  public let limits: Limits?
  public let caps: Caps?

  public static let serviceName = "localflow-analysis"

  public static func decode(_ data: Data) throws -> AnalysisHealth {
    guard let raw = try? JSONSerialization.jsonObject(with: data),
      let object = raw as? [String: Any]
    else { throw AnalysisFailure(.malformedResponse) }
    let server = object["server"] as? [String: Any]
    let backend = (object["backend"] as? [String: Any]).flatMap { dict -> Backend? in
      guard let state = dict["state"] as? String else { return nil }
      return Backend(
        state: state, kind: dict["kind"] as? String, model: dict["model"] as? String,
        jsonSchema: dict["json_schema"] as? Bool ?? false)
    }
    var promptVersions: [String: Int] = [:]
    for (key, value) in object["prompt_versions"] as? [String: Any] ?? [:] {
      if let version = JSONField.int(value) { promptVersions[key] = version }
    }
    let limits = (object["limits"] as? [String: Any]).flatMap { dict -> Limits? in
      guard let input = JSONField.int(dict["input_bytes"]),
        let output = JSONField.int(dict["output_bytes"]),
        let context = JSONField.int(dict["context_tokens"]),
        let concurrency = JSONField.int(dict["concurrency"])
      else { return nil }
      return Limits(
        inputBytes: input, outputBytes: output, contextTokens: context,
        concurrency: concurrency)
    }
    let caps = (object["caps"] as? [String: Any]).flatMap { dict -> Caps? in
      guard let sources = JSONField.int(dict["sources_per_item"]),
        let topics = JSONField.int(dict["topics"]),
        let decisions = JSONField.int(dict["decisions"]),
        let actions = JSONField.int(dict["action_items"]),
        let nextSteps = JSONField.int(dict["next_steps"]),
        let questions = JSONField.int(dict["open_questions"]),
        let risks = JSONField.int(dict["risks"])
      else { return nil }
      return Caps(
        sourcesPerItem: sources, topics: topics, decisions: decisions,
        actionItems: actions, nextSteps: nextSteps, openQuestions: questions,
        risks: risks)
    }
    return AnalysisHealth(
      schemaVersion: JSONField.int(object["schema_version"]),
      service: object["service"] as? String,
      protocolVersions: (object["protocol_versions"] as? [Any])?.compactMap(JSONField.int)
        ?? [],
      serverName: server?["name"] as? String, serverVersion: server?["version"] as? String,
      backend: backend, promptVersions: promptVersions,
      resultSchemaVersion: JSONField.int(object["result_schema_version"]),
      limits: limits, caps: caps)
  }

  public var isAnalysisService: Bool { service == Self.serviceName }
  public var resultSchemaSupported: Bool { resultSchemaVersion == AnalysisBounds.schemaVersion }

  public init(
    schemaVersion: Int?, service: String?, protocolVersions: [Int], serverName: String?,
    serverVersion: String?, backend: Backend?, promptVersions: [String: Int],
    resultSchemaVersion: Int?, limits: Limits?, caps: Caps?
  ) {
    self.schemaVersion = schemaVersion
    self.service = service
    self.protocolVersions = protocolVersions
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.backend = backend
    self.promptVersions = promptVersions
    self.resultSchemaVersion = resultSchemaVersion
    self.limits = limits
    self.caps = caps
  }
}
