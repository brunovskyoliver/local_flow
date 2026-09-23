import Foundation
import OSLog

/// Where meeting summaries run. Remote hands flowd the server from Settings
/// as its first choice; flowd falls back to its own backend (ADR 0021).
enum SummaryServer: String, CaseIterable, Identifiable, Sendable {
  case remote, local
  var id: String { rawValue }
  var title: String { self == .remote ? "Remote" : "This Mac" }

  static let defaultsKey = "summaryServer"
  static let urlKey = "summaryServerURL"
  static let modelKey = "summaryServerModel"
  /// Keychain account for the Remote server's API key, beside the rewrite secrets.
  static let credentialAccount = "summary-server"

  /// flowd's primary-backend headers for the current choice; empty for This Mac
  /// or an incomplete Remote entry. Read at request-build time, like the bearer.
  static func headers(defaults: UserDefaults, credentials: any RewriteCredentialStoring)
    -> [String: String]
  {
    let trimmed = { (key: String) in
      defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    let url = trimmed(urlKey)
    let model = trimmed(modelKey)
    guard defaults.string(forKey: defaultsKey) == remote.rawValue, !url.isEmpty, !model.isEmpty
    else { return [:] }
    var headers = ["X-LocalFlow-Primary-URL": url, "X-LocalFlow-Primary-Model": model]
    if let key = try? credentials.read(origin: credentialAccount) {
      headers["X-LocalFlow-Primary-Key"] = key
    }
    return headers
  }
}

/// `URLSession`-backed analysis transport (T030). Same shape as `RewriteClient`:
/// an ephemeral session (no cache, cookies or credential storage) created
/// lazily, the bearer read from the Keychain at request-build time, one NDJSON
/// reader that stops at `AnalysisBounds.maxLineBytes` total with
/// `oversized_response`, and URL-task cancellation when the Swift task is
/// cancelled. The session is invalidated after 60 s without an active run so
/// nothing stays mapped while the feature is idle.
final class AnalysisClient: AnalysisTransporting, @unchecked Sendable {
  static let idleTimeout: Duration = .seconds(60)
  static let connectionTestTimeout = RewriteClient.connectionTestTimeout
  /// The fixed refusal message the contract attaches to `server_unavailable`
  /// health outcomes ("a flowd without the analysis service").
  static let unavailableMessage = "This server does not offer meeting analysis"

  private let credentials: any RewriteCredentialStoring
  private let defaults: UserDefaults
  private let clock: any DictationClock
  private let configure: @Sendable (URLSessionConfiguration) -> Void
  private let lock = NSLock()
  private var session: URLSession?
  private var activeRuns = 0
  private var idleTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "analysis")

