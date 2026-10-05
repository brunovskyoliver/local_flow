import CryptoKit
import Foundation
import LocalFlowSpeech

/// Control messages of remote channel v1 (`contracts/remote-channel.md`,
/// `protocol/schemas/remote-*.schema.json`). Audio travels in kind-0x01 frames and
/// never appears here.
public enum RemoteProtocol {
  public static let schemaVersion = 1
  public static let channelVersion = 1
  public static let suite = "x25519-hkdfsha256-chacha20poly1305"
  public static let maximumControlBytes = 65_536
  public static let maximumFrameSamples = 16_000
  /// Feature 018: kind-0x02 meeting frames.
  public static let maximumS16FrameSamples = 32_000
  public static let windowSamples = WindowedTranscriber.productionWindowSamples
  /// 180 s of 16 kHz audio: the dictation limit, so at most 13 windows.
  public static let maximumSessionSamples = 2_880_000
  public static let maximumWindows = 14
  public static let maximumBoostTerms = 256
  public static let maximumGovernedSpellings = 1_024
  public static let maximumTermBytes = 128
  public static let maximumDeviceNameBytes = 64
}

/// Error codes flowd sends in `error` messages.
public enum RemoteErrorCode: String, Codable, Sendable, CaseIterable {
  case unauthorized
  case tokenExpired = "token_expired"
  case notApproved = "not_approved"
  case revoked, busy
  case invalidMessage = "invalid_message"
  case unsupportedVersion = "unsupported_version"
  case limitExceeded = "limit_exceeded"
  case workerUnavailable = "worker_unavailable"
  /// Feature 018: the server does not serve this op or meeting job kind.
  case notOffered = "not_offered"
  case `internal`

  /// The code a dictation records when the server answered with this error.
  public var failureReason: RemoteFailureReason {
    switch self {
    case .unauthorized, .tokenExpired: .unauthorized
    case .notApproved: .notApproved
    case .revoked: .revoked
    case .busy: .busy
    case .limitExceeded: .limitExceeded
    case .workerUnavailable: .workerUnavailable
    case .invalidMessage, .unsupportedVersion, .notOffered, .internal: .protocolError
    }
  }
}

public enum RemoteProtocolError: Error, Equatable, Sendable {
  /// Not JSON, a missing field, a wrong type or an unknown message type.
  case invalidMessage
  case unsupportedVersion
  case tooLarge
  /// A decoded window that the recognition checks refuse.
  case invalidResult
}

/// `GET /v1/remote/identity`.
public struct RemoteServerIdentity: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let server: String
  public let protocolVersions: [Int]
  public let suite: String
  public let serverKey: String
  public let fingerprint: String

  public enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case server
    case protocolVersions = "protocol_versions"
    case suite
    case serverKey = "server_key"
    case fingerprint
  }

  /// The 32-byte X25519 key, or nil when the response is not a v1 identity.
  public func validatedKey() -> Data? {
    guard schemaVersion == RemoteProtocol.schemaVersion,
      protocolVersions.contains(RemoteProtocol.channelVersion), suite == RemoteProtocol.suite,
      let key = Data(base64URL: serverKey), key.count == 32,
      fingerprint == RemoteServerIdentity.fingerprint(of: key)
    else { return nil }
    return key
  }

  /// First 16 bytes of SHA-256 over the raw key, as eight groups of four hex digits.
  public static func fingerprint(of key: Data) -> String {
    let hex = Array(SHA256Digest.hex(key).prefix(32))
    return stride(from: 0, to: 32, by: 4).map { String(hex[$0..<$0 + 4]) }.joined(separator: "-")
  }

  public init(
    schemaVersion: Int, server: String, protocolVersions: [Int], suite: String, serverKey: String,
    fingerprint: String
  ) {
    self.schemaVersion = schemaVersion
    self.server = server
    self.protocolVersions = protocolVersions
    self.suite = suite
    self.serverKey = serverKey
    self.fingerprint = fingerprint
  }
}

public enum RemoteHelloPurpose: String, Codable, Sendable {
  case enroll, refresh, session
}

