import Foundation

/// LocalFlow rewrite protocol v1 types and the client-side validation rules from
/// `specs/003-server-rewriting/contracts/rewrite-protocol.md`. Nothing here talks
/// to the network; `RewriteClient` reads bytes and hands decoded events to
/// `RewriteResultValidator`.
enum RewriteMode: String, Codable, CaseIterable, Sendable {
  case exact, clean, polished, concise
  var title: String { rawValue.capitalized }
  /// `exact` never produces a request.
  var sendsRequest: Bool { self != .exact }
}

/// Every numeric limit of the wire contract in one place.
enum RewriteBounds {
  static let schemaVersion = 1
  /// Feature 012: v1 plus a required `context` object (ADR 0023).
  static let contextSchemaVersion = 2
  static let maximumInputScalars = 20_000
  static let maximumInputBytes = 65_536
  static let maximumLineBytes = 8_192
  static let maximumErrorBodyBytes = 8_192
  /// `en` and `sk`, each at most once: the only languages LocalFlow supports.
  static let maximumLanguageHints = 2
  static let maximumIdentityBytes = 128
  static let placeholderGlyphs: Set<Character> = ["⟦", "⟧"]

  static func maximumResultBytes(inputBytes: Int) -> Int {
    min(4 * max(0, inputBytes), maximumInputBytes)
  }
  static func maximumResponseBytes(inputBytes: Int) -> Int {
    min(4 * max(0, inputBytes) + maximumLineBytes, 73_728)
  }
}

/// One canonical set with two halves (`data-model.md`, "Rewrite attempt"): the
/// twelve codes a `rewrite_attempts` row may carry, and the seven pre-admission
/// refusal reasons that are surfaced in notices and counters but never stored.
enum RewriteFailureCategory: String, Codable, CaseIterable, Sendable, Hashable {
  case serverUnreachable = "server_unreachable"
  case timeout
  case authenticationFailed = "authentication_failed"
  case transportError = "transport_error"
  case backendUnavailable = "backend_unavailable"
  case malformedResponse = "malformed_response"
  case unsupportedSchemaVersion = "unsupported_schema_version"
  case emptyResponse = "empty_response"
  case oversizedResponse = "oversized_response"
  case serverValidationFailed = "server_validation_failed"
  case requestMismatch = "request_mismatch"
  case interrupted
  /// Feature 012: the result copied on-screen text the speaker did not say.
  case contextCopied = "context_copied"

  case inputTooLarge = "input_too_large"
  case missingCredential = "missing_credential"
  case insecureEndpointBlocked = "insecure_endpoint_blocked"
  case concurrencyLimit = "concurrency_limit"
  case attemptLimit = "attempt_limit"
  case capacityExceeded = "capacity_exceeded"
  case invalidSettings = "invalid_settings"

  static let persisted: [RewriteFailureCategory] = [
    .serverUnreachable, .timeout, .authenticationFailed, .transportError, .backendUnavailable,
    .malformedResponse, .unsupportedSchemaVersion, .emptyResponse, .oversizedResponse,
    .serverValidationFailed, .requestMismatch, .interrupted, .contextCopied,
  ]

  /// True for the post-admission half; the storage check constraint admits exactly these.
  var isPersistable: Bool { Self.persisted.contains(self) }

  /// Server `error` event codes. A code outside the contract is an unusable reply.
  static func forServerCode(_ code: String) -> RewriteFailureCategory {
    switch code {
    case "shield_restore_failed", "backend_error", "too_large", "invalid_request":
      return .serverValidationFailed
    case "output_too_large": return .oversizedResponse
    case "backend_timeout", "backend_first_token_timeout", "backend_unavailable", "server_busy":
      return .backendUnavailable
    case "unauthorized": return .authenticationFailed
    case "unsupported_version": return .unsupportedSchemaVersion
    default: return .malformedResponse
    }
  }

  /// Non-200 responses. The request was already admitted, so the result is always
  /// a post-admission category, never a local refusal reason.
  static func forHTTPStatus(_ status: Int, code: String?) -> RewriteFailureCategory {
    switch status {
    case 400:
      return code == "unsupported_version" ? .unsupportedSchemaVersion : .serverValidationFailed
    case 401, 403: return .authenticationFailed
    case 413: return .serverValidationFailed
    case 429, 503: return .backendUnavailable
    default: return .transportError
    }
  }
}

