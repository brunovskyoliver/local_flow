import Foundation

/// Which text an insertion handed over: the faithful transcript or one attempt's output.
public enum DeliveredSource: String, Sendable, Codable, Equatable {
  case faithful, rewrite
}

/// What `recordOutcome` writes beside the delivery state: the source, the
/// attempt whose output was inserted, and the commit-to-handoff duration.
struct RewriteDelivery: Sendable, Equatable {
  let source: DeliveredSource
  let attemptID: UUID?
  let durationMilliseconds: Int?
  static let faithful = RewriteDelivery(
    source: .faithful, attemptID: nil, durationMilliseconds: nil)
}

/// Input to `RewriteAttemptStoring.begin`: everything an admitted row needs
/// that the store cannot derive itself.
struct RewriteAdmission: Sendable, Equatable {
  let transcriptionID: UUID
  let mode: RewriteMode
  let inputText: String
  let endpointOrigin: String
  let insecureOverride: Bool

  /// Bytes reserved against the history quota while the attempt is pending.
  var reservedBytes: Int {
    inputText.utf8.count + RewriteBounds.maximumResultBytes(inputBytes: inputText.utf8.count)
  }
}

/// Persisted derivations of the five client instants plus content-free byte counts.
struct RewriteSpans: Sendable, Equatable {
  var durationMilliseconds: Int?
  var firstByteMilliseconds: Int?
  var networkMilliseconds: Int?
  var requestBytes: Int?
  var responseBytes: Int?
  static let none = RewriteSpans()
  init(
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
struct RewriteIdentity: Sendable, Equatable {
  var serverName: String?
  var serverVersion: String?
  var backendKind: String?
  var backendModel: String?
  var promptVersion: Int?
  var shieldVersion: Int?
  static let unknown = RewriteIdentity()

  init(
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
  init(result: RewriteResult) {
    self.init(
      serverName: result.serverName, serverVersion: result.serverVersion,
      backendKind: result.backendKind, backendModel: result.backendModel,
      promptVersion: result.promptVersion, shieldVersion: result.shieldVersion)
  }

  /// Grouping key for latency and metric reports.
  var groupKey: String {
    "\(backendModel ?? "unknown")+p\(promptVersion.map(String.init) ?? "unknown")+s\(shieldVersion.map(String.init) ?? "unknown")"
  }
}

enum RewriteAttemptState: String, Sendable, Codable, CaseIterable {
  case pending, succeeded, failed, cancelled
  case timedOut = "timed_out"
  var isTerminal: Bool { self != .pending }
}

/// One row of `rewrite_attempts`. Exists only for an admitted attempt.
struct RewriteAttempt: Identifiable, Sendable, Equatable {
  static let maximumPerDictation = 10
  static let maximumPendingOverall = 2

  let id: UUID
  let transcriptionID: UUID
  let ordinal: Int
  let mode: RewriteMode
  let state: RewriteAttemptState
  let inputText: String
  let inputHash: String
  let outputText: String?
  let outputHash: String?
  let unchanged: Bool
  let failureCategory: RewriteFailureCategory?
  let stale: Bool
  let startedAtMilliseconds: Int64
  let spans: RewriteSpans
  let serverQueueMilliseconds: Int?
  let backendFirstTokenMilliseconds: Int?
  let backendMilliseconds: Int?
  let protocolVersion: Int
  let identity: RewriteIdentity
  let endpointOrigin: String
  let insecureOverride: Bool
  let delivered: Bool

  /// The text this attempt can deliver, or nil unless it succeeded.
  var deliverableText: String? { state == .succeeded ? outputText : nil }
}
