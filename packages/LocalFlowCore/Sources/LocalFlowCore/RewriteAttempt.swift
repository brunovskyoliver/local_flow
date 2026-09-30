import Foundation

/// Which text an insertion handed over: the faithful transcript or one attempt's output.
public enum DeliveredSource: String, Sendable, Codable, Equatable {
  case faithful, rewrite
}

/// What `recordOutcome` writes beside the delivery state: the source, the
/// attempt whose output was inserted, and the commit-to-handoff duration.
public struct RewriteDelivery: Sendable, Equatable {
  public let source: DeliveredSource
  public let attemptID: UUID?
  let durationMilliseconds: Int?
  public static let faithful = RewriteDelivery(
    source: .faithful, attemptID: nil, durationMilliseconds: nil)

  public init(source: DeliveredSource, attemptID: UUID?, durationMilliseconds: Int?) {
    self.source = source
    self.attemptID = attemptID
    self.durationMilliseconds = durationMilliseconds
  }
}

/// Input to `RewriteAttemptStoring.begin`: everything an admitted row needs
/// that the store cannot derive itself.
public struct RewriteAdmission: Sendable, Equatable {
  let transcriptionID: UUID
  let mode: RewriteMode
  let inputText: String
  let endpointOrigin: String
  let insecureOverride: Bool
  /// Feature 012: the snapshot hash when this attempt sends protocol v2; nil for v1.
  var contextHash: String? = nil

  public init(
    transcriptionID: UUID, mode: RewriteMode, inputText: String, endpointOrigin: String,
    insecureOverride: Bool, contextHash: String? = nil
  ) {
    self.transcriptionID = transcriptionID
    self.mode = mode
    self.inputText = inputText
    self.endpointOrigin = endpointOrigin
    self.insecureOverride = insecureOverride
    self.contextHash = contextHash
  }

  var protocolVersion: Int {
    contextHash == nil ? RewriteBounds.schemaVersion : RewriteBounds.contextSchemaVersion
  }

  /// Bytes reserved against the history quota while the attempt is pending.
  var reservedBytes: Int {
    inputText.utf8.count + RewriteBounds.maximumResultBytes(inputBytes: inputText.utf8.count)
  }
}

/// Persisted derivations of the five client instants plus content-free byte counts.
public struct RewriteSpans: Sendable, Equatable {
  public var durationMilliseconds: Int?
  public var firstByteMilliseconds: Int?
  public var networkMilliseconds: Int?
  public var requestBytes: Int?
  public var responseBytes: Int?

  static let none = RewriteSpans()
  public init(
    durationMilliseconds: Int? = nil, firstByteMilliseconds: Int? = nil,
    networkMilliseconds: Int? = nil, requestBytes: Int? = nil, responseBytes: Int? = nil
  ) {
    self.durationMilliseconds = durationMilliseconds
    self.firstByteMilliseconds = firstByteMilliseconds
    self.networkMilliseconds = networkMilliseconds
    self.requestBytes = requestBytes
    self.responseBytes = responseBytes
  }
}

/// Who produced a result; copied from the `result` event so every stored attempt
/// and every report is reproducible.
public struct RewriteIdentity: Sendable, Equatable {
  var serverName: String?
  var serverVersion: String?
  var backendKind: String?
  var backendModel: String?
  var promptVersion: Int?
  var shieldVersion: Int?
  static let unknown = RewriteIdentity()

  public init(
    serverName: String? = nil, serverVersion: String? = nil, backendKind: String? = nil,
    backendModel: String? = nil, promptVersion: Int? = nil, shieldVersion: Int? = nil
  ) {
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.backendKind = backendKind
    self.backendModel = backendModel
    self.promptVersion = promptVersion
    self.shieldVersion = shieldVersion
  }
  public init(result: RewriteResult) {
    self.init(
      serverName: result.serverName, serverVersion: result.serverVersion,
      backendKind: result.backendKind, backendModel: result.backendModel,
      promptVersion: result.promptVersion, shieldVersion: result.shieldVersion)
  }

  /// Grouping key for latency and metric reports.
  public var groupKey: String {
    "\(backendModel ?? "unknown")+p\(promptVersion.map(String.init) ?? "unknown")+s\(shieldVersion.map(String.init) ?? "unknown")"
  }
}

public enum RewriteAttemptState: String, Sendable, Codable, CaseIterable {
  case pending, succeeded, failed, cancelled
  case timedOut = "timed_out"
  var isTerminal: Bool { self != .pending }
}

/// One row of `rewrite_attempts`. Exists only for an admitted attempt.
public struct RewriteAttempt: Identifiable, Sendable, Equatable {
  public static let maximumPerDictation = 10
  public static let maximumPendingOverall = 2

  public let id: UUID
  public let transcriptionID: UUID
  public let ordinal: Int
  public let mode: RewriteMode
  public let state: RewriteAttemptState
  public let inputText: String
  let inputHash: String
  public let outputText: String?
  let outputHash: String?
  let unchanged: Bool
  public let failureCategory: RewriteFailureCategory?
  public let stale: Bool
  let startedAtMilliseconds: Int64
  public let spans: RewriteSpans
  let serverQueueMilliseconds: Int?
  let backendFirstTokenMilliseconds: Int?
  let backendMilliseconds: Int?
  let protocolVersion: Int
  public let identity: RewriteIdentity
  let endpointOrigin: String
  let insecureOverride: Bool
  public let delivered: Bool
  /// Feature 012: hash of the snapshot sent with a protocol v2 request; nil for v1.
  public var contextHash: String? = nil

  /// The text this attempt can deliver, or nil unless it succeeded.
  public var deliverableText: String? { state == .succeeded ? outputText : nil }
}
