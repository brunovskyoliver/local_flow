import AuthenticationServices
import CryptoKit
import Foundation
import OSLog

/// The display cache of this device's server state (`remote.state`). The server decides;
/// the app only shows what it last heard.
public enum RemoteDictationState: String, CaseIterable, Sendable {
  case off, pinned, pending, approved, rejected, revoked
  case pinMismatch = "pin_mismatch"
}

/// A one-off instruction the status line shows beside the state (`remote.notice`).
public enum RemoteDictationNotice: String, CaseIterable, Sendable {
  /// The device key or tokens are gone; enrollment must run again.
  case signInAgain = "sign_in_again"
  /// The server answered `unsupported_version`.
  case updateRequired = "update_required"
}

/// Feature 027: which kind of network an address found on the server Mac belongs to.
public enum ServerAddressKind: Sendable, Equatable {
  case lan, tailscale
}

/// The press-time snapshot of the remote settings (FR-017: one decision per dictation).
public struct RemoteDictationSettings: Sendable, Equatable {
  public static let defaultFallbackThreshold = Duration.milliseconds(1_500)
  public var enabled = false
  public var serverOrigin: URL?
  public var state: RemoteDictationState = .off
  public var fallbackThreshold: Duration = RemoteDictationSettings.defaultFallbackThreshold
  /// False under Settings › Server › Server only: a failed or missing server never
  /// falls back to the local model.
  public var localModelsAllowed = true
  /// Settings › Server › Advanced › Dictation: This Mac. Speech stays on this Mac while
  /// rewriting and the rest still use the server.
  public var dictationOnThisMac = false

  public static let off = RemoteDictationSettings()

  /// Remote recognition is attempted only for an approved device with a pinned server.
  public var routesToServer: Bool { enabled && serverOrigin != nil && state == .approved }
  /// Dictation audio streams to the server.
  public var streamsDictation: Bool { routesToServer && !dictationOnThisMac }

  /// An origin with no path, query, fragment or credentials; nil otherwise. `https://` on
  /// any host, `http://` only where `allowsPlainHTTP` says (FR-012a).
  public static func origin(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme, scheme == "https" || scheme == "http",
      let host = components.host, !host.isEmpty, components.user == nil,
      components.password == nil, components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/",
      scheme == "https" || allowsPlainHTTP(host: host)
    else { return nil }
    var origin = URLComponents()
    origin.scheme = scheme
    origin.host = host.lowercased()
    origin.port = components.port
    return origin.url
  }

