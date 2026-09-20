import Foundation
import OSLog

/// Where a request goes: the full URL from Settings and its normalized origin,
/// which keys the credential and the insecure override.
struct RewriteEndpoint: Sendable, Equatable {
  let url: URL
  let origin: String

  init?(settings: RewriteSettings) {
    guard let url = settings.endpoint, settings.isEndpointValid else { return nil }
    self.url = url
    origin = settings.endpointOrigin
  }
  init(url: URL, origin: String) {
    self.url = url
    self.origin = origin
  }

  var rewriteURL: URL { url.appendingPathComponent("v1/rewrite") }
  var healthURL: URL { url.appendingPathComponent("v1/rewrite/health") }
  var analysisURL: URL { url.appendingPathComponent("v1/analysis/meeting") }
  var analysisHealthURL: URL { url.appendingPathComponent("v1/analysis/health") }
}

/// What the transport yields while a response streams in. `firstByte` arrives
/// once, before any event; `completed` closes a stream that ended normally.
enum RewriteTransportItem: Sendable, Equatable {
  case firstByte
  case event(RewriteEvent)
  case completed(requestBytes: Int, responseBytes: Int)
}

/// Eight connection-test outcomes (FR-017), in evaluation order.
enum RewriteConnectionCategory: String, Sendable, Equatable {
  case connected, authenticationFailed, serverUnreachable, rewriteServiceUnavailable
  case backendUnavailable, incompatibleVersion, missingCredential, insecureEndpointBlocked

  /// After a 200 with a JSON body: service, protocol, backend, in that order.
  static func evaluate(_ health: HealthResponse) -> RewriteConnectionCategory {
    guard health.isRewriteService else { return .rewriteServiceUnavailable }
    guard health.supportsProtocolOne else { return .incompatibleVersion }
    guard health.backendReady else { return .backendUnavailable }
    return .connected
  }

  /// The two checks that never send a request.
  static func preflight(_ settings: RewriteSettings) -> RewriteConnectionCategory? {
    guard settings.isEndpointValid else { return .rewriteServiceUnavailable }
    if settings.isUnencryptedRemote && !settings.insecureOverride {
      return .insecureEndpointBlocked
    }
    if settings.requiresCredential && !settings.credentialPresent { return .missingCredential }
    return nil
  }
}

/// Thrown by `health` for anything but a 200 with a JSON object body.
struct RewriteConnectionFailure: Error, Equatable, Sendable {
  let category: RewriteConnectionCategory
  /// Bounded, content-free code for diagnostics; never the HTTP body.
  let diagnostic: String
}

/// `URLSession`-backed transport. The session is ephemeral (no cache, cookies
/// or credential storage), created lazily, and can be invalidated when
/// rewriting is turned off so nothing stays mapped while the feature is idle.
final class RewriteClient: RewriteTransporting, @unchecked Sendable {
  static let connectionTestTimeout: Duration = .seconds(10)
  /// Client-side handling allowance on top of the configured timeout (SC-004).
  static let timeoutTolerance: Duration = .milliseconds(500)

