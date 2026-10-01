import Foundation

/// flowd's loopback admin API (ADR 0032, server/cmd/flowd/admin_api.go): live counters
/// and switching the summaries backend without a restart. Present when flowd runs with
/// `--admin-listen`; the bearer token is read from `<data-dir>/admin-token` per request
/// and never stored or shown.
struct AdminStatus: Decodable, Equatable, Sendable {
  struct Count: Decodable, Equatable, Sendable {
    var requests: Int
    var failures: Int
  }
  struct Analysis: Decodable, Equatable, Sendable {
    var backend: String
    var model: String
  }
  var version: String
  var startedAt: String
  var counters: [String: Count]
  var analysis: Analysis

  enum CodingKeys: String, CodingKey {
    case version, counters, analysis
    case startedAt = "started_at"
  }
}

enum AdminAPI {
  /// The admin port from flowd's plist, when the installer set one.
  static var url: URL? {
    guard let listen = AgentPlist.arguments(Server.plist)?.value(after: "--admin-listen") else {
      return nil
    }
    return URL(string: "http://\(listen)/v1/admin")
  }

  static func status() async -> AdminStatus? {
    guard let data = await send("GET", "status", body: nil) else { return nil }
    return try? JSONDecoder().decode(AdminStatus.self, from: data)
  }

  /// nil `model` sends summaries back to the rewrite model.
  static func setAnalysis(backend: String, model: String?) async -> AdminStatus? {
    let body = try? JSONSerialization.data(withJSONObject: [
      "backend": model == nil ? "" : backend, "model": model ?? "",
    ])
    guard let data = await send("PUT", "analysis", body: body) else { return nil }
    return try? JSONDecoder().decode(AdminStatus.self, from: data)
  }

  private static func send(_ method: String, _ path: String, body: Data?) async -> Data? {
    guard let url,
      let token = try? String(
        contentsOf: Server.dataDir.appending(path: "admin-token"), encoding: .utf8)
    else { return nil }
    var request = URLRequest(url: url.appending(path: path), timeoutInterval: 3)
    request.httpMethod = method
    request.httpBody = body
    request.setValue(
      "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
      forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return data
  }
}