  /// FR-012a: loopback, RFC 1918, link-local, IPv6 unique-local and Tailscale literals, and
  /// `.local`, `*.ts.net` and single-label names. `host` is `URLComponents.host`: IPv6 keeps
  /// its brackets, and Foundation has already applied IDNA mapping and percent-decoding.
  static func allowsPlainHTTP(host: String) -> Bool {
    let name = host.lowercased()
    if name.hasPrefix("["), name.hasSuffix("]") {
      let literal = name.dropFirst().dropLast().prefix { $0 != "%" }
      var address = in6_addr()
      guard inet_pton(AF_INET6, String(literal), &address) == 1 else { return false }
      let bytes = withUnsafeBytes(of: &address) { Array($0) }
      if bytes[..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
        return isPrivate(ipv4: Array(bytes[12...]))
      }
      return bytes == [UInt8](repeating: 0, count: 15) + [1]  // ::1
        || bytes[0] & 0xfe == 0xfc  // fc00::/7, which holds Tailscale's fd7a:115c:a1e0::/48
        || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)  // fe80::/10
    }
    var address = in_addr()
    if inet_pton(AF_INET, name, &address) == 1 {
      return isPrivate(ipv4: withUnsafeBytes(of: &address) { Array($0) })
    }
    // `2130706433`, `0x7f.1` and `127.1` aren't dotted quads but do reach an address, so
    // the name rules below must not see them: `134744072` is 8.8.8.8 as a "single label".
    if inet_aton(name, &address) != 0 { return false }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard
      labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.allSatisfy { $0 == 0x2d || isASCIIAlphanumeric($0) }
      })
    else { return false }
    return labels.count == 1 || (labels.count > 1 && labels.last == "local")
      || (labels.count > 2 && labels.suffix(2) == ["ts", "net"])
  }

  /// Where an address found on this machine leads, by FR-012a's own rule, for listing the
  /// server's addresses. nil for anything else: loopback, link-local, public or not an IP.
  public static func serverAddressKind(ip: String) -> ServerAddressKind? {
    var v4 = in_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
      let b = withUnsafeBytes(of: &v4) { Array($0) }
      guard isPrivate(ipv4: b), b[0] != 127, !(b[0] == 169 && b[1] == 254) else { return nil }
      return b[0] == 100 ? .tailscale : .lan
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, ip, &v6) == 1, allowsPlainHTTP(host: "[\(ip)]") else { return nil }
    let b = withUnsafeBytes(of: &v6) { Array($0) }
    guard b[0] & 0xfe == 0xfc else { return nil }  // only fc00::/7 stays stable and reachable
    return Array(b[..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] ? .tailscale : .lan
  }

  private static func isPrivate(ipv4 b: [UInt8]) -> Bool {
    b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16)
      || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
      || (b[0] == 100 && b[1] & 0xc0 == 64)
  }

  private static func isASCIIAlphanumeric(_ c: UInt8) -> Bool {
    (0x30...0x39).contains(c) || (0x61...0x7a).contains(c)
  }

  /// What a server form says under the address, FR-012a's statement included: why an
  /// `http://` address is refused, or that an accepted one is not TLS. Nil for anything else.
  public static func addressNotice(_ text: String) -> String? {
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("http://") else {
      return nil
    }
    return origin(text) == nil
      ? "http:// works only for private and Tailscale addresses. Use https:// for this one."
      : "This connection is not TLS. Content stays encrypted between this device and the server."
  }

  public init(
    enabled: Bool = false, serverOrigin: URL? = nil, state: RemoteDictationState = .off,
    fallbackThreshold: Duration = RemoteDictationSettings.defaultFallbackThreshold,
    localModelsAllowed: Bool = true, dictationOnThisMac: Bool = false
  ) {
    self.enabled = enabled
    self.serverOrigin = serverOrigin
    self.state = state
    self.fallbackThreshold = fallbackThreshold
    self.localModelsAllowed = localModelsAllowed
    self.dictationOnThisMac = dictationOnThisMac
  }
}

/// The settings enrollment reads and writes (`remote.*`). The Mac's `AppPreferences`
/// conforms; the phone keeps its own.
@MainActor
public protocol RemoteEnrollmentSettings: AnyObject {
  /// The server origin once the consent step is confirmed and the feature is on; nil
  /// before that, so nothing connects.
  var remoteEnrollmentOrigin: URL? { get }
  /// Stores an origin `updateAddress` verified; nothing else changes.
  func setRemoteOrigin(_ origin: URL)
  var remoteState: RemoteDictationState { get set }
  var remoteNotice: RemoteDictationNotice? { get set }
  /// Turning the feature off: every `remote.*` setting goes except the switch.
  func resetRemote()
}

public enum RemoteEnrollmentError: Error, Equatable, Sendable {
  /// Consent is not confirmed or no server address is set: nothing may connect.
  case notConfigured
  /// The identity endpoint answered something other than a v1 identity.
  case invalidIdentity
  /// The Secure Enclave can no longer load this device's key.
  case deviceKeyUnavailable
  case signInFailed
  /// The server answered with an unexpected message.
  case protocolError
  /// Feature 027: the address reaches a server other than the one that issued the token.
  case wrongServer
  /// Feature 027: the server doesn't know `pair`. The token was not spent.
  case updateRequired
  /// Feature 027: the address answers the identity route but carries no channel, as when a
  /// proxy strips WebSocket upgrades or rewrites paths.
  case unusableRoute
}

