import Foundation

/// Immutable snapshot of the rewrite preferences captured on the main actor at
/// admission time. Later Settings changes never alter an admitted attempt. The
/// credential value is never copied here; only its presence is.
struct RewriteSettings: Sendable, Equatable {
  static let minimumTimeoutSeconds = 5
  static let maximumTimeoutSeconds = 60
  static let defaultTimeoutSeconds = 20
  static let maximumOriginBytes = 255

  let enabled: Bool
  let mode: RewriteMode
  /// The full endpoint URL as entered; nil when it fails validation.
  let endpoint: URL?
  /// Normalized `scheme://host:port`; empty when the endpoint is invalid.
  let endpointOrigin: String
  let timeoutSeconds: Int
  let insecureOverride: Bool
  let credentialPresent: Bool

  init(
    enabled: Bool, mode: RewriteMode, endpoint: URL?, endpointOrigin: String, timeoutSeconds: Int,
    insecureOverride: Bool, credentialPresent: Bool
  ) {
    self.enabled = enabled
    self.mode = mode
    self.endpoint = endpoint
    self.endpointOrigin = endpointOrigin
    self.timeoutSeconds = Self.clampTimeout(timeoutSeconds)
    self.insecureOverride = insecureOverride
    self.credentialPresent = credentialPresent
  }

  /// Reads preferences and credential presence; the store is asked whether an item
  /// exists, never for its value.
  @MainActor
  static func capture(preferences: AppPreferences, credentialStore: any RewriteCredentialStoring)
    -> RewriteSettings
  {
    let raw = preferences.rewriteEndpoint
    let origin = normalizedOrigin(raw)
    let url = origin == nil ? nil : URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    return RewriteSettings(
      enabled: preferences.rewriteEnabled, mode: preferences.rewriteDefaultMode, endpoint: url,
      endpointOrigin: origin ?? "", timeoutSeconds: preferences.rewriteTimeoutSeconds,
      insecureOverride: origin.map { preferences.insecureOverride(for: $0) } ?? false,
      credentialPresent: origin.map { credentialStore.exists(origin: $0) } ?? false)
  }

  var isEndpointValid: Bool { endpoint != nil && !endpointOrigin.isEmpty }
  var scheme: String { endpoint?.scheme?.lowercased() ?? "" }
  var host: String { Self.host(of: endpointOrigin) }
  var isLoopback: Bool { Self.isLoopbackHost(host) }
  var requiresCredential: Bool { !isLoopback }
  var isUnencryptedRemote: Bool { scheme == "http" && !isLoopback }

  var canSend: Bool {
    enabled && isEndpointValid && (!requiresCredential || credentialPresent)
      && (!isUnencryptedRemote || insecureOverride)
  }

  /// Precedence: blocked plain HTTP, then missing credential, then invalid endpoint.
  var refusalCategory: RewriteFailureCategory? {
    if isEndpointValid && isUnencryptedRemote && !insecureOverride {
      return .insecureEndpointBlocked
    }
    if isEndpointValid && requiresCredential && !credentialPresent { return .missingCredential }
    if !isEndpointValid { return .invalidSettings }
    return nil
  }

  static func clampTimeout(_ seconds: Int) -> Int {
    min(max(seconds, minimumTimeoutSeconds), maximumTimeoutSeconds)
  }

  /// Absolute `http`/`https` URL with a host and no credentials; the origin is
  /// `scheme://host:port` with a lowercase host and an explicit port.
  static func normalizedOrigin(_ endpoint: String) -> String? {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048,
      let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      var host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil
    else { return nil }
    if let port = components.port, port < 1 || port > 65_535 { return nil }
    let port = components.port ?? (scheme == "https" ? 443 : 80)
    if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
    guard host.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else { return nil }
    let origin = "\(scheme)://\(host):\(port)"
    guard origin.utf8.count <= maximumOriginBytes else { return nil }
    return origin
  }

  static func host(of origin: String) -> String {
    guard let range = origin.range(of: "://") else { return "" }
    var rest = origin[range.upperBound...]
    if rest.hasPrefix("[") {
      guard let close = rest.firstIndex(of: "]") else { return "" }
      return String(rest[rest.index(after: rest.startIndex)..<close])
    }
    if let colon = rest.lastIndex(of: ":") { rest = rest[..<colon] }
    return String(rest)
  }

  /// `localhost`, `127.0.0.0/8` and `::1` need neither a credential nor an override.
  static func isLoopbackHost(_ host: String) -> Bool {
    let value = host.lowercased()
    if value == "localhost" || value == "::1" || value == "[::1]" { return true }
    let octets = value.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      return false
    }
    return octets.compactMap({ Int($0) }).count == 4 && Int(octets[0]) == 127
      && octets.allSatisfy { Int($0)! <= 255 }
  }
}

/// Bounds on the stored secret; shared by the Keychain store and its fake.
enum RewriteCredentialValidation {
  static let maximumBytes = 4_096
  static func validate(secret: String) throws {
    guard !secret.isEmpty else { throw RewriteCredentialError.empty }
    guard secret.utf8.count <= maximumBytes else { throw RewriteCredentialError.tooLarge }
    guard secret == secret.trimmingCharacters(in: .whitespacesAndNewlines),
      !secret.contains(where: { $0.isNewline })
    else { throw RewriteCredentialError.invalidCharacters }
  }
}

/// Bounded error codes; none carries the secret, the origin or a system message.
enum RewriteCredentialError: Error, Equatable, Sendable {
  case empty
  case tooLarge
  case invalidCharacters
  case unavailable(Int32)
}
