import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import OSLog

/// The display cache of this device's server state (`remote.state`). The server decides;
/// the app only shows what it last heard.
enum RemoteDictationState: String, CaseIterable, Sendable {
  case off, pinned, pending, approved, rejected, revoked
  case pinMismatch = "pin_mismatch"
}

/// A one-off instruction the status line shows beside the state (`remote.notice`).
enum RemoteDictationNotice: String, CaseIterable, Sendable {
  /// The device key or tokens are gone; enrollment must run again.
  case signInAgain = "sign_in_again"
  /// The server answered `unsupported_version`.
  case updateRequired = "update_required"
}

/// The press-time snapshot of the remote settings (FR-017: one decision per dictation).
struct RemoteDictationSettings: Sendable, Equatable {
  static let defaultFallbackThreshold = Duration.milliseconds(1_500)
  var enabled = false
  var serverOrigin: URL?
  var state: RemoteDictationState = .off
  var fallbackThreshold = RemoteDictationSettings.defaultFallbackThreshold
  /// False under Settings › Server › Server only: a failed or missing server never
  /// falls back to the local model.
  var localModelsAllowed = true
  /// Settings › Server › Advanced › Dictation: This Mac. Speech stays on this Mac while
  /// rewriting and the rest still use the server.
  var dictationOnThisMac = false

  static let off = RemoteDictationSettings()

  /// Remote recognition is attempted only for an approved device with a pinned server.
  var routesToServer: Bool { enabled && serverOrigin != nil && state == .approved }
  /// Dictation audio streams to the server.
  var streamsDictation: Bool { routesToServer && !dictationOnThisMac }

  /// An `https://` origin with no path, query, fragment or credentials; nil otherwise.
  static func origin(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed), components.scheme == "https",
      let host = components.host, !host.isEmpty, components.user == nil,
      components.password == nil, components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host.lowercased()
    origin.port = components.port
    return origin.url
  }
}

enum RemoteEnrollmentError: Error, Equatable, Sendable {
  /// Consent is not confirmed or no server address is set: nothing may connect.
  case notConfigured
  /// The identity endpoint answered something other than a v1 identity.
  case invalidIdentity
  /// The Secure Enclave can no longer load this device's key.
  case deviceKeyUnavailable
  case signInFailed
  /// The server answered with an unexpected message.
  case protocolError
}

/// Enrollment and credentials for remote dictation (User Story 2): server identity and
/// pinning, Sign in with Apple or Google bound to the channel, the Secure Enclave key,
/// token refresh, state updates and turning the feature off. Main-actor confined; it
/// writes the display state into `AppPreferences`.
@MainActor
final class RemoteEnrollment {
  /// Access tokens live 15 minutes on the server; the client refreshes after 12.
  static let refreshAfter = Duration.seconds(12 * 60)

  private let preferences: AppPreferences
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
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")

