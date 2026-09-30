import CryptoKit
import Foundation
import LocalFlowSpeech

/// Control messages of remote channel v1 (`contracts/remote-channel.md`,
/// `protocol/schemas/remote-*.schema.json`). Audio travels in kind-0x01 frames and
/// never appears here.
enum RemoteProtocol {
  static let schemaVersion = 1
  static let channelVersion = 1
  static let suite = "x25519-hkdfsha256-chacha20poly1305"
  static let maximumControlBytes = 65_536
  static let maximumFrameSamples = 16_000
  static let windowSamples = WindowedTranscriber.productionWindowSamples
  /// 180 s of 16 kHz audio: the dictation limit, so at most 13 windows.
  static let maximumSessionSamples = 2_880_000
  static let maximumWindows = 14
  static let maximumBoostTerms = 256
  static let maximumGovernedSpellings = 1_024
  static let maximumTermBytes = 128
  static let maximumDeviceNameBytes = 64
}

/// Failure reason codes a dictation records (`server_failure`, FR-019).
public enum RemoteFailureReason: String, Codable, Sendable, CaseIterable, Error {
  case unreachable, timeout, busy, unauthorized
  case notApproved = "not_approved"
  case revoked
  case pinMismatch = "pin_mismatch"
  case workerUnavailable = "worker_unavailable"
  case protocolError = "protocol_error"
  case limitExceeded = "limit_exceeded"
  case pendingRetry = "pending_retry"
}

/// Error codes flowd sends in `error` messages.
enum RemoteErrorCode: String, Codable, Sendable, CaseIterable {
  case unauthorized
  case tokenExpired = "token_expired"
  case notApproved = "not_approved"
  case revoked, busy
  case invalidMessage = "invalid_message"
  case unsupportedVersion = "unsupported_version"
  case limitExceeded = "limit_exceeded"
  case workerUnavailable = "worker_unavailable"
  case `internal`

  /// The code a dictation records when the server answered with this error.
  var failureReason: RemoteFailureReason {
    switch self {
    case .unauthorized, .tokenExpired: .unauthorized
    case .notApproved: .notApproved
    case .revoked: .revoked
    case .busy: .busy
    case .limitExceeded: .limitExceeded
    case .workerUnavailable: .workerUnavailable
    case .invalidMessage, .unsupportedVersion, .internal: .protocolError
    }
  }
}

enum RemoteProtocolError: Error, Equatable, Sendable {
  /// Not JSON, a missing field, a wrong type or an unknown message type.
  case invalidMessage
  case unsupportedVersion
  case tooLarge
  /// A decoded window that the recognition checks refuse.
  case invalidResult
}

/// `GET /v1/remote/identity`.
struct RemoteServerIdentity: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let server: String
  let protocolVersions: [Int]
  let suite: String
  let serverKey: String
  let fingerprint: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case server
    case protocolVersions = "protocol_versions"
    case suite
    case serverKey = "server_key"
    case fingerprint
  }

  /// The 32-byte X25519 key, or nil when the response is not a v1 identity.
  func validatedKey() -> Data? {
    guard schemaVersion == RemoteProtocol.schemaVersion,
      protocolVersions.contains(RemoteProtocol.channelVersion), suite == RemoteProtocol.suite,
      let key = Data(base64URL: serverKey), key.count == 32,
      fingerprint == RemoteServerIdentity.fingerprint(of: key)
    else { return nil }
    return key
  }

  /// First 16 bytes of SHA-256 over the raw key, as eight groups of four hex digits.
  static func fingerprint(of key: Data) -> String {
    let hex = Array(SHA256Digest.hex(key).prefix(32))
    return stride(from: 0, to: 32, by: 4).map { String(hex[$0..<$0 + 4]) }.joined(separator: "-")
  }
}

enum RemoteHelloPurpose: String, Codable, Sendable {
  case enroll, refresh, session
}

struct RemoteHello: Encodable, Sendable {
  let schemaVersion = RemoteProtocol.schemaVersion
  let type = "hello"
  let replyKey: String
  let purpose: RemoteHelloPurpose
  var accessToken: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case type
    case replyKey = "reply_key"
    case purpose
    case accessToken = "access_token"
  }
}

/// Dictionary terms for one dictation (FR-014). The server uses them for that session only.
struct RemoteBoost: Codable, Sendable, Equatable {
  struct Term: Codable, Sendable, Equatable {
    let entryID: String
    let canonical: String
    enum CodingKeys: String, CodingKey {
      case entryID = "entry_id"
      case canonical
    }
  }
  let terms: [Term]
  let governed: [String]

  /// The first 256 terms and 1,024 governed spellings that fit the wire limits.
  init?(_ boost: VocabularyBoostTerms?) {
    guard let boost else { return nil }
    let fits = { (text: String) in text.utf8.count <= RemoteProtocol.maximumTermBytes }
    terms = boost.terms.filter { fits($0.entryID) && fits($0.canonical) }
      .prefix(RemoteProtocol.maximumBoostTerms)
      .map { Term(entryID: $0.entryID, canonical: $0.canonical) }
    governed = boost.governed.filter(fits).sorted().prefix(RemoteProtocol.maximumGovernedSpellings)
      .map { $0 }
    guard !terms.isEmpty else { return nil }
  }

  init(terms: [Term], governed: [String]) {
    self.terms = terms
    self.governed = governed
  }
}