/// Enrollment and credentials for remote dictation (User Story 2): server identity and
/// pinning, Sign in with Apple or Google bound to the channel, the Secure Enclave key,
/// token refresh, state updates and turning the feature off. Main-actor confined; it
/// writes the display state into its `RemoteEnrollmentSettings`.
@MainActor
public final class RemoteEnrollment {
  /// Access tokens live 15 minutes on the server; the client refreshes after 12.
  public static let refreshAfter = Duration.seconds(12 * 60)

  private let preferences: any RemoteEnrollmentSettings
  private let credentials: any RemoteCredentialStoring
  private let keys: any RemoteDeviceKeys
  private let signIn: any IdentitySignIn
  private let identityFetcher: any RemoteIdentityFetching
  private let transports: any RemoteTransportOpening
  private let clock: any RemoteClock
  private let deviceName: String
  private var accessIssuedAt: Duration?
  private var refreshing: Task<String?, Never>?
  private var scheduledRefresh: Task<Void, Never>?
  /// The token being redeemed and its device key, kept until a definite answer: a lost
  /// reply can only be retried with the same key (contracts/pairing.md).
  private var pairAttempt: (token: PairingToken, handle: Data, publicKey: Data)?
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")

  public init(
    preferences: any RemoteEnrollmentSettings, credentials: any RemoteCredentialStoring,
    keys: any RemoteDeviceKeys, signIn: any IdentitySignIn,
    identityFetcher: any RemoteIdentityFetching, transports: any RemoteTransportOpening,
    clock: any RemoteClock = SystemRemoteClock(), deviceName: String
  ) {
    self.preferences = preferences
    self.credentials = credentials
    self.keys = keys
    self.signIn = signIn
    self.identityFetcher = identityFetcher
    self.transports = transports
    self.clock = clock
    self.deviceName = deviceName
  }

  public var state: RemoteDictationState { preferences.remoteState }

  /// `wss://<host>/v1/remote/channel`, or `ws://` for an `http://` origin; nil for anything
  /// `RemoteDictationSettings.origin` refuses, so a refused address never gets a socket.
  public static func channelURL(origin: URL) -> URL? {
    guard let checked = RemoteDictationSettings.origin(origin.absoluteString),
      var components = URLComponents(url: checked, resolvingAgainstBaseURL: false)
    else { return nil }
    components.scheme = checked.scheme == "http" ? "ws" : "wss"
    components.path = "/v1/remote/channel"
    return components.url
  }

  private var origin: URL? { preferences.remoteEnrollmentOrigin }

  // MARK: Identity and pinning

  /// Fetches the server identity for the user to compare. Nothing connects before the
  /// consent step and a server address.
  public func fetchServerIdentity() async throws -> RemoteServerIdentity {
    guard let origin else { throw RemoteEnrollmentError.notConfigured }
    let identity = try await identityFetcher.fetch(origin: origin)
    guard identity.validatedKey() != nil else { throw RemoteEnrollmentError.invalidIdentity }
    return identity
  }

  /// Pins the key the user saw. Only enrollment pins; a later mismatch never re-pins.
  public func pin(_ identity: RemoteServerIdentity) throws {
    guard origin != nil else { throw RemoteEnrollmentError.notConfigured }
    guard let key = identity.validatedKey() else { throw RemoteEnrollmentError.invalidIdentity }
    try credentials.removeAll()
    accessIssuedAt = nil
    try credentials.write(.serverKey, key)
    preferences.remoteNotice = nil
    preferences.remoteState = .pinned
  }

  public var pinnedKey: Data? { try? credentials.read(.serverKey) }