/// The error type every rewrite boundary throws. Carries a category only; never a
/// message, URL or body fragment.
struct RewriteFailure: Error, Equatable, Sendable {
  let category: RewriteFailureCategory
  init(_ category: RewriteFailureCategory) { self.category = category }
}

/// Body of `POST /v1/rewrite`. The closed `CodingKeys` set is the only thing the
/// encoder can emit, so no other field can ever reach the wire. With `context`
/// the request is protocol v2 and carries the stored canonical snapshot bytes.
struct RewriteRequest: Encodable, Sendable, Equatable {
  let schemaVersion: Int
  let requestID: UUID
  let mode: RewriteMode
  let text: String
  let languageHints: [String]
  let streamDeltas: Bool
  /// Canonical snapshot JSON exactly as stored; nil for v1.
  let context: Data?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case mode, text
    case languageHints = "language_hints"
    case streamDeltas = "stream_deltas"
    case context
  }

  init(
    requestID: UUID, mode: RewriteMode, text: String, languageHints: [String] = [],
    streamDeltas: Bool = false, context: Data? = nil
  ) throws {
    guard mode.sendsRequest else { throw RewriteFailure(.invalidSettings) }
    guard languageHints.count <= RewriteBounds.maximumLanguageHints,
      Set(languageHints).count == languageHints.count,
      languageHints.allSatisfy(MeetingLanguage.supportedCodes.contains)
    else { throw RewriteFailure(.invalidSettings) }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RewriteFailure(.invalidSettings)
    }
    guard text.unicodeScalars.count <= RewriteBounds.maximumInputScalars,
      text.utf8.count <= RewriteBounds.maximumInputBytes
    else { throw RewriteFailure(.inputTooLarge) }
    if let context {
      guard context.count <= AppContextSnapshot.maximumBytes,
        (try? JSONSerialization.jsonObject(with: context)) is [String: Any]
      else { throw RewriteFailure(.invalidSettings) }
    }
    schemaVersion =
      context == nil ? RewriteBounds.schemaVersion : RewriteBounds.contextSchemaVersion
    self.requestID = requestID
    self.mode = mode
    self.text = text
    self.languageHints = languageHints
    self.streamDeltas = streamDeltas
    self.context = context
  }

  var inputBytes: Int { text.utf8.count }
  var inputScalars: Int { text.unicodeScalars.count }
  var sendsContext: Bool { context != nil }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID.uuidString, forKey: .requestID)
    try container.encode(mode, forKey: .mode)
    try container.encode(text, forKey: .text)
    try container.encode(languageHints, forKey: .languageHints)
    try container.encode(streamDeltas, forKey: .streamDeltas)
    if let context {
      try container.encode(
        JSONDecoder().decode(AppContextSnapshot.self, from: context), forKey: .context)
    }
  }

  /// Wire bytes. The context is spliced in verbatim, so the sent object is
  /// byte-identical to the stored snapshot and its hash.
  func httpBody() throws -> Data {
    guard let context else { return try JSONEncoder().encode(self) }
    let fields = try JSONEncoder().encode(
      RewriteRequest(
        uncheckedVersion: schemaVersion, requestID: requestID, mode: mode, text: text,
        languageHints: languageHints, streamDeltas: streamDeltas))
    guard fields.last == UInt8(ascii: "}") else { throw RewriteFailure(.invalidSettings) }
    return fields.dropLast() + Data(#","context":"#.utf8) + context + Data("}".utf8)
  }

  private init(
    uncheckedVersion: Int, requestID: UUID, mode: RewriteMode, text: String,
    languageHints: [String], streamDeltas: Bool
  ) {
    schemaVersion = uncheckedVersion
    self.requestID = requestID
    self.mode = mode
    self.text = text
    self.languageHints = languageHints
    self.streamDeltas = streamDeltas
    context = nil
  }
}

