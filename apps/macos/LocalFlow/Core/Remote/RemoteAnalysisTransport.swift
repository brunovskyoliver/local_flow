import Foundation
import LocalFlowCore
import LocalFlowSpeech

/// Sends each analysis over HTTP (Feature 011) or the background channel (Feature 018),
/// as the run's admitted endpoint chose. A custom summaries server that fails before
/// any result is retried once over the channel (R9).
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

  /// The same request over the channel, without the custom server's headers.
  private static func overChannel(_ endpoint: RewriteEndpoint) -> RewriteEndpoint {
    var channel = endpoint
    channel.viaRemoteChannel = true
    channel.channelFallback = false
    channel.summaryHeaders = [:]
    return channel
  }

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    guard endpoint.channelFallback, !endpoint.viaRemoteChannel else {
      return transport(endpoint).analyze(request: request, endpoint: endpoint, timeout: timeout)
    }
    let first = http.analyze(request: request, endpoint: endpoint, timeout: timeout)
    return AsyncThrowingStream { continuation in
      let task = Task { [remote] in
        // Held back until the custom server shows progress or a result; a failure
        // before that drops them and the channel answers instead.
        var held: [AnalysisTransportItem] = []
        var committed = false
        do {
          do {
            for try await item in first {
              if !committed {
                switch item {
                case .event(.progress), .event(.result):
                  committed = true
                case .event(.error(_, let code)):
                  throw AnalysisFailure(AnalysisFailureCategory.forServerCode(code), detail: code)
                default:
                  held.append(item)
                  continue
                }
                for item in held { continuation.yield(item) }
                held = []
              }
              continuation.yield(item)
            }
            for item in held { continuation.yield(item) }
            continuation.finish()
            return
          } catch  where !committed && !(error is CancellationError) {
            continuation.yield(.fellBackToServer)
          }
          for try await item in remote.analyze(
            request: request, endpoint: Self.overChannel(endpoint), timeout: timeout)
          {
            continuation.yield(item)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    guard endpoint.channelFallback, !endpoint.viaRemoteChannel else {
      return try await transport(endpoint).health(endpoint: endpoint)
    }
    if let health = try? await http.health(endpoint: endpoint), health.backend?.state == "ready" {
      return health
    }
    return try await remote.health(endpoint: Self.overChannel(endpoint))
  }

  func pinned(_ endpoint: RewriteEndpoint) -> RewriteEndpoint {
    transport(endpoint).pinned(endpoint)
  }

  func invalidate() {
    http.invalidate()
    remote.invalidate()
  }
}