  /// Moves to a new address for the same server (FR-013). The identity there must be the
  /// pinned key exactly and a channel must open there; on a match only the stored address
  /// changes, and otherwise nothing does.
  public func updateAddress(to address: URL) async throws {
    guard origin != nil, let pinned = pinnedKey,
      let checked = RemoteDictationSettings.origin(address.absoluteString)
    else { throw RemoteEnrollmentError.notConfigured }
    let identity = try await identityFetcher.fetch(origin: checked)
    guard let key = identity.validatedKey() else { throw RemoteEnrollmentError.invalidIdentity }
    guard key == pinned else { throw RemoteEnrollmentError.wrongServer }
    guard let url = Self.channelURL(origin: checked) else {
      throw RemoteEnrollmentError.notConfigured
    }
    let channel = try RemoteChannel(transport: try await transports.open(url), serverKey: pinned)
    defer { Task { await channel.close() } }
    do {
      try await openChecked(channel)
    } catch RemoteChannelError.pinMismatch {
      throw RemoteEnrollmentError.wrongServer
    }
    preferences.setRemoteOrigin(checked)
  }

  /// Opens an enroll channel at an address whose identity route just answered, so a failure
  /// that isn't the server's own answer means the route doesn't carry WebSockets.
  private func openChecked(_ channel: RemoteChannel) async throws {
    do {
      try await channel.open(purpose: .enroll)
    } catch let error as RemoteChannelError {
      switch error {
      case .pinMismatch, .server: throw error
      case .unreachable, .timeout, .protocolError, .closed:
        throw RemoteEnrollmentError.unusableRoute
      }
    }
  }

  // MARK: Enrollment

  /// Creates the device key, signs in with the provider on a nonce bound to this
  /// channel, and registers the device. Returns the server's state for it.
  @discardableResult
  public func enroll(provider: IdentityProvider) async throws -> RemoteEnrollmentState {
    guard let origin, let url = Self.channelURL(origin: origin), let serverKey = pinnedKey else {
      throw RemoteEnrollmentError.notConfigured
    }
    let device = try keys.create()
    let channel = try RemoteChannel(transport: try await transports.open(url), serverKey: serverKey)
    defer { Task { await channel.close() } }
    do {
      try await channel.open(purpose: .enroll)
      let binding = await channel.binding
      let raw = binding.base64URL
      let nonce = provider == .apple ? SHA256Digest.hex(Data(raw.utf8)) : raw
      let token: String
      do { token = try await signIn.signIn(provider: provider, nonce: nonce) } catch {
        throw RemoteEnrollmentError.signInFailed
      }
      let signature = try keys.sign(
        Data("localflow-v1-enroll".utf8) + binding, handle: device.handle)
      try await channel.send(
        .enroll(
          op: 1, provider: provider, idToken: token, deviceName: deviceName,
          deviceKey: device.publicKey, signature: signature))
      switch try await channel.receive() {
      case .enrolled(1, let state, let refresh):
        try credentials.write(.deviceKey, device.handle)
        try? credentials.remove(.accessToken)
        accessIssuedAt = nil
        if let refresh { try credentials.write(.refreshToken, Data(refresh.utf8)) }
        preferences.remoteNotice = nil
        switch state {
        case .pending: preferences.remoteState = .pending
        case .approved: preferences.remoteState = .approved
        case .rejected: preferences.remoteState = .rejected
        }
        log.notice("Enrollment finished: state=\(state.rawValue, privacy: .public)")
        if state == .approved { _ = await refreshNow() }
        return state
      case .error(_, let code):
        apply(code)
        throw RemoteChannelError.server(code)
      default:
        throw RemoteEnrollmentError.protocolError
      }
    } catch let error as RemoteChannelError {
      if error == .pinMismatch { handlePinMismatch() }
      if case .server(let code) = error { apply(code) }
      throw error
    }
  }

  // MARK: Pairing

  /// What a `pair` message signs; `fixtures/remote/pairing-vectors.json` holds it for flowd.
  static func pairSignatureInput(binding: Data) -> Data {
    Data("localflow-v1-pair".utf8) + binding
  }