/// One decoded NDJSON line. Decoding is structural only (rule 2); the semantic
/// rules run in `RewriteResultValidator` so every category is decided in order.
enum RewriteEvent: Sendable, Equatable {
  struct Identity: Sendable, Equatable {
    let name: String
    let version: String
  }
  struct Backend: Sendable, Equatable {
    let kind: String
    let model: String
  }
  struct Shield: Sendable, Equatable {
    let version: Int
    let placeholders: Int
    let restored: Int
  }
  struct Timing: Sendable, Equatable {
    let queueMilliseconds: Int?
    let backendFirstTokenMilliseconds: Int?
    let backendMilliseconds: Int?
  }
  /// Raw `result` fields; each identity field is nil when absent or of the wrong type.
  struct ResultPayload: Sendable, Equatable {
    let schemaVersion: Int?
    let requestID: String?
    let mode: String?
    let text: String?
    let textIsString: Bool
    let server: Identity?
    let backend: Backend?
    let promptVersion: Int?
    let shield: Shield?
    let timing: Timing?
    /// Feature 012: present on v2 results only.
    var contextPromptVersion: Int? = nil
  }

  case accepted(requestID: String?)
  case progress(requestID: String?, generatedChars: Int)
  case delta(requestID: String?, text: String)
  case result(ResultPayload)
  case error(requestID: String?, code: String, message: String)
  /// An event name outside v1; tolerated for forward compatibility, still id-checked.
  case other(requestID: String?)

  var isTerminal: Bool {
    switch self {
    case .result, .error: return true
    default: return false
    }
  }

  var requestID: String? {
    switch self {
    case .accepted(let id), .progress(let id, _), .delta(let id, _), .error(let id, _, _),
      .other(let id):
      return id
    case .result(let payload): return payload.requestID
    }
  }

  static func decode(line: Data) throws -> RewriteEvent {
    guard let raw = try? JSONSerialization.jsonObject(with: line),
      let object = raw as? [String: Any], let name = object["event"] as? String
    else { throw RewriteFailure(.malformedResponse) }
    let id = object["request_id"] as? String
    switch name {
    case "accepted": return .accepted(requestID: id)
    case "progress":
      return .progress(requestID: id, generatedChars: JSONField.int(object["generated_chars"]) ?? 0)
    case "delta": return .delta(requestID: id, text: object["text"] as? String ?? "")
    case "error":
      guard let code = object["code"] as? String else { throw RewriteFailure(.malformedResponse) }
      return .error(requestID: id, code: code, message: object["message"] as? String ?? "")
    case "result":
      let server = (object["server"] as? [String: Any]).flatMap { dictionary -> Identity? in
        guard let name = JSONField.identity(dictionary["name"]),
          let version = JSONField.identity(dictionary["version"])
        else { return nil }
        return Identity(name: name, version: version)
      }
      let backend = (object["backend"] as? [String: Any]).flatMap { dictionary -> Backend? in
        guard let kind = JSONField.identity(dictionary["kind"]),
          let model = JSONField.identity(dictionary["model"])
        else { return nil }
        return Backend(kind: kind, model: model)
      }
      let shield = (object["shield"] as? [String: Any]).flatMap { dictionary -> Shield? in
        guard let version = JSONField.int(dictionary["version"]),
          let placeholders = JSONField.int(dictionary["placeholders"]),
          let restored = JSONField.int(dictionary["restored"]), version >= 0, placeholders >= 0,
          restored >= 0
        else { return nil }
        return Shield(version: version, placeholders: placeholders, restored: restored)
      }
      let timing = (object["timing"] as? [String: Any]).map { dictionary in
        Timing(
          queueMilliseconds: JSONField.span(dictionary["queue_ms"]),
          backendFirstTokenMilliseconds: JSONField.span(dictionary["backend_first_token_ms"]),
          backendMilliseconds: JSONField.span(dictionary["backend_ms"]))
      }
      return .result(
        ResultPayload(
          schemaVersion: JSONField.int(object["schema_version"]), requestID: id,
          mode: object["mode"] as? String, text: object["text"] as? String,
          textIsString: object["text"] is String, server: server, backend: backend,
          promptVersion: JSONField.int(object["prompt_version"]), shield: shield, timing: timing,
          contextPromptVersion: JSONField.int(object["context_prompt_version"])))
    default: return .other(requestID: id)
    }
  }
}

