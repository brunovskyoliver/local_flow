import Foundation

/// LocalFlow meeting analysis protocol v1 types and the client-side bounded
/// decoder (`specs/011-meeting-intelligence/contracts/analysis-protocol.md`).
/// Nothing here talks to the network; `AnalysisClient` reads bytes and hands
/// lines to `AnalysisEvent.decode`.
enum AnalysisBounds {
  static let schemaVersion = 1
  static let maxRequestBodyBytes = 262_144
  static let maxLineBytes = 98_304
  /// Whole response stream. flowd sends a ~110-byte `progress` line every
  /// 250 ms while generating, so a request that runs the full 300 s
  /// per-request timeout carries ~1,200 of them (~132 KB) before its result
  /// line (≤ `maxLineBytes`). 512 KiB leaves more than twice that room.
  static let maxStreamBytes = 524_288
  static let maxErrorBodyBytes = 8_192
  static let maxIdentityBytes = 128
  static let maxTitleBytes = 256
  static let maxTimeZoneBytes = 64
  static let maxParticipantNameBytes = 80
  static let maxOriginBytes = 32
  static let maxParticipants = 64
  static let maxSegments = 4_096
  static let maxSegmentTextBytes = 4_096
  static let maxNotes = 256
  static let maxNoteTextBytes = 8_192
  static let maxPartials = 16
  static let maxChunks = 64
  static let maxSummaryBytes = 4_000
  static let maxTopicTitleBytes = 200
  static let maxTopicSummaryBytes = 2_000
  static let maxTopicBullets = 12
  static let maxTopicBulletBytes = 500
  static let maxItemTextBytes = 1_000
  static let maxOwnerNameBytes = 80
  static let maxDueOriginalBytes = 80
  static let maxSourcesPerItem = 10
}

// MARK: - Request

enum AnalysisStage: String, Sendable, Equatable, Encodable {
  case full, chunk, synthesis
}

/// Body of `POST /v1/analysis/meeting`. The closed `CodingKeys` set is the only
/// thing the encoder can emit; optional keys are absent when nil.
struct AnalysisRequest: Encodable, Sendable, Equatable {
  struct Meeting: Encodable, Sendable, Equatable {
    let id: UUID
    let title: String
    /// RFC 3339 with offset.
    let startedAt: String
    let durationMs: Int64
    let timeZone: String
    let languagePolicy: LanguagePolicyValue

    enum CodingKeys: String, CodingKey {
      case id, title
      case startedAt = "started_at"
      case durationMs = "duration_ms"
      case timeZone = "time_zone"
      case languagePolicy = "language_policy"
    }
  }

  struct LanguagePolicyValue: Encodable, Sendable, Equatable {
    let output: AnalysisLanguage
    let preserveTerms: Bool

    enum CodingKeys: String, CodingKey {
      case output
      case preserveTerms = "preserve_terms"
    }
  }

  struct Participant: Encodable, Sendable, Equatable {
    let speakerID: UUID
    let certainty: ParticipantCertainty
    let origin: String
    let knownSpeakerID: UUID?
    let name: String?

    enum CodingKeys: String, CodingKey {
      case speakerID = "speaker_id"
      case certainty, origin
      case knownSpeakerID = "known_speaker_id"
      case name
    }
  }

  struct Segment: Encodable, Sendable, Equatable {
    let id: UUID
    let startMs: Int64
    let endMs: Int64
    /// nil encodes as `null`, never omitted.
    let speakerID: UUID?
    let text: String

    enum CodingKeys: String, CodingKey {
      case id
      case startMs = "start_ms"
      case endMs = "end_ms"
      case speakerID = "speaker_id"
      case text
    }

    func encode(to encoder: Encoder) throws {
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
  }

  struct Note: Encodable, Sendable, Equatable {
    let ordinal: Int
    let text: String

    enum CodingKeys: String, CodingKey {
      case id, text
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("note:\(ordinal)", forKey: .id)
      try container.encode(text, forKey: .text)
    }
  }

  struct Chunk: Encodable, Sendable, Equatable {
    let index: Int
    let count: Int
  }

  let schemaVersion = AnalysisBounds.schemaVersion
  let requestID: UUID
  let runID: UUID
  let stage: AnalysisStage
  let chunk: Chunk?
  let meeting: Meeting
  let participants: [Participant]
  let segments: [Segment]?
  let notes: [Note]?
  let partials: [AnalysisResult]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case runID = "run_id"
    case priority, stage, chunk, meeting, participants, segments, notes, partials
  }

  func encode(to encoder: Encoder) throws {
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
}

// MARK: - Result wire types

struct WireSummary: Sendable, Equatable, Encodable {
  var text: String
  var sources: [WireSourceRef]
  var wholeMeeting: Bool