  /// Redeems a pairing token (Feature 027). The caller has shown consent. The token goes
  /// only into a channel sealed to the key it names, and only if the address serves that
  /// key. The pin, which clears existing credentials, comes after the server's answer, so
  /// a refused token leaves a working device as it was.
  public func pair(token: PairingToken) async throws {
    guard let origin, let url = Self.channelURL(origin: origin) else {
      throw RemoteEnrollmentError.notConfigured
    }
    let identity = try await fetchServerIdentity()
    guard identity.validatedKey() == token.serverKey else {
      throw RemoteEnrollmentError.wrongServer
    }
    let device: (handle: Data, publicKey: Data)
    if let pairAttempt, pairAttempt.token == token {
      device = (pairAttempt.handle, pairAttempt.publicKey)
    } else {
      device = try keys.create()
      pairAttempt = (token, device.handle, device.publicKey)
    }
    let channel = try RemoteChannel(
      transport: try await transports.open(url), serverKey: token.serverKey)
    defer { Task { await channel.close() } }
    do {
      try await openChecked(channel)
      let signature = try keys.sign(
        Self.pairSignatureInput(binding: await channel.binding), handle: device.handle)
      try await channel.send(
        .pair(
          op: 1, token: token.value, deviceName: deviceName, deviceKey: device.publicKey,
          signature: signature))
      switch try await channel.receive() {
      case .enrolled(1, .approved, let refresh?):
        try pin(identity)
        try credentials.write(.deviceKey, device.handle)
        try credentials.write(.refreshToken, Data(refresh.utf8))
        pairAttempt = nil
        preferences.remoteState = .approved
        log.notice("Pairing finished")
        _ = await refreshNow()
      case .error(_, let code):
        throw RemoteChannelError.server(code)
      default:
        throw RemoteEnrollmentError.protocolError
      }
    } catch RemoteChannelError.pinMismatch {
      // The channel, unlike the identity endpoint, proves who holds the key.
      pairAttempt = nil
      throw RemoteEnrollmentError.wrongServer
    } catch RemoteChannelError.server(let code) {
      pairAttempt = nil
      // A flowd without `pair` refuses the unknown type with invalid_message, then closes.
      guard code == .invalidMessage || code == .unsupportedVersion else {
        throw RemoteChannelError.server(code)
      }
      apply(.unsupportedVersion)
      throw RemoteEnrollmentError.updateRequired
    }
  }

  // MARK: Tokens

  /// A live access token for a session channel, refreshing first when it is 12 minutes
  /// old by the monotonic clock or its issue time is unknown. Nil when the device is not
  /// approved or the refresh failed; the dictation then runs locally.
  public func accessToken() async -> String? {
    guard origin != nil, preferences.remoteState == .approved else { return nil }
    if let token = credentials.string(.accessToken), let issued = accessIssuedAt,
      clock.now() - issued < Self.refreshAfter
    {
      return token
    }
    return await refreshNow()
  }

  /// A pending device tries one background refresh at dictation start, so an approval
  /// takes effect without restarting (User Story 2 scenario 5).
  public func refreshIfPending() {
    guard origin != nil, preferences.remoteState == .pending, refreshing == nil else { return }
    Task { _ = await refreshNow() }
  }

  /// After `token_expired`: the token is dropped and refreshed now.
  public func accessTokenExpired() async -> String? {
    try? credentials.remove(.accessToken)
    accessIssuedAt = nil
    return await refreshNow()
  }

  /// One refresh at a time; concurrent callers share it.
  @discardableResult
  public func refreshNow() async -> String? {
    if let refreshing { return await refreshing.value }
    let task = Task { await performRefresh() }
    refreshing = task
    let token = await task.value
    refreshing = nil
    return token
  }

