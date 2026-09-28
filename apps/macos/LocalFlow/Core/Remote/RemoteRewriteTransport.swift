import Foundation

/// Hands a completed dictation's still-open channel to its rewrite, or opens a new
/// session channel when there is none (Feature 014 R14).
actor RemoteRewriteChannels {
  typealias Opener = @Sendable () async throws -> RemoteChannel

  private var parked: (channel: RemoteChannel, nextOp: Int)?
  private let open: Opener

  init(open: @escaping Opener) { self.open = open }

  /// The latest dictation's channel. A previous one that was never used is closed.
  func park(_ result: RemoteDictationResult) async {
    if let old = parked { await old.channel.close() }
    parked = (result.channel, result.nextOp)
  }

  /// A channel and the operation number to use on it; the caller owns and closes it.
  func take() async throws -> (RemoteChannel, Int) {
    if let current = parked {
      parked = nil
      return current
    }
    return (try await open(), 1)
  }

  func closeParked() async {
    if let old = parked { await old.channel.close() }
    parked = nil
  }
}

/// `RewriteTransporting` over the remote channel: the unchanged rewrite request JSON goes
/// in a `rewrite` operation, and each `rewrite_event` becomes the same item the HTTP
/// client yields. Channel failures map to the Feature 003 fallback categories, so the
/// coordinator, attempt storage and delivery work as they do over HTTP.
final class RemoteRewriteTransport: RewriteTransporting, @unchecked Sendable {
  /// The rewrite handler on flowd is the Feature 003/012 one: both versions.
  static let protocolVersions = [RewriteBounds.schemaVersion, RewriteBounds.contextSchemaVersion]

  private let channels: RemoteRewriteChannels
  private let clock: any DictationClock

  init(channels: RemoteRewriteChannels, clock: any DictationClock = SystemDictationClock()) {
    self.channels = channels
    self.clock = clock
  }

  func rewrite(request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<RewriteTransportItem, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { [channels, clock] in
        let owned = OwnedChannel()
        do {
          let body = try request.httpBody()
          let cap = RewriteBounds.maximumResponseBytes(inputBytes: request.inputBytes)
          try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
              group.addTask {
                try await clock.sleep(for: timeout)
                // Closing ends a receive that is still waiting for the server.
                await owned.get()?.close()
                throw RewriteFailure(.timeout)
              }
              group.addTask {
                let (channel, op) = try await channels.take()
                owned.set(channel)
                if Task.isCancelled { await channel.close() }
                try await channel.send(.rewrite(op: op, request: body))
                var first = true
                var total = 0
                while true {
                  let message = try await channel.receive()
                  if first {
                    continuation.yield(.firstByte)
                    first = false
                  }
                  switch message {
                  case .rewriteEvent(op, let data):
                    total += data.count + 1
                    guard total <= cap else { throw RewriteFailure(.oversizedResponse) }
                    let event = try RewriteEvent.decode(line: data)
                    if case .result = event {
                    } else if data.count > RewriteBounds.maximumLineBytes {
                      throw RewriteFailure(.malformedResponse)
                    }
                    continuation.yield(.event(event))
                    if event.isTerminal {
                      continuation.yield(.completed(requestBytes: body.count, responseBytes: total))
                      return
                    }
                  case .progress(op, _):
                    continue
                  case .error(_, let code):
                    throw RewriteFailure(Self.category(for: .server(code)))
                  default:
                    throw RewriteFailure(.malformedResponse)
                  }
                }
              }
              try await group.next()
              group.cancelAll()
            }
          } onCancel: {
            Task { await owned.get()?.close() }
          }
          await owned.get()?.close()
          continuation.finish()
        } catch {
          await owned.get()?.close()
          continuation.finish(throwing: Self.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func health(endpoint: RewriteEndpoint) async throws -> HealthResponse {
    // The channel has no health route; a session that opens is the check.
    HealthResponse(
      schemaVersion: 1, service: HealthResponse.serviceName,
      protocolVersions: Self.protocolVersions, serverName: "flowd", serverVersion: nil,
      modes: RewriteMode.allCases.filter(\.sendsRequest).map(\.rawValue),
      backend: .init(state: "ready", kind: nil, model: nil), promptVersions: [:],
      shieldVersion: nil)
  }

  func protocolVersions(endpoint: RewriteEndpoint) async -> [Int]? { Self.protocolVersions }

  func invalidate() {
    Task { await channels.closeParked() }
  }

  static func category(for error: RemoteChannelError) -> RewriteFailureCategory {
    switch error {
    case .unreachable, .closed: .serverUnreachable
    case .timeout: .timeout
    case .pinMismatch: .authenticationFailed
    case .protocolError: .malformedResponse
    case .server(let code):
      switch code {
      case .unauthorized, .tokenExpired, .notApproved, .revoked: .authenticationFailed
      case .busy, .workerUnavailable: .backendUnavailable
      case .unsupportedVersion: .unsupportedSchemaVersion
      case .invalidMessage, .limitExceeded: .serverValidationFailed
      case .internal: .transportError
      }
    }
  }

  static func mapped(_ error: any Error) -> any Error {
    if error is RewriteFailure || error is CancellationError { return error }
    if let channel = error as? RemoteChannelError { return RewriteFailure(category(for: channel)) }
    if error is RemoteTransportError { return RewriteFailure(.serverUnreachable) }
    return RewriteFailure(.transportError)
  }
}

/// The channel a rewrite took, closed when the rewrite ends whichever task finishes first.
private final class OwnedChannel: @unchecked Sendable {
  private let lock = NSLock()
  private var channel: RemoteChannel?
  func set(_ value: RemoteChannel) { lock.withLock { channel = value } }
  func get() -> RemoteChannel? { lock.withLock { channel } }
}

/// Sends each rewrite over HTTP (Feature 003) or the remote channel (Feature 014), as
/// the admitted settings chose; attempts, fallback and delivery do not change.
final class RoutingRewriteTransport: RewriteTransporting, @unchecked Sendable {
  private let http: any RewriteTransporting
  private let remote: any RewriteTransporting

  init(http: any RewriteTransporting, remote: any RewriteTransporting) {
    self.http = http
    self.remote = remote
  }

  private func transport(_ endpoint: RewriteEndpoint) -> any RewriteTransporting {
    endpoint.viaRemoteChannel ? remote : http
  }

  func rewrite(request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<RewriteTransportItem, Error>
  {
    transport(endpoint).rewrite(request: request, endpoint: endpoint, timeout: timeout)
  }

  func health(endpoint: RewriteEndpoint) async throws -> HealthResponse {
    try await transport(endpoint).health(endpoint: endpoint)
  }

  func protocolVersions(endpoint: RewriteEndpoint) async -> [Int]? {
    await transport(endpoint).protocolVersions(endpoint: endpoint)
  }

  func invalidate() {
    http.invalidate()
    remote.invalidate()
  }
}