public struct RemoteHello: Encodable, Sendable {
  public let schemaVersion = RemoteProtocol.schemaVersion
  public let type = "hello"
  public let replyKey: String
  public let purpose: RemoteHelloPurpose
  public var accessToken: String?

  public enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case type
    case replyKey = "reply_key"
    case purpose
    case accessToken = "access_token"
  }

  public init(replyKey: String, purpose: RemoteHelloPurpose, accessToken: String? = nil) {
    self.replyKey = replyKey
    self.purpose = purpose
    self.accessToken = accessToken
  }
}

/// Dictionary terms for one dictation (FR-014). The server uses them for that session only.
public struct RemoteBoost: Codable, Sendable, Equatable {
  public struct Term: Codable, Sendable, Equatable {
    public let entryID: String
    public let canonical: String
    public enum CodingKeys: String, CodingKey {
      case entryID = "entry_id"
      case canonical
    }

    public init(entryID: String, canonical: String) {
      self.entryID = entryID
      self.canonical = canonical
    }
  }
  public let terms: [Term]
  public let governed: [String]

  /// The first 256 terms and 1,024 governed spellings that fit the wire limits.
  public init?(_ boost: VocabularyBoostTerms?) {
    guard let boost else { return nil }
    let fits = { (text: String) in text.utf8.count <= RemoteProtocol.maximumTermBytes }
    terms = boost.terms.filter { fits($0.entryID) && fits($0.canonical) }
      .prefix(RemoteProtocol.maximumBoostTerms)
      .map { Term(entryID: $0.entryID, canonical: $0.canonical) }
    governed = boost.governed.filter(fits).sorted().prefix(RemoteProtocol.maximumGovernedSpellings)
      .map { $0 }
    guard !terms.isEmpty else { return nil }
  }

  public init(terms: [Term], governed: [String]) {
    self.terms = terms
    self.governed = governed
  }
}

/// A message the app sends after `ready`.
public enum RemoteClientMessage: Sendable, Equatable {
  case enroll(
    op: Int, provider: IdentityProvider, idToken: String, deviceName: String, deviceKey: Data,
    signature: Data)
  case refresh(op: Int, refreshToken: String, signature: Data)
  case dictationStart(op: Int, boost: RemoteBoost?)
  case dictationEnd(op: Int, totalSamples: Int)
  case dictationCancel(op: Int)
  /// `request` is the unchanged rewrite request JSON (v1 or v2).
  case rewrite(op: Int, request: Data)
  /// Feature 018: one fragment of the analysis request JSON, then the closing `analysis`.
  case analysisPart(op: Int, index: Int, data: String)
  case analysis(op: Int, parts: Int, bytes: Int, sha256: String)
  /// A live-preview window of `sampleCount` s16le samples, sent next as kind-0x02 frames.
  case liveWindow(op: Int, sampleCount: Int, language: String?)
  /// A meeting job of `sampleCount` s16le samples; options per kind (contract table).
  case meetingJob(op: Int, job: RemoteMeetingJob)
  case meetingCancel(op: Int)
  /// A handed-off meeting: upload, start, poll, download or delete (one reply each).
  case handoff(op: Int, request: RemoteHandoffRequest)