/// Typed extraction from `JSONSerialization` values. Booleans are `NSNumber` too,
/// so an integer field must reject them explicitly.
enum JSONField {
  static func int(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    guard let double = Double(exactly: number), double.rounded() == double,
      double >= Double(Int32.min), double <= Double(Int32.max)
    else { return nil }
    return Int(double)
  }
  static func span(_ value: Any?) -> Int? {
    guard let value = int(value), value >= 0 else { return nil }
    return value
  }
  static func identity(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty,
      string.utf8.count <= RewriteBounds.maximumIdentityBytes
    else { return nil }
    return string
  }
}

/// A validated `result`: the only thing the rest of the app may insert or store.
struct RewriteResult: Sendable, Equatable {
  let text: String
  let unchanged: Bool
  let serverName: String
  let serverVersion: String
  let backendKind: String
  let backendModel: String
  let promptVersion: Int
  let shieldVersion: Int
  let serverQueueMilliseconds: Int?
  let backendFirstTokenMilliseconds: Int?
  let backendMilliseconds: Int?
  /// Feature 012: the server's context rules version; nil for v1.
  var contextPromptVersion: Int? = nil
}

enum RewriteResultValidator {
  /// Rules 3 to 9 of the contract, in order, over the decoded events of one
  /// response. Rules 1 and 2 (byte cap, line shape) are enforced while reading.
  static func validate(events: [RewriteEvent], for request: RewriteRequest, inputBytes: Int) throws
    -> RewriteResult
  {
    let expectedID = request.requestID.uuidString
    for event in events {
      switch event {
      case .result(let payload):
        guard payload.schemaVersion == RewriteBounds.schemaVersion else {
          throw RewriteFailure(.unsupportedSchemaVersion)
        }
        try checkID(payload.requestID, expected: expectedID)
        guard payload.mode == request.mode.rawValue else {
          throw RewriteFailure(.malformedResponse)
        }
        guard payload.textIsString, let text = payload.text else {
          throw RewriteFailure(.malformedResponse)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw RewriteFailure(.emptyResponse)
        }
        guard text.utf8.count <= RewriteBounds.maximumResultBytes(inputBytes: inputBytes) else {
          throw RewriteFailure(.oversizedResponse)
        }
        guard let server = payload.server, let backend = payload.backend,
          let promptVersion = payload.promptVersion, promptVersion >= 0,
          let shield = payload.shield, let timing = payload.timing
        else { throw RewriteFailure(.malformedResponse) }
        // A v2 result must name the context rules it was produced under.
        let contextPromptVersion = request.sendsContext ? payload.contextPromptVersion : nil
        guard !request.sendsContext || (contextPromptVersion ?? 0) >= 1 else {
          throw RewriteFailure(.malformedResponse)
        }
        guard !text.contains(where: { RewriteBounds.placeholderGlyphs.contains($0) }) else {
          throw RewriteFailure(.serverValidationFailed)
        }
        // A rewrite never translates: Slovak in, English out (or the reverse) falls
        // back to the faithful transcript.
        guard !isTranslation(input: request.text, output: text) else {
          throw RewriteFailure(.serverValidationFailed)
        }
        // Rule 9: the first terminal event decides; later ones are ignored.
        return RewriteResult(
          text: text, unchanged: text.utf8.elementsEqual(request.text.utf8),
          serverName: server.name, serverVersion: server.version, backendKind: backend.kind,
          backendModel: backend.model, promptVersion: promptVersion, shieldVersion: shield.version,
          serverQueueMilliseconds: timing.queueMilliseconds,
          backendFirstTokenMilliseconds: timing.backendFirstTokenMilliseconds,
          backendMilliseconds: timing.backendMilliseconds,
          contextPromptVersion: contextPromptVersion)
      case .error(let id, let code, _):
        try checkID(id, expected: expectedID)
        throw RewriteFailure(RewriteFailureCategory.forServerCode(code))
      case .accepted(let id), .progress(let id, _), .delta(let id, _), .other(let id):
        try checkID(id, expected: expectedID)
      }
    }
    throw RewriteFailure(.malformedResponse)
  }