  private func performRefresh() async -> String? {
    guard let origin, let url = Self.channelURL(origin: origin), let serverKey = pinnedKey,
      let refresh = credentials.string(.refreshToken)
    else { return nil }
    guard let handle = try? credentials.read(.deviceKey), keys.publicKey(handle: handle) != nil
    else {
      deviceKeyLost()
      return nil
    }
    let channel: RemoteChannel
    do {
      channel = try RemoteChannel(transport: try await transports.open(url), serverKey: serverKey)
    } catch {
      return nil
    }
    defer { Task { await channel.close() } }
    do {
      try await channel.open(purpose: .refresh)
      let binding = await channel.binding
      let digest = Data(SHA256.hash(data: Data(refresh.utf8)))
      let signature: Data
      do {
        signature = try keys.sign(
          Data("localflow-v1-refresh".utf8) + binding + digest, handle: handle)
      } catch {
        deviceKeyLost()
        return nil
      }
      try await channel.send(.refresh(op: 1, refreshToken: refresh, signature: signature))
      switch try await channel.receive() {
      case .tokens(1, let access, _, let rotated):
        try credentials.write(.refreshToken, Data(rotated.utf8))
        try credentials.write(.accessToken, Data(access.utf8))
        accessIssuedAt = clock.now()
        credentials.accessTokenIssuedAt = accessIssuedAt
        preferences.remoteNotice = nil
        if preferences.remoteState != .approved { preferences.remoteState = .approved }
        scheduleRefresh()
        return access
      case .error(_, let code):
        apply(code)
        return nil
      default:
        return nil
      }
    } catch let error as RemoteChannelError {
      switch error {
      case .pinMismatch: handlePinMismatch()
      case .server(let code): apply(code)
      default: break
      }
      return nil
    } catch {
      return nil
    }
  }

  /// Refreshes 12 minutes after issue while remote dictation stays on and approved.
  private func scheduleRefresh() {
    scheduledRefresh?.cancel()
    guard let issued = accessIssuedAt else { return }
    let due = issued + Self.refreshAfter
    scheduledRefresh = Task { [clock] in
      do { try await clock.sleep(for: due - clock.now()) } catch { return }
      guard !Task.isCancelled, preferences.remoteState == .approved, origin != nil else { return }
      _ = await refreshNow()
    }
  }

  // MARK: Server answers

  /// Applies an error code the server sent on any channel (FR-005, User Story 3).
  public func apply(_ code: RemoteErrorCode) {
    switch code {
    case .revoked:
      try? credentials.remove(.accessToken)
      try? credentials.remove(.refreshToken)
      accessIssuedAt = nil
      scheduledRefresh?.cancel()
      preferences.remoteState = .revoked
    case .notApproved:
      // The refresh token stays valid; a rejected device stays shown as rejected.
      try? credentials.remove(.accessToken)
      accessIssuedAt = nil
      if preferences.remoteState != .rejected { preferences.remoteState = .pending }
    case .unauthorized:
      // The refresh token or signature was refused: enrollment has to run again.
      try? credentials.remove(.accessToken)
      try? credentials.remove(.refreshToken)
      accessIssuedAt = nil
      preferences.remoteState = .pinned
      preferences.remoteNotice = .signInAgain
    case .unsupportedVersion:
      preferences.remoteNotice = .updateRequired
    case .tokenExpired:
      try? credentials.remove(.accessToken)
      accessIssuedAt = nil
    default: break
    }
  }

  /// Close code 4001 or a different identity: refuse to send anything until the user
  /// enrolls again. The pin is never replaced here.
  public func handlePinMismatch() {
    try? credentials.remove(.accessToken)
    accessIssuedAt = nil
    scheduledRefresh?.cancel()
    preferences.remoteState = .pinMismatch
  }

