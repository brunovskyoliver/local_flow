import Foundation
import LocalFlowCore
import LocalFlowSpeech

/// `AnalysisTransporting` over the background channel (Feature 018 research R8). The
/// unchanged analysis request JSON goes out in `analysis_part` fragments closed by
/// `analysis`; each `analysis_event`, inline or reassembled from `analysis_event_part`s,
/// becomes the item the HTTP client yields. A busy or unreachable server and a stopped
/// worker fail with `waiting_for_server`, which the coordinator retries (FR-031);
/// `not_offered` drops the capability so the next run takes the local path.
final class RemoteAnalysisTransport: AnalysisTransporting, @unchecked Sendable {
  static let maximumPartBytes = 49_152
  /// What one fragment may take once JSON-escaped, leaving room for the envelope.
  static let maximumEscapedPartBytes = 64_000
  static let waitingDetail = "waiting_for_server"

  private let pool: RemoteChannelPool
  private let clock: any DictationClock
  private let notOffered: @Sendable () async -> Void

  init(
    pool: RemoteChannelPool, clock: any DictationClock = SystemDictationClock(),
    notOffered: @escaping @Sendable () async -> Void = {}
  ) {
    self.pool = pool
    self.clock = clock
    self.notOffered = notOffered
  }

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { [pool, clock] in
        do {
          let body = try JSONEncoder().encode(request)
          guard body.count <= AnalysisBounds.maxRequestBodyBytes else {
            throw AnalysisFailure(.tooLong)
          }
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              try await clock.sleep(for: timeout)
              throw AnalysisFailure(.timeout)
            }
            group.addTask {
              try await Self.run(body: body, pool: pool, continuation: continuation)
            }
            try await group.next()
            group.cancelAll()
          }
          continuation.finish()
        } catch {
          if (error as? RemoteChannelError) == .server(.notOffered) { await self.notOffered() }
          continuation.finish(throwing: Self.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// One op on the background channel; the channel is kept only after a terminal event.
  private static func run(
    body: Data, pool: RemoteChannelPool,
    continuation: AsyncThrowingStream<AnalysisTransportItem, Error>.Continuation
  ) async throws {
    let (channel, op) = try await pool.lease(.background)
    var finished = false
    do {
      try await withTaskCancellationHandler {
        let parts = fragments(body)
        for (index, part) in parts.enumerated() {
          try await channel.send(.analysisPart(op: op, index: index, data: part))
        }
        try await channel.send(
          .analysis(op: op, parts: parts.count, bytes: body.count, sha256: SHA256Digest.hex(body)))
        var first = true
        var total = 0
        var pending = Data()
        var pendingParts = 0
        while true {
          let message = try await channel.receive()
          if first {
            continuation.yield(.firstByte)
            first = false
          }
          let line: Data
          switch message {
          case .analysisEventPart(op, let index, let data):
            guard index == pendingParts,
              pending.count + data.utf8.count <= AnalysisBounds.maxLineBytes
            else { throw AnalysisFailure(.oversizedResponse) }
            pending.append(Data(data.utf8))
            pendingParts += 1
            continue
          case .analysisEvent(op, let event?, nil, nil):
            guard pendingParts == 0 else { throw AnalysisFailure(.malformedResponse) }
            line = event
          case .analysisEvent(op, nil, let parts?, let sha256?):
            guard parts == pendingParts, SHA256Digest.hex(pending) == sha256 else {
              throw AnalysisFailure(.malformedResponse)
            }
            line = pending
            pending = Data()
            pendingParts = 0
          case .progress(op, _):
            continue
          case .error(_, let code):
            throw RemoteChannelError.server(code)
          default:
            throw AnalysisFailure(.malformedResponse)
          }
          total += line.count + 1
          guard total <= AnalysisBounds.maxStreamBytes else {
            throw AnalysisFailure(.oversizedResponse, detail: "stream_bytes")
          }
          let event = try AnalysisEvent.decode(line: line)
          continuation.yield(.event(event))
          switch event {
          case .result, .error:
            continuation.yield(.completed(requestBytes: body.count, responseBytes: total))
            finished = true
            await pool.release(.background, channel: channel, nextOp: op + 1)
            return
          case .accepted, .progress:
            continue
          }
        }
      } onCancel: {
        Task { await channel.close() }
      }
    } catch {
      if !finished { await pool.release(.background, channel: channel, nextOp: nil) }
      throw error
    }
  }

  /// The request in order, each fragment at most 49,152 UTF-8 bytes and small enough
  /// once escaped to fit one control message. Cuts fall between Unicode scalars.
  static func fragments(_ body: Data) -> [String] {
    let text = String(decoding: body, as: UTF8.self)
    var parts: [String] = []
    var current = String.UnicodeScalarView()
    var raw = 0
    var escaped = 0
    for scalar in text.unicodeScalars {
      let bytes = String(scalar).utf8.count
      let cost: Int
      switch scalar {
      case "\"", "\\", "/": cost = 2
      case _ where scalar.value < 0x20: cost = 6
      default: cost = bytes
      }
      if raw + bytes > maximumPartBytes || escaped + cost > maximumEscapedPartBytes {
        parts.append(String(current))
        current = String.UnicodeScalarView()
        raw = 0
        escaped = 0
      }
      current.append(scalar)
      raw += bytes
      escaped += cost
    }
    if !current.isEmpty || parts.isEmpty { parts.append(String(current)) }
    return parts
  }

  /// The channel has no health route. flowd's own analysis handler answers on it, so
  /// the client's default limits apply.
  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    AnalysisHealth(
      schemaVersion: 1, service: AnalysisHealth.serviceName, protocolVersions: [1],
      serverName: "flowd", serverVersion: nil,
      backend: .init(state: "ready", kind: nil, model: nil, jsonSchema: true), promptVersions: [:],
      resultSchemaVersion: AnalysisBounds.schemaVersion, limits: nil, caps: nil)
  }

  /// The server uses its own backend: no summary-server headers, ever (R9).
  func pinned(_ endpoint: RewriteEndpoint) -> RewriteEndpoint {
    var pinned = endpoint
    pinned.summaryHeaders = [:]
    return pinned
  }

  func invalidate() {}

  /// Busy, unreachable and a stopped worker wait for the server; the rest map like HTTP.
  static func mapped(_ error: any Error) -> any Error {
    if error is AnalysisFailure || error is CancellationError { return error }
    guard let channel = error as? RemoteChannelError else {
      return AnalysisFailure(.serverUnreachable, detail: waitingDetail)
    }
    switch channel {
    case .unreachable, .closed, .timeout:
      return AnalysisFailure(.serverUnreachable, detail: waitingDetail)
    case .pinMismatch: return AnalysisFailure(.authenticationFailed)
    case .protocolError: return AnalysisFailure(.malformedResponse)
    case .server(let code):
      switch code {
      case .busy, .workerUnavailable:
        return AnalysisFailure(.serverUnreachable, detail: waitingDetail)
      case .notOffered: return AnalysisFailure(.serverUnavailable, detail: "not_offered")
      case .unauthorized, .tokenExpired, .notApproved, .revoked:
        return AnalysisFailure(.authenticationFailed)
      case .limitExceeded: return AnalysisFailure(.tooLong)
      case .unsupportedVersion: return AnalysisFailure(.unsupportedVersion)
      case .invalidMessage, .internal: return AnalysisFailure(.malformedResponse)
      }
    }
  }
}

/// Sends each analysis over HTTP (Feature 011) or the background channel (Feature 018),
/// as the run's admitted endpoint chose.
final class RoutingAnalysisTransport: AnalysisTransporting, @unchecked Sendable {
  private let http: any AnalysisTransporting
  private let remote: any AnalysisTransporting

  init(http: any AnalysisTransporting, remote: any AnalysisTransporting) {
    self.http = http
    self.remote = remote
  }

  private func transport(_ endpoint: RewriteEndpoint) -> any AnalysisTransporting {
    endpoint.viaRemoteChannel ? remote : http
  }

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    transport(endpoint).analyze(request: request, endpoint: endpoint, timeout: timeout)
  }

  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    try await transport(endpoint).health(endpoint: endpoint)
  }

  func pinned(_ endpoint: RewriteEndpoint) -> RewriteEndpoint {
    transport(endpoint).pinned(endpoint)
  }

  func invalidate() {
    http.invalidate()
    remote.invalidate()
  }
}