  /// True only when both texts are substantial prose the English/Slovak recognizer
  /// is sure about and the languages differ. Short text, code, names and jargon
  /// lists are never sure enough to decide.
  static func isTranslation(input: String, output: String) -> Bool {
    func language(_ text: String) -> SupportedTextLanguage? {
      SupportedTextLanguage.confident(
        text, minimumLetters: 40, minimumWords: 6, minimumConfidence: 0.99)
    }
    guard let spoken = language(input), let written = language(output) else { return false }
    return spoken != written
  }

  private static func checkID(_ id: String?, expected: String) throws {
    guard let id else { throw RewriteFailure(.malformedResponse) }
    guard id.uppercased() == expected else { throw RewriteFailure(.requestMismatch) }
  }
}

/// `GET /v1/rewrite/health`. Fields the connection test distinguishes on are
/// optional so a wrong or partial body maps to a category instead of a decode error.
struct HealthResponse: Sendable, Equatable {
  struct Backend: Sendable, Equatable {
    let state: String
    let kind: String?
    let model: String?
  }
  let schemaVersion: Int?
  let service: String?
  let protocolVersions: [Int]
  let serverName: String?
  let serverVersion: String?
  let modes: [String]
  let backend: Backend?
  let promptVersions: [String: Int]
  let shieldVersion: Int?

  static let serviceName = "localflow-rewrite"

  /// Throws `malformedResponse` for a non-object body; every other shape decodes.
  static func decode(_ data: Data) throws -> HealthResponse {
    guard let raw = try? JSONSerialization.jsonObject(with: data),
      let object = raw as? [String: Any]
    else { throw RewriteFailure(.malformedResponse) }
    let server = object["server"] as? [String: Any]
    let backend = (object["backend"] as? [String: Any]).flatMap { dictionary -> Backend? in
      guard let state = dictionary["state"] as? String else { return nil }
      return Backend(
        state: state, kind: JSONField.identity(dictionary["kind"]),
        model: JSONField.identity(dictionary["model"]))
    }
    var promptVersions: [String: Int] = [:]
    for (key, value) in object["prompt_versions"] as? [String: Any] ?? [:] {
      if let version = JSONField.int(value) { promptVersions[key] = version }
    }
    return HealthResponse(
      schemaVersion: JSONField.int(object["schema_version"]), service: object["service"] as? String,
      protocolVersions: (object["protocol_versions"] as? [Any])?.compactMap(JSONField.int) ?? [],
      serverName: JSONField.identity(server?["name"]),
      serverVersion: JSONField.identity(server?["version"]),
      modes: (object["modes"] as? [String]) ?? [], backend: backend,
      promptVersions: promptVersions, shieldVersion: JSONField.int(object["shield_version"]))
  }

  var isRewriteService: Bool { service == Self.serviceName }
  var supportsProtocolOne: Bool { protocolVersions.contains(RewriteBounds.schemaVersion) }
  var supportsContext: Bool { protocolVersions.contains(RewriteBounds.contextSchemaVersion) }
  var backendReady: Bool { backend?.state == "ready" }
}

/// Bounded user-facing text per category (`contracts/client-rewrite.md`, "Failure
/// to user text"). Never carries transcript text, URLs or raw error descriptions.
enum RewriteNotice {
  enum Context: Sendable { case live, history }
  static let insertedSuffix = " Original text inserted."