  private let credentials: any RewriteCredentialStoring
  private let clock: any DictationClock
  private let configure: @Sendable (URLSessionConfiguration) -> Void
  private let lock = NSLock()
  private var session: URLSession?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "rewrite")

  init(
    credentials: any RewriteCredentialStoring, clock: any DictationClock = SystemDictationClock(),
    configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }
  ) {
    self.credentials = credentials
    self.clock = clock
    self.configure = configure
  }

  /// Ephemeral, keep-alive on, never waits for connectivity: an unreachable
  /// server must fail fast so the faithful transcript is inserted at once.
  static func makeConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.waitsForConnectivity = false
    configuration.allowsCellularAccess = true
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return configuration
  }

  private func currentSession() -> URLSession {
    lock.withLock {
      if let session { return session }
      let configuration = Self.makeConfiguration()
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

  // MARK: Rewrite

  func rewrite(request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<RewriteTransportItem, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { [self] in
        do {
          let (urlRequest, requestBytes) = try buildRequest(
            request, endpoint: endpoint, timeout: timeout)
          let cap = RewriteBounds.maximumResponseBytes(inputBytes: request.inputBytes)
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              try await self.clock.sleep(for: timeout)
              throw RewriteFailure(.timeout)
            }
            group.addTask {
              try await self.stream(
                urlRequest, cap: cap, requestBytes: requestBytes, continuation: continuation)
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
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func buildRequest(_ request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    throws -> (URLRequest, Int)
  {
    var urlRequest = URLRequest(url: endpoint.rewriteURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
    urlRequest.timeoutInterval = timeout.seconds
    // The credential is read here, at request-build time, never from a snapshot.
    if let secret = try? credentials.read(origin: endpoint.origin) {
      urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    }
    let body = try JSONEncoder().encode(request)
    urlRequest.httpBody = body
    return (urlRequest, body.count)
  }

  private func stream(
    _ urlRequest: URLRequest, cap: Int, requestBytes: Int,
    continuation: AsyncThrowingStream<RewriteTransportItem, Error>.Continuation
  ) async throws {
    let (bytes, response) = try await currentSession().bytes(for: urlRequest)
    continuation.yield(.firstByte)
    guard let http = response as? HTTPURLResponse else { throw RewriteFailure(.transportError) }
    guard http.statusCode == 200 else {
      let code = try await Self.errorCode(from: bytes)
      throw RewriteFailure(RewriteFailureCategory.forHTTPStatus(http.statusCode, code: code))
    }
    var line: [UInt8] = []
    var total = 0
    for try await byte in bytes {
      total += 1
      guard total <= cap else { throw RewriteFailure(.oversizedResponse) }
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

  /// A decoded line; anything but `result` must fit the per-line bound.
  private static func deliver(
    _ line: [UInt8], continuation: AsyncThrowingStream<RewriteTransportItem, Error>.Continuation
  ) throws {
    let event = try RewriteEvent.decode(line: Data(line))
    if case .result = event {
    } else if line.count > RewriteBounds.maximumLineBytes {
      throw RewriteFailure(.malformedResponse)
    }
    continuation.yield(.event(event))
  }

  /// Reads a non-200 body to at most 8,192 bytes and keeps only the code.
  private static func errorCode(from bytes: URLSession.AsyncBytes) async throws -> String? {
    var body: [UInt8] = []
    for try await byte in bytes {
      body.append(byte)
      if body.count >= RewriteBounds.maximumErrorBodyBytes { break }
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
      let error = object["error"] as? [String: Any]
    else { return nil }
    return error["code"] as? String
  }

  static func mapped(_ error: Error) -> Error {
    if error is RewriteFailure || error is CancellationError { return error }
    guard let urlError = error as? URLError else { return RewriteFailure(.transportError) }
    switch urlError.code {
    case .cancelled: return CancellationError()
    case .timedOut: return RewriteFailure(.timeout)
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
      .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
      return RewriteFailure(.serverUnreachable)
    default: return RewriteFailure(.transportError)
    }
  }

  // MARK: Health

  func health(endpoint: RewriteEndpoint) async throws -> HealthResponse {
    var urlRequest = URLRequest(url: endpoint.healthURL)
    urlRequest.httpMethod = "GET"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.timeoutInterval = Self.connectionTestTimeout.seconds
    if let secret = try? credentials.read(origin: endpoint.origin) {
      urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
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
            guard data.count < RewriteBounds.maximumErrorBodyBytes else {
              throw RewriteConnectionFailure(
                category: .rewriteServiceUnavailable, diagnostic: "health_too_large")
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
      if let failure = error as? RewriteConnectionFailure { throw failure }
      let urlError = error as? URLError
      let diagnostic =
        urlError.map { "url_error_\($0.code.rawValue)" } ?? "transport_error"
      let tls: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
      ]
      throw RewriteConnectionFailure(
        category: .serverUnreachable,
        diagnostic: urlError.map { tls.contains($0.code) } == true ? "transport_error" : diagnostic)
    }
    guard let http = response as? HTTPURLResponse else {
      throw RewriteConnectionFailure(category: .serverUnreachable, diagnostic: "no_http_response")
    }
    switch http.statusCode {
    case 200:
      guard
        let health = try? HealthResponse.decode(data.prefix(RewriteBounds.maximumErrorBodyBytes))
      else {
        throw RewriteConnectionFailure(category: .rewriteServiceUnavailable, diagnostic: "non_json")
      }
      return health
    case 401, 403:
      throw RewriteConnectionFailure(
        category: .authenticationFailed, diagnostic: "http_\(http.statusCode)")
    case 503:
      throw RewriteConnectionFailure(category: .backendUnavailable, diagnostic: "http_503")
    default:
      throw RewriteConnectionFailure(
        category: .rewriteServiceUnavailable, diagnostic: "http_\(http.statusCode)")
    }
  }
}