  public func encoded() throws -> Data {
    var object: [String: Any] = ["schema_version": RemoteProtocol.schemaVersion]
    switch self {
    case .enroll(let op, let provider, let idToken, let deviceName, let deviceKey, let signature):
      object.merge([
        "type": "enroll", "op": op, "provider": provider.rawValue, "id_token": idToken,
        "device_name": Self.deviceName(deviceName), "device_key": deviceKey.base64URL,
        "signature": signature.base64URL,
      ]) { $1 }
    case .refresh(let op, let refreshToken, let signature):
      object.merge([
        "type": "refresh", "op": op, "refresh_token": refreshToken,
        "signature": signature.base64URL,
      ]) { $1 }
    case .dictationStart(let op, let boost):
      object.merge(["type": "dictation_start", "op": op, "format": "f32le", "sample_rate": 16_000])
      { $1 }
      if let boost {
        object["boost"] = [
          "terms": boost.terms.map { ["entry_id": $0.entryID, "canonical": $0.canonical] },
          "governed": boost.governed,
        ]
      }
    case .dictationEnd(let op, let totalSamples):
      object.merge(["type": "dictation_end", "op": op, "total_samples": totalSamples]) { $1 }
    case .dictationCancel(let op):
      object.merge(["type": "dictation_cancel", "op": op]) { $1 }
    case .rewrite(let op, let request):
      let parsed = try JSONSerialization.jsonObject(with: request)
      object.merge(["type": "rewrite", "op": op, "request": parsed]) { $1 }
    case .analysisPart(let op, let index, let data):
      object.merge(["type": "analysis_part", "op": op, "index": index, "data": data]) { $1 }
    case .analysis(let op, let parts, let bytes, let sha256):
      object.merge([
        "type": "analysis", "op": op, "parts": parts, "bytes": bytes, "sha256": sha256,
      ]) { $1 }
    case .liveWindow(let op, let sampleCount, let language):
      object.merge([
        "type": "live_window", "op": op, "sample_count": sampleCount, "format": "s16le",
      ]) { $1 }
      if let language { object["language"] = language }
    case .meetingJob(let op, let job):
      object.merge([
        "type": "meeting_job", "op": op, "kind": job.kind.rawValue,
        "sample_count": job.sampleCount, "format": "s16le",
      ]) { $1 }
      if let language = job.language { object["language"] = language }
      if let terms = job.vocabularyTerms { object["vocabulary_terms"] = terms }
      if let pipeline = job.pipeline { object["pipeline"] = pipeline }
      if let speakers = job.numSpeakers { object["num_speakers"] = speakers }
    case .meetingCancel(let op):
      object.merge(["type": "meeting_cancel", "op": op]) { $1 }
    case .handoff(let op, let request):
      object.merge(["type": "handoff", "op": op, "action": request.action.rawValue]) { $1 }
      if let meeting = request.meeting { object["meeting"] = meeting.uuidString }
      if let name = request.name { object["name"] = name }
      if let offset = request.offset { object["offset"] = offset }
      if let data = request.data { object["data"] = data.base64URL }
      if let sha256 = request.sha256 { object["sha256"] = sha256 }
      if request.partial { object["partial"] = true }
      if request.copy { object["copy"] = true }
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard data.count <= RemoteProtocol.maximumControlBytes else {
      throw RemoteProtocolError.tooLarge
    }
    return data
  }

  /// At most 64 UTF-8 bytes with control characters removed, cut on a character boundary.
  public static func deviceName(_ name: String) -> String {
    var result = ""
    for character in name
    where !character.unicodeScalars.contains(where: {
      CharacterSet.controlCharacters.contains($0)
    }) {
      guard
        result.utf8.count + String(character).utf8.count <= RemoteProtocol.maximumDeviceNameBytes
      else { break }
      result.append(character)
    }
    return result
  }
}

/// One recognized window: the wire form of `TranscriptionWindow` and `RecognitionEvidence`.
public struct RemoteWindowResult: Decodable, Sendable {
  public struct Token: Codable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
      self.text = text
      self.start = start
      self.end = end
    }
  }
  public struct Evidence: Codable, Sendable {
    public let text: String
    public let samples: Int
    public let paddedSamples: Int
    public let timingsAvailable: Bool
    public let tokens: [RecognitionEvidence.Token]
    public enum CodingKeys: String, CodingKey {
      case text, samples
      case paddedSamples = "padded_samples"
      case timingsAvailable = "timings_available"
      case tokens
    }

    public init(
      text: String, samples: Int, paddedSamples: Int, timingsAvailable: Bool,
      tokens: [RecognitionEvidence.Token]
    ) {
      self.text = text
      self.samples = samples
      self.paddedSamples = paddedSamples
      self.timingsAvailable = timingsAvailable
      self.tokens = tokens
    }
  }
  public struct Hint: Codable, Sendable {
    public let source: String
    public let canonical: String
    public let entryID: String
    public enum CodingKeys: String, CodingKey {
      case source, canonical
      case entryID = "entry_id"
    }

    public init(source: String, canonical: String, entryID: String) {
      self.source = source
      self.canonical = canonical
      self.entryID = entryID
    }
  }
  public let op: Int
  public let index: Int
  public let sampleStart: Int
  public let sampleCount: Int
  public let text: String
  public let tokens: [Token]
  public let evidence: Evidence?
  public let boostHints: [Hint]
  public let recognitionMs: Int

  public enum CodingKeys: String, CodingKey {
    case op, index
    case sampleStart = "sample_start"
    case sampleCount = "sample_count"
    case text, tokens, evidence
    case boostHints = "boost_hints"
    case recognitionMs = "recognition_ms"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    op = try container.decode(Int.self, forKey: .op)
    index = try container.decode(Int.self, forKey: .index)
    sampleStart = try container.decode(Int.self, forKey: .sampleStart)
    sampleCount = try container.decode(Int.self, forKey: .sampleCount)
    text = try container.decode(String.self, forKey: .text)
    tokens = try container.decode([Token].self, forKey: .tokens)
    evidence = try container.decodeIfPresent(Evidence.self, forKey: .evidence)
    boostHints = try container.decodeIfPresent([Hint].self, forKey: .boostHints) ?? []
    recognitionMs = try container.decode(Int.self, forKey: .recognitionMs)
  }

  /// Field mapping of FR-016. Hints are dropped when the server said boosting did not run.
  public func window(boostingRan: Bool = true) -> TranscriptionWindow {
    TranscriptionWindow(
      text: text, tokens: tokens.map { .init(text: $0.text, start: $0.start, end: $0.end) },
      evidence: evidence.map {
        RecognitionEvidence(
          text: $0.text, samples: $0.samples, paddedSamples: $0.paddedSamples,
          timingsAvailable: $0.timingsAvailable, tokens: $0.tokens)
      },
      boostHints: boostingRan
        ? boostHints.map {
          VocabularyBoostHint(source: $0.source, canonical: $0.canonical, entryID: $0.entryID)
        } : [])
  }

  public var recognitionSeconds: Double { Double(max(0, recognitionMs)) / 1_000 }
}