  /// The Secure Enclave no longer loads the key (for example after a restore onto new
  /// hardware): tokens go, dictation stays local, and the user must sign in again.
  private func deviceKeyLost() {
    try? credentials.remove(.accessToken)
    try? credentials.remove(.refreshToken)
    try? credentials.remove(.deviceKey)
    accessIssuedAt = nil
    scheduledRefresh?.cancel()
    preferences.remoteState = .pinned
    preferences.remoteNotice = .signInAgain
    log.notice("Remote device key unavailable; enrollment required")
  }

  // MARK: Turning off

  /// FR-003: deletes the four Keychain items and the `remote.*` settings except
  /// `remote.enabled = false`. History is untouched.
  public func turnOff() {
    refreshing?.cancel()
    scheduledRefresh?.cancel()
    scheduledRefresh = nil
    accessIssuedAt = nil
    pairAttempt = nil
    try? credentials.removeAll()
    preferences.resetRemote()
  }
}

extension RemoteCredentialStoring {
  public func string(_ item: RemoteCredentialItem) -> String? {
    (try? read(item)).flatMap { String(data: $0, encoding: .utf8) }
  }
}

// MARK: Production boundaries

/// Secure Enclave P-256 keys. The handle is the key's `dataRepresentation`, usable only on
/// this Mac's Secure Enclave; the private key never leaves it.
public struct SecureEnclaveDeviceKeys: RemoteDeviceKeys {
  public init() {}

  public func create() throws -> (handle: Data, publicKey: Data) {
    guard SecureEnclave.isAvailable else { throw RemoteEnrollmentError.deviceKeyUnavailable }
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    return (key.dataRepresentation, key.publicKey.x963Representation)
  }

  public func publicKey(handle: Data) -> Data? {
    (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle))?.publicKey
      .x963Representation
  }

  public func sign(_ message: Data, handle: Data) throws -> Data {
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle) else {
      throw RemoteEnrollmentError.deviceKeyUnavailable
    }
    return try key.signature(for: message).derRepresentation
  }
}

/// `GET /v1/remote/identity`: public and content-free, at most 4 KiB.
public struct URLSessionIdentityFetcher: RemoteIdentityFetching {
  public init() {}

  public func fetch(origin: URL) async throws -> RemoteServerIdentity {
    var request = URLRequest(url: origin.appendingPathComponent("v1/remote/identity"))
    request.timeoutInterval = 10
    request.httpShouldHandleCookies = false
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    let (data, response) = try await URLSession(configuration: configuration).data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_096 else {
      throw RemoteEnrollmentError.invalidIdentity
    }
    do { return try JSONDecoder().decode(RemoteServerIdentity.self, from: data) } catch {
      throw RemoteEnrollmentError.invalidIdentity
    }
  }
}

/// Sign in with Apple (native) and Google (authorization code with PKCE in
/// `ASWebAuthenticationSession`). Only the ID token leaves this type, to flowd.
@MainActor
public final class SystemIdentitySignIn: NSObject, IdentitySignIn, @unchecked Sendable {
  /// The per-variant Google iOS OAuth client, from the caller (the Mac reads Info.plist
  /// `LocalFlowGoogleClientID`); Google sign-in is hidden when it is empty.
  public let googleClientID: String
  /// The window sign-in sheets attach to.
  private let presentationAnchor: @MainActor () -> ASPresentationAnchor
  private var appleContinuation: CheckedContinuation<String, any Error>?
  private var webSession: ASWebAuthenticationSession?
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")

  public init(
    googleClientID: String?, presentationAnchor: @escaping @MainActor () -> ASPresentationAnchor
  ) {
    self.googleClientID = googleClientID?.trimmingCharacters(in: .whitespaces) ?? ""
    self.presentationAnchor = presentationAnchor
  }

  public nonisolated func isAvailable(_ provider: IdentityProvider) -> Bool {
    switch provider {
    case .apple: true
    case .google: MainActor.assumeIsolated { !googleClientID.isEmpty }
    }
  }

