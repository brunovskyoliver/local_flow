import Foundation

/// Where a request goes: the full URL from Settings and its normalized origin,
/// which keys the credential and the insecure override. The Mac builds it from its
/// rewrite settings (`init?(settings:)` in the app).
public struct RewriteEndpoint: Sendable, Equatable {
  public let url: URL
  public let origin: String
  /// Meeting analysis only: the summary-server headers pinned at admission
  /// (`AnalysisTransporting.pinned`), held in memory for one run and never
  /// logged or stored. Nil means "read the current Settings choice".
  public var summaryHeaders: [String: String]? = nil
  /// Feature 014: the request travels over the remote dictation channel, not HTTP.
  public var viaRemoteChannel = false
  /// Feature 018 (R9): a request to the custom summaries server that fails before any
  /// result is sent again over the channel.
  public var channelFallback = false

  public init(url: URL, origin: String) {
    self.url = url
    self.origin = origin
  }

  /// Feature 018: the server's channel, the custom summaries server, or this Mac's flowd.
  public var analysisInferencePath: AnalysisInferencePath {
    if viaRemoteChannel { return .server }
    return summaryHeaders?.isEmpty == false ? .custom : .local
  }

  public var rewriteURL: URL { url.appendingPathComponent("v1/rewrite") }
  public var healthURL: URL { url.appendingPathComponent("v1/rewrite/health") }
  public var analysisURL: URL { url.appendingPathComponent("v1/analysis/meeting") }
  public var analysisHealthURL: URL { url.appendingPathComponent("v1/analysis/health") }
}