  init(
    preferences: AppPreferences, credentials: any RemoteCredentialStoring,
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

  var state: RemoteDictationState { preferences.remoteState }

  /// `wss://<host>/v1/remote/channel` for the configured origin.
  static func channelURL(origin: URL) -> URL? {
    guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = "wss"
    components.path = "/v1/remote/channel"
    return components.url
  }

  private var origin: URL? {
    guard preferences.remoteConsentVersion >= AppPreferences.remoteDictationConsentVersion,
      preferences.remoteEnabled
    else { return nil }
    return RemoteDictationSettings.origin(preferences.remoteServerURL)
  }

  // MARK: Identity and pinning

  /// Fetches the server identity for the user to compare. Nothing connects before the
  /// consent step and a server address.
  func fetchServerIdentity() async throws -> RemoteServerIdentity {
    guard let origin else { throw RemoteEnrollmentError.notConfigured }
    let identity = try await identityFetcher.fetch(origin: origin)
    guard identity.validatedKey() != nil else { throw RemoteEnrollmentError.invalidIdentity }
    return identity
  }

  /// Pins the key the user saw. Only enrollment pins; a later mismatch never re-pins.
  func pin(_ identity: RemoteServerIdentity) throws {
    guard origin != nil else { throw RemoteEnrollmentError.notConfigured }
    guard let key = identity.validatedKey() else { throw RemoteEnrollmentError.invalidIdentity }
    try credentials.removeAll()
    accessIssuedAt = nil
    try credentials.write(.serverKey, key)
    preferences.remoteNotice = nil
    preferences.remoteState = .pinned
  }

  var pinnedKey: Data? { try? credentials.read(.serverKey) }

  // MARK: Enrollment

  /// Creates the device key, signs in with the provider on a nonce bound to this
  /// channel, and registers the device. Returns the server's state for it.
  @discardableResult
  func enroll(provider: IdentityProvider) async throws -> RemoteEnrollmentState {
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

  // MARK: Tokens

  /// A live access token for a session channel, refreshing first when it is 12 minutes
  /// old by the monotonic clock or its issue time is unknown. Nil when the device is not
  /// approved or the refresh failed; the dictation then runs locally.
  func accessToken() async -> String? {
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
  func refreshIfPending() {
    guard origin != nil, preferences.remoteState == .pending, refreshing == nil else { return }
    Task { _ = await refreshNow() }
  }

  /// After `token_expired`: the token is dropped and refreshed now.
  func accessTokenExpired() async -> String? {
    try? credentials.remove(.accessToken)
    accessIssuedAt = nil
    return await refreshNow()
  }

  /// One refresh at a time; concurrent callers share it.
  @discardableResult
  func refreshNow() async -> String? {
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
        (credentials as? RemoteCredentialStore)?.accessTokenIssuedAt = accessIssuedAt
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
  func apply(_ code: RemoteErrorCode) {
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
  func handlePinMismatch() {
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
  func turnOff() {
    refreshing?.cancel()
    scheduledRefresh?.cancel()
    scheduledRefresh = nil
    accessIssuedAt = nil
    try? credentials.removeAll()
    preferences.resetRemote()
  }
}

extension RemoteCredentialStoring {
  func string(_ item: RemoteCredentialItem) -> String? {
    (try? read(item)).flatMap { String(data: $0, encoding: .utf8) }
  }
}

// MARK: Production boundaries

/// Secure Enclave P-256 keys. The handle is the key's `dataRepresentation`, usable only on
/// this Mac's Secure Enclave; the private key never leaves it.
struct SecureEnclaveDeviceKeys: RemoteDeviceKeys {
  func create() throws -> (handle: Data, publicKey: Data) {
    guard SecureEnclave.isAvailable else { throw RemoteEnrollmentError.deviceKeyUnavailable }
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    return (key.dataRepresentation, key.publicKey.x963Representation)
  }

  func publicKey(handle: Data) -> Data? {
    (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle))?.publicKey
      .x963Representation
  }

  func sign(_ message: Data, handle: Data) throws -> Data {
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle) else {
      throw RemoteEnrollmentError.deviceKeyUnavailable
    }
    return try key.signature(for: message).derRepresentation
  }
}

/// `GET /v1/remote/identity`: public and content-free, at most 4 KiB.
struct URLSessionIdentityFetcher: RemoteIdentityFetching {
  func fetch(origin: URL) async throws -> RemoteServerIdentity {
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
final class SystemIdentitySignIn: NSObject, IdentitySignIn, @unchecked Sendable {
  /// The per-variant Google iOS OAuth client (Info.plist `LocalFlowGoogleClientID`);
  /// Google sign-in is hidden when it is empty.
  let googleClientID: String
  private var appleContinuation: CheckedContinuation<String, any Error>?
  private var webSession: ASWebAuthenticationSession?
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")

  init(
    googleClientID: String? = Bundle.main.object(forInfoDictionaryKey: "LocalFlowGoogleClientID")
      as? String
  ) {
    self.googleClientID = googleClientID?.trimmingCharacters(in: .whitespaces) ?? ""
  }

  nonisolated func isAvailable(_ provider: IdentityProvider) -> Bool {
    switch provider {
    case .apple: true
    case .google: MainActor.assumeIsolated { !googleClientID.isEmpty }
    }
  }

  nonisolated func signIn(provider: IdentityProvider, nonce: String) async throws -> String {
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
  nonisolated func authorizationController(
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

  nonisolated func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: any Error
  ) {
    MainActor.assumeIsolated {
      appleContinuation?.resume(throwing: RemoteEnrollmentError.signInFailed)
      appleContinuation = nil
    }
  }

  nonisolated func presentationAnchor(for controller: ASAuthorizationController)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
  }
}