  static func text(for category: RewriteFailureCategory, context: Context) -> String {
    let inserted = context == .live ? insertedSuffix : ""
    switch category {
    case .serverUnreachable: return "Rewrite server unreachable." + inserted
    case .transportError: return "Rewrite connection failed." + inserted
    case .timeout: return "Rewrite took too long." + inserted
    case .authenticationFailed: return "Rewrite server rejected the credential. Check Settings."
    case .backendUnavailable: return "Rewrite model is not available on the server."
    case .malformedResponse, .unsupportedSchemaVersion, .requestMismatch:
      return "Rewrite server sent an unusable reply."
    case .emptyResponse, .oversizedResponse, .serverValidationFailed:
      return "Rewrite result was rejected."
    case .missingCredential: return "Rewriting skipped: no credential for this server." + inserted
    case .insecureEndpointBlocked:
      return "Rewriting skipped: unencrypted connection blocked." + inserted
    case .invalidSettings: return "Rewriting skipped: the endpoint is invalid." + inserted
    case .inputTooLarge: return "Rewriting skipped: the text is too long." + inserted
    case .capacityExceeded: return "Rewriting skipped: history is full." + inserted
    case .attemptLimit: return "This dictation already has ten rewrite attempts."
    case .concurrencyLimit: return "Two rewrites are still running." + inserted
    case .interrupted: return "Rewrite was interrupted by a restart."
    case .contextCopied:
      return context == .live
        ? "Rewrite used on-screen text you did not say; inserted your transcript."
        : "Rewrite used on-screen text you did not say."
    }
  }

  static func cancelled(context: Context) -> String {
    "Rewrite cancelled." + (context == .live ? insertedSuffix : "")
  }

  /// A rewrite finished after the next dictation began; nothing was inserted.
  static let supersededSaved = "Previous dictation saved to history, not inserted."
}

/// Connection-test presentation and a separate, content-free diagnostic code.
struct RewriteConnectionTestResult: Sendable, Equatable {
  let category: RewriteConnectionCategory
  let protocolVersions: [Int]
  let serverName: String?
  let serverVersion: String?
  let backendKind: String?
  let backendModel: String?
  let promptVersions: [String: Int]
  let shieldVersion: Int?
  let testedAt: Date
  let diagnostic: String

  init(
    category: RewriteConnectionCategory, health: HealthResponse? = nil,
    testedAt: Date = Date(), diagnostic: String
  ) {
    self.category = category
    protocolVersions = Array((health?.protocolVersions ?? []).prefix(16))
    serverName = health?.serverName
    serverVersion = health?.serverVersion
    backendKind = health?.backend?.kind
    backendModel = health?.backend?.model
    promptVersions = (health?.promptVersions ?? [:]).filter {
      ["clean", "polished", "concise"].contains($0.key)
    }
    shieldVersion = health?.shieldVersion
    self.testedAt = testedAt
    self.diagnostic = Self.safeDiagnostic(diagnostic)
  }

  var statusText: String {
    switch category {
    case .connected: return "Connected."
    case .authenticationFailed: return "The server rejected the credential."
    case .serverUnreachable: return "Could not reach the server."
    case .rewriteServiceUnavailable:
      return "This endpoint does not provide the LocalFlow rewrite service."
    case .backendUnavailable: return "The rewrite model is not available on the server."
    case .incompatibleVersion: return "The server does not support rewrite protocol version 1."
    case .missingCredential: return "Set a credential for this server first."
    case .insecureEndpointBlocked:
      return "Allow the unencrypted connection to this server first, or use https://."
    }
  }

  var identityText: String {
    guard category == .connected else { return "" }
    let prompts = ["clean", "polished", "concise"].compactMap { mode in
      promptVersions[mode].map { "\(mode): \($0)" }
    }.joined(separator: ", ")
    return """
      Server: \(serverName ?? "Unknown") \(serverVersion ?? "Unknown")
      Backend: \(backendKind ?? "Unknown") · \(backendModel ?? "Unknown")
      Prompts: \(prompts)
      Shield: \(shieldVersion.map(String.init) ?? "Unknown")
      Protocol: \(protocolVersions.map(String.init).joined(separator: ", "))
      """
  }

  private static func safeDiagnostic(_ value: String) -> String {
    if [
      "preflight", "health_response", "transport_error", "no_http_response", "non_json",
      "health_too_large",
    ].contains(
      value)
    {
      return value
    }
    if value.hasPrefix("http_"), let code = Int(value.dropFirst(5)),
      (100...599).contains(code), value == "http_\(code)"
    {
      return value
    }
    if value.hasPrefix("url_error_"), let code = Int(value.dropFirst(10)),
      (-4000 ... -1).contains(code), value == "url_error_\(code)"
    {
      return value
    }
    return "transport_error"
  }
}