  enum CodingKeys: String, CodingKey {
    case text, sources
    case wholeMeeting = "whole_meeting"
  }
}

struct WireTopic: Sendable, Equatable, Encodable {
  var title: String
  var summary: String
  var bullets: [String]
  var sources: [WireSourceRef]
}

struct WireItem: Sendable, Equatable, Encodable {
  var text: String
  var evidenceClass: EvidenceClass?
  var sources: [WireSourceRef]

  enum CodingKeys: String, CodingKey {
    case text
    case evidenceClass = "evidence_class"
    case sources
  }
}

enum WireOwnerKind: String, Sendable, Equatable, Encodable {
  case participant, mentioned, none
}

struct WireOwner: Sendable, Equatable, Encodable {
  var kind: WireOwnerKind
  var speakerID: UUID?
  var name: String?

  enum CodingKeys: String, CodingKey {
    case kind
    case speakerID = "speaker_id"
    case name
  }
}

struct WireDue: Sendable, Equatable, Encodable {
  var state: DueState
  var date: String?
  var original: String?
  var source: WireSourceRef?
}

struct WireActionItem: Sendable, Equatable, Encodable {
  var text: String
  var owner: WireOwner
  var ownershipState: OwnershipState
  var due: WireDue
  var sources: [WireSourceRef]

  enum CodingKeys: String, CodingKey {
    case text, owner
    case ownershipState = "ownership_state"
    case due, sources
  }
}

/// The `analysis` object of a `result` event, after the bounded decoder ran.
/// Also the value a `synthesis` request carries in `partials`.
struct AnalysisResult: Sendable, Equatable, Encodable {
  var schemaVersion: Int
  var meetingID: UUID
  var partial: Bool
  var language: AnalysisLanguage
  var summary: WireSummary
  var topics: [WireTopic]
  var decisions: [WireItem]
  var actionItems: [WireActionItem]
  var nextSteps: [WireItem]
  var openQuestions: [WireItem]
  var risks: [WireItem]

  /// Decode a `result` event's `analysis` object with every structural rule of
  /// the contract. `partial == true` applies the halved section caps.
  static func decode(_ value: Any?, partial: Bool) throws -> AnalysisResult {
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
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case meetingID = "meeting_id"
    case partial, language, summary, topics, decisions
    case actionItems = "action_items"
    case nextSteps = "next_steps"
    case openQuestions = "open_questions"
    case risks
  }

  func encode(to encoder: Encoder) throws {
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
}

// MARK: - Events

enum AnalysisEvent: Sendable, Equatable {
  struct Identity: Sendable, Equatable {
    let name: String
    let version: String
  }
  struct Backend: Sendable, Equatable {
    let kind: String
    let model: String
  }
  struct Timing: Sendable, Equatable {
    let queueMs: Int?
    let firstTokenMs: Int?
    let backendMs: Int?
  }
  struct ResultPayload: Sendable, Equatable {
    let requestID: String?
    let runID: String?
    let stage: String?
    let server: Identity?
    let backend: Backend?
    let promptVersion: Int?
    let pipelineVersion: String?
    let timing: Timing?
    let preemptions: Int?
    let analysis: AnalysisResult
  }

  case accepted(requestID: String?, server: Identity?)
  case progress(requestID: String?, stage: String?, chars: Int)
  case result(ResultPayload)
  case error(requestID: String?, code: String)

  var requestID: String? {
    switch self {
    case .accepted(let id, _), .progress(let id, _, _), .error(let id, _): return id
    case .result(let payload): return payload.requestID
    }
  }

  /// One NDJSON line. Lines over `AnalysisBounds.maxLineBytes` never reach this:
  /// the transport stops with `oversized_response` first.
  static func decode(line: Data) throws -> AnalysisEvent {
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
struct AnalysisHealth: Sendable, Equatable {
  struct Backend: Sendable, Equatable {
    let state: String
    let kind: String?
    let model: String?
    let jsonSchema: Bool
  }
  struct Limits: Sendable, Equatable {
    var inputBytes: Int
    var outputBytes: Int
    var contextTokens: Int
    var concurrency: Int
  }
  struct Caps: Sendable, Equatable {
    var sourcesPerItem: Int
    var topics: Int
    var decisions: Int
    var actionItems: Int
    var nextSteps: Int
    var openQuestions: Int
    var risks: Int
  }

  let schemaVersion: Int?
  let service: String?
  let protocolVersions: [Int]
  let serverName: String?
  let serverVersion: String?
  let backend: Backend?
  let promptVersions: [String: Int]
  let resultSchemaVersion: Int?
  let limits: Limits?
  let caps: Caps?

  static let serviceName = "localflow-analysis"

  static func decode(_ data: Data) throws -> AnalysisHealth {
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

  var isAnalysisService: Bool { service == Self.serviceName }
  var resultSchemaSupported: Bool { resultSchemaVersion == AnalysisBounds.schemaVersion }
}