/// Collects window results for one dictation and applies the local admission checks
/// as they arrive, so a bad result fails the session instead of the transcript.
public struct RemoteWindowCollector: Sendable {
  public private(set) var windows: [Int: PrefetchedWindow] = [:]
  private var admission = RecognitionAdmission(
    strideSamples: 239_360, processingReserveBytes: 24_576)
  public let boostingRan: Bool

  public init(boostingRan: Bool) { self.boostingRan = boostingRan }

  public var count: Int { windows.count }

  /// Throws `invalidResult` for an out-of-order, oversized or inadmissible window.
  public mutating func append(_ result: RemoteWindowResult) throws {
    guard result.index == windows.count, result.index < RemoteProtocol.maximumWindows,
      result.sampleStart == result.index * RemoteProtocol.windowSamples,
      (1...RemoteProtocol.windowSamples).contains(result.sampleCount),
      result.sampleStart + result.sampleCount <= RemoteProtocol.maximumSessionSamples
    else { throw RemoteProtocolError.invalidResult }
    let window = result.window(boostingRan: boostingRan)
    do {
      try admission.append(window, sampleStart: result.sampleStart, sampleCount: result.sampleCount)
    } catch { throw RemoteProtocolError.invalidResult }
    windows[result.sampleStart] = PrefetchedWindow(
      window: window, recognitionSeconds: result.recognitionSeconds)
  }

  /// Whether the collected windows cover exactly `total` samples.
  public func covers(_ total: Int) -> Bool {
    let expected = total == 0 ? 0 : (total - 1) / RemoteProtocol.windowSamples + 1
    return windows.count == expected
  }
}