  public nonisolated func signIn(provider: IdentityProvider, nonce: String) async throws -> String {
    switch provider {
    case .apple: try await appleSignIn(nonce: nonce)
    case .google: try await googleSignIn(nonce: nonce)
    }
  }

  private func appleSignIn(nonce: String) async throws -> String {
    let request = ASAuthorizationAppleIDProvider().createRequest()
    // The nonce is already the SHA-256 of the channel-bound value; Apple copies it as is.
    request.nonce = nonce
    request.requestedScopes = [.email]
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    return try await withCheckedThrowingContinuation { continuation in
      appleContinuation = continuation
      controller.performRequests()
    }
  }

  private func googleSignIn(nonce: String) async throws -> String {
    guard !googleClientID.isEmpty else { throw RemoteEnrollmentError.signInFailed }
    // The reverse client ID is the redirect scheme Google issues for iOS clients.
    let scheme = googleClientID.split(separator: ".").reversed().joined(separator: ".")
    let verifier = Self.randomURLSafe(32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    let state = Self.randomURLSafe(16)
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      .init(name: "client_id", value: googleClientID),
      .init(name: "redirect_uri", value: "\(scheme):/oauth2redirect"),
      .init(name: "response_type", value: "code"),
      .init(name: "scope", value: "openid email"),
      .init(name: "code_challenge", value: challenge),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "state", value: state),
      .init(name: "nonce", value: nonce),
    ]
    let log = log
    let callback: URL = try await withCheckedThrowingContinuation { continuation in
      // AuthenticationServices calls this on an XPC queue, not the main actor.
      let session = ASWebAuthenticationSession(
        url: components.url!, callbackURLScheme: scheme
      ) { @Sendable url, error in
        if let url {
          continuation.resume(returning: url)
        } else {
          // Domain and code only: they carry no account or token data.
          let failure = error.map { $0 as NSError }
          log.error(
            "google_sign_in_failed domain=\(failure?.domain ?? "none", privacy: .public) code=\(failure?.code ?? 0, privacy: .public)"
          )
          continuation.resume(throwing: error ?? RemoteEnrollmentError.signInFailed)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = true
      webSession = session
      session.start()
    }
    webSession = nil
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard items.first(where: { $0.name == "state" })?.value == state,
      let code = items.first(where: { $0.name == "code" })?.value
    else { throw RemoteEnrollmentError.signInFailed }
    var exchange = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    exchange.httpMethod = "POST"
    exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var body = URLComponents()
    body.queryItems = [
      .init(name: "code", value: code), .init(name: "client_id", value: googleClientID),
      .init(name: "code_verifier", value: verifier),
      .init(name: "redirect_uri", value: "\(scheme):/oauth2redirect"),
      .init(name: "grant_type", value: "authorization_code"),
    ]
    exchange.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    let (data, response) = try await URLSession(configuration: configuration).data(for: exchange)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let idToken = object["id_token"] as? String
    else { throw RemoteEnrollmentError.signInFailed }
    return idToken
  }

  private static func randomURLSafe(_ bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
    }
    return data.base64URL
  }
}

extension SystemIdentitySignIn: ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding,
  ASWebAuthenticationPresentationContextProviding
{
  public nonisolated func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    let token = (authorization.credential as? ASAuthorizationAppleIDCredential)?.identityToken
      .flatMap { String(data: $0, encoding: .utf8) }
    MainActor.assumeIsolated {
      if let token {
        appleContinuation?.resume(returning: token)
      } else {
        appleContinuation?.resume(throwing: RemoteEnrollmentError.signInFailed)
      }
      appleContinuation = nil
    }
  }

  public nonisolated func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: any Error
  ) {
    MainActor.assumeIsolated {
      appleContinuation?.resume(throwing: RemoteEnrollmentError.signInFailed)
      appleContinuation = nil
    }
  }

  public nonisolated func presentationAnchor(for controller: ASAuthorizationController)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { presentationAnchor() }
  }

  public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { presentationAnchor() }
  }
}