/// A message the app sends after `ready`.
enum RemoteClientMessage: Sendable, Equatable {
  case enroll(
    op: Int, provider: IdentityProvider, idToken: String, deviceName: String, deviceKey: Data,
    signature: Data)
  case refresh(op: Int, refreshToken: String, signature: Data)
  case dictationStart(op: Int, boost: RemoteBoost?)
  case dictationEnd(op: Int, totalSamples: Int)
  case dictationCancel(op: Int)
  /// `request` is the unchanged rewrite request JSON (v1 or v2).
  case rewrite(op: Int, request: Data)

  func encoded() throws -> Data {
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
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard data.count <= RemoteProtocol.maximumControlBytes else {
      throw RemoteProtocolError.tooLarge
    }
    return data
  }

  /// At most 64 UTF-8 bytes with control characters removed, cut on a character boundary.
  static func deviceName(_ name: String) -> String {
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

/// The server's model identity from `dictation_accepted` (and the worker's `ready`).
struct RemoteModelIdentity: Codable, Sendable, Equatable {
  let engine: String
  let modelID: String
  let modelRevision: String
  let manifestHash: String
  let sdk: String
  /// Absent when the server has no term booster: boosting did not run.
  let booster: String?
  let workerBuild: String?

  enum CodingKeys: String, CodingKey {
    case engine
    case modelID = "model_id"
    case modelRevision = "model_revision"
    case manifestHash = "manifest_hash"
    case sdk, booster
    case workerBuild = "worker_build"
  }

  var boostingRan: Bool { booster != nil }
}

/// One recognized window: the wire form of `TranscriptionWindow` and `RecognitionEvidence`.
struct RemoteWindowResult: Decodable, Sendable {
  struct Token: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
  }
  struct Evidence: Codable, Sendable {
    let text: String
    let samples: Int
    let paddedSamples: Int
    let timingsAvailable: Bool
    let tokens: [RecognitionEvidence.Token]
    enum CodingKeys: String, CodingKey {
      case text, samples
      case paddedSamples = "padded_samples"
      case timingsAvailable = "timings_available"
      case tokens
    }
  }
  struct Hint: Codable, Sendable {
    let source: String
    let canonical: String
    let entryID: String
    enum CodingKeys: String, CodingKey {
      case source, canonical
      case entryID = "entry_id"
    }
  }
  let op: Int
  let index: Int
  let sampleStart: Int
  let sampleCount: Int
  let text: String
  let tokens: [Token]
  let evidence: Evidence?
  let boostHints: [Hint]
  let recognitionMs: Int

  enum CodingKeys: String, CodingKey {
    case op, index
    case sampleStart = "sample_start"
    case sampleCount = "sample_count"
    case text, tokens, evidence
    case boostHints = "boost_hints"
    case recognitionMs = "recognition_ms"
  }

  init(from decoder: any Decoder) throws {
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
  func window(boostingRan: Bool = true) -> TranscriptionWindow {
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

  var recognitionSeconds: Double { Double(max(0, recognitionMs)) / 1_000 }
}

/// Collects window results for one dictation and applies the local admission checks
/// as they arrive, so a bad result fails the session instead of the transcript.
struct RemoteWindowCollector: Sendable {
  private(set) var windows: [Int: PrefetchedWindow] = [:]
  private var admission = RecognitionAdmission(
    strideSamples: 239_360, processingReserveBytes: 24_576)
  let boostingRan: Bool

  init(boostingRan: Bool) { self.boostingRan = boostingRan }

  var count: Int { windows.count }

  /// Throws `invalidResult` for an out-of-order, oversized or inadmissible window.
  mutating func append(_ result: RemoteWindowResult) throws {
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
  func covers(_ total: Int) -> Bool {
    let expected = total == 0 ? 0 : (total - 1) / RemoteProtocol.windowSamples + 1
    return windows.count == expected
  }
}

/// A message flowd sends.
enum RemoteServerMessage: Sendable {
  case ready
  case enrolled(op: Int, state: RemoteEnrollmentState, refreshToken: String?)
  case tokens(op: Int, accessToken: String, expiresIn: Int, refreshToken: String)
  case dictationAccepted(op: Int, windowSamples: Int, model: RemoteModelIdentity)
  case windowResult(RemoteWindowResult)
  case progress(op: Int, state: String)
  case dictationComplete(op: Int, windows: Int)
  case cancelled(op: Int)
  /// The rewrite event object, re-encoded, exactly as one NDJSON line of the HTTP route.
  case rewriteEvent(op: Int, event: Data)
  case error(op: Int?, code: RemoteErrorCode)

  var op: Int? {
    switch self {
    case .ready: nil
    case .enrolled(let op, _, _), .tokens(let op, _, _, _), .dictationAccepted(let op, _, _),
      .progress(let op, _), .dictationComplete(let op, _), .cancelled(let op),
      .rewriteEvent(let op, _):
      op
    case .windowResult(let result): result.op
    case .error(let op, _): op
    }
  }

  static func decode(_ data: Data) throws -> RemoteServerMessage {
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
      case "ready": return .ready
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
    } catch {
      throw RemoteProtocolError.invalidMessage
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
enum RemoteEnrollmentState: String, Codable, Sendable {
  case pending, approved, rejected
}

enum SHA256Digest {
  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension Data {
  /// Unpadded base64url (RFC 4648 §5), as every key and signature on the wire.
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL text: String) {
    guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}