/// A message flowd sends.
public enum RemoteServerMessage: Sendable {
  case ready(RemoteCapabilities)
  case enrolled(op: Int, state: RemoteEnrollmentState, refreshToken: String?)
  case tokens(op: Int, accessToken: String, expiresIn: Int, refreshToken: String)
  case dictationAccepted(op: Int, windowSamples: Int, model: RemoteModelIdentity)
  case windowResult(RemoteWindowResult)
  case progress(op: Int, state: String)
  case dictationComplete(op: Int, windows: Int)
  case cancelled(op: Int)
  /// The rewrite event object, re-encoded, exactly as one NDJSON line of the HTTP route.
  case rewriteEvent(op: Int, event: Data)
  /// Feature 018: one fragment of an analysis event line too large for one message.
  case analysisEventPart(op: Int, index: Int, data: String)
  /// An analysis event inline (`event`), or closing its fragments (`parts`, `sha256`).
  case analysisEvent(op: Int, event: Data?, parts: Int?, sha256: String?)
  case liveResult(op: Int, window: TranscriptionWindow, recognitionMs: Int)
  case meetingProgress(op: Int, state: String, position: Int?)
  case meetingResult(
    op: Int, result: RemoteMeetingResult, processingMs: Int, model: RemoteCapabilities.Model)
  case handoffReply(op: Int, reply: RemoteHandoffReply)
  case error(op: Int?, code: RemoteErrorCode)

  public var op: Int? {
    switch self {
    case .ready: nil
    case .enrolled(let op, _, _), .tokens(let op, _, _, _), .dictationAccepted(let op, _, _),
      .progress(let op, _), .dictationComplete(let op, _), .cancelled(let op),
      .rewriteEvent(let op, _), .analysisEventPart(let op, _, _), .analysisEvent(let op, _, _, _),
      .liveResult(let op, _, _), .meetingProgress(let op, _, _), .meetingResult(let op, _, _, _),
      .handoffReply(let op, _):
      op
    case .windowResult(let result): result.op
    case .error(let op, _): op
    }
  }