  init(
    credentials: any RewriteCredentialStoring, defaults: UserDefaults = .standard,
    clock: any DictationClock = SystemDictationClock(),
    configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }
  ) {
    self.credentials = credentials
    self.defaults = defaults
    self.clock = clock
    self.configure = configure
  }

  private func currentSession() -> URLSession {
    lock.withLock {
      if let session { return session }
      let configuration = RewriteClient.makeConfiguration()
      configure(configuration)
      let created = URLSession(configuration: configuration)
      session = created
      return created
    }
  }

  var hasSession: Bool { lock.withLock { session != nil } }

  /// Drops the session; the next request recreates it lazily.
  func invalidate() {
    let existing: URLSession? = lock.withLock {
      defer { session = nil }
      return session
    }
    existing?.invalidateAndCancel()
  }

  /// `analyze`/`health` mark work; when the count reaches zero a 60 s timer
  /// drops the session. A new run cancels the timer.
  private func runStarted() {
    lock.withLock {
      activeRuns += 1
      idleTask?.cancel()
      idleTask = nil
    }
  }

  private func runFinished() {
    lock.withLock {
      activeRuns = max(0, activeRuns - 1)
      guard activeRuns == 0, idleTask == nil else { return }
      idleTask = Task { [self] in
        try? await self.clock.sleep(for: Self.idleTimeout)
        guard !Task.isCancelled else { return }
        let idle = self.lock.withLock { self.activeRuns == 0 }
        if idle { self.invalidate() }
      }
    }
  }

  // MARK: Analyze

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    runStarted()
    return AsyncThrowingStream { continuation in
      let task = Task { [self] in
        do {
          let (urlRequest, requestBytes) = try buildRequest(
            request, endpoint: endpoint, timeout: timeout)
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              try await self.clock.sleep(for: timeout)
              throw AnalysisFailure(.timeout)
            }
            group.addTask {
              try await self.stream(
                urlRequest, requestBytes: requestBytes, continuation: continuation)
            }
            // The first to finish decides; the other is cancelled with the group.
            try await group.next()
            group.cancelAll()
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.mapped(error))
        }
      }
      continuation.onTermination = { [self] _ in
        task.cancel()
        runFinished()
      }
    }
  }

  private func buildRequest(
    _ request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration
  )
    throws -> (URLRequest, Int)
  {
    var urlRequest = URLRequest(url: endpoint.analysisURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
    urlRequest.timeoutInterval = timeout.seconds
    // The credential is read here, at request-build time, never from a snapshot.
    if let secret = try? credentials.read(origin: endpoint.origin) {
      urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    }
    for (name, value) in SummaryServer.headers(defaults: defaults, credentials: credentials) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let body = try JSONEncoder().encode(request)
    urlRequest.httpBody = body
    return (urlRequest, body.count)
  }

  private func stream(
    _ urlRequest: URLRequest, requestBytes: Int,
    continuation: AsyncThrowingStream<AnalysisTransportItem, Error>.Continuation
  ) async throws {
    let (bytes, response) = try await currentSession().bytes(for: urlRequest)
    continuation.yield(.firstByte)
    guard let http = response as? HTTPURLResponse else {
      throw AnalysisFailure(.serverUnreachable)
    }
    guard http.statusCode == 200 else {
      let code = try await Self.errorCode(from: bytes)
      // A bare 429 carries the same requeue meaning as a `server_busy` event
      // (contract step 6), so the coordinator sees one detail for both.
      let detail = code ?? (http.statusCode == 429 ? "server_busy" : nil)
      throw AnalysisFailure(
        AnalysisFailureCategory.forHTTPStatus(http.statusCode, code: code), detail: detail)
    }
    var line: [UInt8] = []
    var total = 0
    for try await byte in bytes {
      total += 1
      guard total <= AnalysisBounds.maxLineBytes else {
        throw AnalysisFailure(.oversizedResponse)
      }
      if byte == 10 {
        try Self.deliver(line, continuation: continuation)
        line.removeAll(keepingCapacity: true)
      } else {
        line.append(byte)
      }
    }
    if !line.isEmpty { try Self.deliver(line, continuation: continuation) }
    continuation.yield(.completed(requestBytes: requestBytes, responseBytes: total))
  }

  /// Every line is bounded by `AnalysisBounds.maxLineBytes`; decode enforces
  /// it and yields `oversized_response` for an over-cap line.
  private static func deliver(
    _ line: [UInt8],
    continuation: AsyncThrowingStream<AnalysisTransportItem, Error>.Continuation
  ) throws {
    continuation.yield(.event(try AnalysisEvent.decode(line: Data(line))))
  }

  /// Reads a non-200 body to at most 8,192 bytes and keeps only the code.
  private static func errorCode(from bytes: URLSession.AsyncBytes) async throws -> String? {
    var body: [UInt8] = []
    for try await byte in bytes {
      body.append(byte)
      if body.count >= AnalysisBounds.maxErrorBodyBytes { break }
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
      let error = object["error"] as? [String: Any]
    else { return nil }
    return error["code"] as? String
  }

  static func mapped(_ error: Error) -> Error {
    if error is AnalysisFailure || error is CancellationError { return error }
    guard let urlError = error as? URLError else {
      return AnalysisFailure(.serverUnreachable)
    }
    switch urlError.code {
    case .cancelled: return CancellationError()
    case .timedOut: return AnalysisFailure(.timeout)
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
      .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
      return AnalysisFailure(.serverUnreachable)
    default: return AnalysisFailure(.serverUnreachable)
    }
  }

  // MARK: Health

  /// `GET /v1/analysis/health`. A 404, a wrong `service` value or a non-JSON
  /// body means the server does not offer analysis → `server_unavailable`
  /// with the fixed message. A `result_schema_version` other than 1 →
  /// `unsupported_version`. Other statuses map like the stream's.
  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    runStarted()
    defer { runFinished() }
    var urlRequest = URLRequest(url: endpoint.analysisHealthURL)
    urlRequest.httpMethod = "GET"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.timeoutInterval = Self.connectionTestTimeout.seconds
    if let secret = try? credentials.read(origin: endpoint.origin) {
      urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    }
    for (name, value) in SummaryServer.headers(defaults: defaults, credentials: credentials) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let data: Data
    let response: URLResponse
    let probe = urlRequest
    do {
      (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
          try await self.clock.sleep(for: Self.connectionTestTimeout)
          throw URLError(.timedOut)
        }
        group.addTask {
          let (bytes, response) = try await self.currentSession().bytes(for: probe)
          defer { bytes.task.cancel() }
          guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return (Data(), response)
          }
          var data = Data()
          for try await byte in bytes {
            guard data.count < AnalysisBounds.maxErrorBodyBytes else {
              throw AnalysisFailure(.oversizedResponse)
            }
            data.append(byte)
          }
          return (data, response)
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
      }
    } catch {
      throw Self.mapped(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw AnalysisFailure(.serverUnreachable)
    }
    guard http.statusCode == 200 else {
      if http.statusCode == 404 {
        throw AnalysisFailure(.serverUnavailable, detail: Self.unavailableMessage)
      }
      throw AnalysisFailure(AnalysisFailureCategory.forHTTPStatus(http.statusCode, code: nil))
    }
    guard let health = try? AnalysisHealth.decode(data), health.isAnalysisService else {
      throw AnalysisFailure(.serverUnavailable, detail: Self.unavailableMessage)
    }
    guard health.resultSchemaVersion == AnalysisBounds.schemaVersion else {
      throw AnalysisFailure(.unsupportedVersion)
    }
    return health
  }
}