  public static func decode(_ data: Data) throws -> RemoteServerMessage {
    guard data.count <= RemoteProtocol.maximumControlBytes else {
      throw RemoteProtocolError.tooLarge
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = integer(object["schema_version"]), let type = object["type"] as? String
    else { throw RemoteProtocolError.invalidMessage }
    guard version == RemoteProtocol.schemaVersion else {
      throw RemoteProtocolError.unsupportedVersion
    }
    let decoder = JSONDecoder()
    func op() throws -> Int {
      guard let op = integer(object["op"]), (1...Int(Int32.max)).contains(op) else {
        throw RemoteProtocolError.invalidMessage
      }
      return op
    }
    func string(_ key: String) throws -> String {
      guard let value = object[key] as? String else { throw RemoteProtocolError.invalidMessage }
      return value
    }
    func int(_ key: String) throws -> Int {
      guard let value = integer(object[key]) else { throw RemoteProtocolError.invalidMessage }
      return value
    }
    do {
      switch type {
      case "ready": return .ready(try RemoteCapabilities.ready(object["capabilities"]))
      case "enrolled":
        guard let state = RemoteEnrollmentState(rawValue: try string("state")) else {
          throw RemoteProtocolError.invalidMessage
        }
        let refresh = object["refresh_token"] as? String
        // A rejected identity gets no refresh token; every other state gets one.
        guard (state == .rejected) == (refresh == nil) else {
          throw RemoteProtocolError.invalidMessage
        }
        return .enrolled(op: try op(), state: state, refreshToken: refresh)
      case "tokens":
        return .tokens(
          op: try op(), accessToken: try string("access_token"), expiresIn: try int("expires_in"),
          refreshToken: try string("refresh_token"))
      case "dictation_accepted":
        guard let model = object["model"], try int("window_samples") == RemoteProtocol.windowSamples
        else { throw RemoteProtocolError.invalidMessage }
        return .dictationAccepted(
          op: try op(), windowSamples: try int("window_samples"),
          model: try decoder.decode(
            RemoteModelIdentity.self, from: JSONSerialization.data(withJSONObject: model)))
      case "window_result":
        _ = try op()
        return .windowResult(try decoder.decode(RemoteWindowResult.self, from: data))
      case "progress":
        let state = try string("state")
        guard ["queued", "recognizing"].contains(state) else {
          throw RemoteProtocolError.invalidMessage
        }
        return .progress(op: try op(), state: state)
      case "dictation_complete":
        let windows = try int("windows")
        guard (0...RemoteProtocol.maximumWindows).contains(windows) else {
          throw RemoteProtocolError.invalidMessage
        }
        return .dictationComplete(op: try op(), windows: windows)
      case "cancelled": return .cancelled(op: try op())
      case "rewrite_event":
        guard let event = object["event"] as? [String: Any] else {
          throw RemoteProtocolError.invalidMessage
        }
        return .rewriteEvent(
          op: try op(), event: try JSONSerialization.data(withJSONObject: event))
      case "analysis_event_part":
        let index = try int("index")
        guard index >= 0 else { throw RemoteProtocolError.invalidMessage }
        return .analysisEventPart(op: try op(), index: index, data: try string("data"))
      case "analysis_event":
        if let event = object["event"] as? [String: Any] {
          guard object["parts"] == nil, object["sha256"] == nil else {
            throw RemoteProtocolError.invalidMessage
          }
          return .analysisEvent(
            op: try op(), event: try JSONSerialization.data(withJSONObject: event), parts: nil,
            sha256: nil)
        }
        let parts = try int("parts")
        let sha256 = try string("sha256")
        guard parts >= 1, sha256.utf8.count == 64 else { throw RemoteProtocolError.invalidMessage }
        return .analysisEvent(op: try op(), event: nil, parts: parts, sha256: sha256)
      case "live_result":
        guard let window = object["window"] else { throw RemoteProtocolError.invalidMessage }
        let decoded = try decoder.decode(
          RemoteLiveWindow.self, from: JSONSerialization.data(withJSONObject: window))
        return .liveResult(
          op: try op(), window: decoded.window, recognitionMs: try int("recognition_ms"))
      case "meeting_progress":
        let state = try string("state")
        guard ["queued", "running"].contains(state) else {
          throw RemoteProtocolError.invalidMessage
        }
        return .meetingProgress(op: try op(), state: state, position: integer(object["position"]))
      case "meeting_result":
        guard let kind = RemoteMeetingJob.Kind(rawValue: try string("kind")),
          let result = object["result"] as? [String: Any], let model = object["model"]
        else { throw RemoteProtocolError.invalidMessage }
        return .meetingResult(
          op: try op(), result: try RemoteMeetingResult.decode(kind: kind, result),
          processingMs: try int("processing_ms"),
          model: try decoder.decode(
            RemoteCapabilities.Model.self, from: JSONSerialization.data(withJSONObject: model)))
      case "handoff_reply":
        return .handoffReply(op: try op(), reply: try RemoteHandoffReply(object))
      case "error":
        guard let code = RemoteErrorCode(rawValue: try string("code")) else {
          throw RemoteProtocolError.invalidMessage
        }
        let op = object["op"] == nil ? nil : try op()
        return .error(op: op, code: code)
      default: throw RemoteProtocolError.invalidMessage
      }
    } catch let error as RemoteProtocolError {
      throw error
    } catch let error as VoiceEmbeddingFailure {
      throw error
    } catch {
      throw RemoteProtocolError.invalidMessage
    }
  }
}

/// Feature 018: one meeting model call for the server's meeting worker.
public struct RemoteMeetingJob: Sendable, Equatable {
  public enum Kind: String, Sendable, CaseIterable {
    case transcribe, diarize, embed
  }
  public let kind: Kind
  public let sampleCount: Int
  /// Transcribe only.
  public var language: String?
  public var vocabularyTerms: [String]?
  public var pipeline: String?
  /// Diarize only.
  public var numSpeakers: Int?

  public init(
    kind: Kind, sampleCount: Int, language: String? = nil, vocabularyTerms: [String]? = nil,
    pipeline: String? = nil, numSpeakers: Int? = nil
  ) {
    self.kind = kind
    self.sampleCount = sampleCount
    self.language = language
    self.vocabularyTerms = vocabularyTerms
    self.pipeline = pipeline
    self.numSpeakers = numSpeakers
  }
}

/// `live_result.window`: the dictation window form without boost hints.
private struct RemoteLiveWindow: Decodable {
  let text: String
  let tokens: [RemoteWindowResult.Token]
  let evidence: RemoteWindowResult.Evidence?

  var window: TranscriptionWindow {
    TranscriptionWindow(
      text: text, tokens: tokens.map { .init(text: $0.text, start: $0.start, end: $0.end) },
      evidence: evidence.map {
        RecognitionEvidence(
          text: $0.text, samples: $0.samples, paddedSamples: $0.paddedSamples,
          timingsAvailable: $0.timingsAvailable, tokens: $0.tokens)
      })
  }
}

/// `meeting_result.result` mapped to the types the local runtimes return.
public enum RemoteMeetingResult: Sendable {
  case transcription(TranscriptionWindow, language: String?, retryDepth: Int)
  case diarization(DiarizationWindowResult)
  case embedding(VoiceEmbedding)

  private struct Transcribed: Decodable {
    let text: String
    let tokens: [RemoteWindowResult.Token]
    let language: String?
    let retryDepth: Int
    enum CodingKeys: String, CodingKey {
      case text, tokens, language
      case retryDepth = "retry_depth"
    }
  }
  private struct Diarized: Decodable {
    struct Turn: Decodable {
      public let cluster: Int
      public let start: Double
      public let end: Double
      public let quality: Float?
    }
    struct Centroid: Decodable {
      public let cluster: Int
      public let vector: [Float]
    }
    let turns: [Turn]
    let centroids: [Centroid]
  }
  private struct Embedded: Decodable {
    let vector: [Float]
    let speechSeconds: Double
    enum CodingKeys: String, CodingKey {
      case vector
      case speechSeconds = "speech_seconds"
    }
  }

  public static func decode(kind: RemoteMeetingJob.Kind, _ object: [String: Any]) throws
    -> RemoteMeetingResult
  {
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    switch kind {
    case .transcribe:
      let value = try decoder.decode(Transcribed.self, from: data)
      return .transcription(
        TranscriptionWindow(
          text: value.text,
          tokens: value.tokens.map { .init(text: $0.text, start: $0.start, end: $0.end) }),
        language: value.language, retryDepth: value.retryDepth)
    case .diarize:
      let value = try decoder.decode(Diarized.self, from: data)
      let result = DiarizationWindowResult(
        turns: value.turns.map {
          .init(
            cluster: $0.cluster, startSeconds: $0.start, endSeconds: $0.end, quality: $0.quality)
        },
        centroids: Dictionary(value.centroids.map { ($0.cluster, $0.vector) }) { $1 })
      guard result.isValid else { throw RemoteProtocolError.invalidResult }
      return .diarization(result)
    case .embed:
      let value = try decoder.decode(Embedded.self, from: data)
      // The worker's answer for a region without speech.
      if value.vector.isEmpty { throw VoiceEmbeddingFailure.noSpeech }
      let embedding = VoiceEmbedding(vector: value.vector, speechSeconds: value.speechSeconds)
      guard embedding.isValid else { throw RemoteProtocolError.invalidResult }
      return .embedding(embedding)
    }
  }
}

/// A JSON integer; booleans and fractions are not integers here.
private func integer(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    return nil
  }
  return value as? Int
}

/// A device's combined state as the server reports it at enrollment.
public enum RemoteEnrollmentState: String, Codable, Sendable {
  case pending, approved, rejected
}

public enum SHA256Digest {
  public static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension Data {
  /// Unpadded base64url (RFC 4648 §5), as every key and signature on the wire.
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  public init?(base64URL text: String) {
    guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}

/// `handoff`: one action on a meeting handed to the server (or `list`, on none).
public struct RemoteHandoffRequest: Sendable, Equatable {
  public enum Action: String, Sendable { case put, start, list, get, delete, release }
  public var action: Action
  public var meeting: UUID?
  public var name: String?
  public var offset: Int?
  public var data: Data?
  public var sha256: String?
  /// `start` only (Feature 020): process the audio uploaded so far, then back to `receiving`.
  public var partial = false
  /// `put` and `start` only (Feature 020): keep the result for the owner's Mac after `release`.
  public var copy = false

  public init(
    action: Action, meeting: UUID? = nil, name: String? = nil, offset: Int? = nil,
    data: Data? = nil, sha256: String? = nil, partial: Bool = false, copy: Bool = false
  ) {
    self.action = action
    self.meeting = meeting
    self.name = name
    self.offset = offset
    self.data = data
    self.sha256 = sha256
    self.partial = partial
    self.copy = copy
  }
}

/// `handoff_reply`. `state` is absent only on a `list` reply, which has `meetings`.
public struct RemoteHandoffReply: Sendable, Equatable {
  public enum State: String, Sendable { case receiving, queued, processing, done, failed, missing }
  public struct Entry: Sendable, Equatable {
    public let meeting: UUID
    public let state: State
    public let detail: String?
    /// `processing` only: percent done, 0...100, once the processor has reported.
    public var progress: Int? = nil
    /// Feature 020: `receiving` after a partial run, milliseconds transcribed so far.
    public var transcribedMS: Int? = nil
    /// Feature 020: sent by this device, a Mac copy was asked for, the sender has its result.
    public var mine = false
    public var copy = false
    public var released = false

    public init(
      meeting: UUID, state: State, detail: String?, progress: Int? = nil, transcribedMS: Int? = nil,
      mine: Bool = false, copy: Bool = false, released: Bool = false
    ) {
      self.meeting = meeting
      self.state = state
      self.detail = detail
      self.progress = progress
      self.transcribedMS = transcribedMS
      self.mine = mine
      self.copy = copy
      self.released = released
    }
  }
  public var state: State?
  public var meeting: UUID?
  public var name: String?
  public var offset: Int?
  public var data: Data?
  public var size: Int?
  public var sha256: String?
  public var detail: String?
  public var meetings: [Entry]?

  public init(
    state: State? = nil, meeting: UUID? = nil, name: String? = nil, offset: Int? = nil,
    data: Data? = nil, size: Int? = nil, sha256: String? = nil, detail: String? = nil,
    meetings: [Entry]? = nil
  ) {
    self.state = state
    self.meeting = meeting
    self.name = name
    self.offset = offset
    self.data = data
    self.size = size
    self.sha256 = sha256
    self.detail = detail
    self.meetings = meetings
  }

  public init(_ object: [String: Any]) throws {
    func state(_ value: Any?) throws -> State? {
      guard let value else { return nil }
      guard let raw = value as? String, let state = State(rawValue: raw) else {
        throw RemoteProtocolError.invalidMessage
      }
      return state
    }
    func uuid(_ value: Any?) throws -> UUID? {
      guard let value else { return nil }
      guard let raw = value as? String, let id = UUID(uuidString: raw) else {
        throw RemoteProtocolError.invalidMessage
      }
      return id
    }
    func count(_ key: String) throws -> Int? {
      guard let value = object[key] else { return nil }
      guard let number = integer(value), number >= 0 else {
        throw RemoteProtocolError.invalidMessage
      }
      return number
    }
    self.state = try state(object["state"])
    meeting = try uuid(object["meeting"])
    name = object["name"] as? String
    offset = try count("offset")
    size = try count("size")
    sha256 = object["sha256"] as? String
    detail = object["detail"] as? String
    if let text = object["data"] {
      guard let text = text as? String, let decoded = Data(base64URL: text) else {
        throw RemoteProtocolError.invalidMessage
      }
      data = decoded
    }
    if let list = object["meetings"] {
      guard let list = list as? [[String: Any]] else { throw RemoteProtocolError.invalidMessage }
      meetings = try list.map { entry in
        guard let id = try uuid(entry["meeting"]), let state = try state(entry["state"]) else {
          throw RemoteProtocolError.invalidMessage
        }
        let detail = entry["detail"] as? String
        guard detail == nil || state == .failed || state == .receiving else {
          throw RemoteProtocolError.invalidMessage
        }
        // An out-of-range percent is dropped rather than failing the whole list.
        let progress = entry["progress"].flatMap(integer).flatMap {
          (0...100).contains($0) ? $0 : nil
        }
        let transcribed = entry["transcribed_ms"].flatMap(integer).flatMap { $0 >= 0 ? $0 : nil }
        return Entry(
          meeting: id, state: state, detail: detail, progress: progress,
          transcribedMS: transcribed, mine: entry["mine"] as? Bool ?? false,
          copy: entry["copy"] as? Bool ?? false, released: entry["released"] as? Bool ?? false)
      }
    }
    guard (self.state == nil) == (meetings != nil),
      detail == nil || self.state == .failed || self.state == .receiving
    else {
      throw RemoteProtocolError.invalidMessage
    }
  }
}
