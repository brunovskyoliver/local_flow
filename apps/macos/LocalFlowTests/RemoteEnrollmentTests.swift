import CryptoKit
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// A scripted flowd for enrollment and refresh: it verifies device signatures over the
/// channel binding and the ID token nonce, and answers as the account store would.
final class FakeFlowdAccounts: @unchecked Sendable {
  enum Answer {
    case enrolled(RemoteEnrollmentState)
    case error(String)
  }
  let lock = NSLock()
  var enrollAnswer: Answer = .enrolled(.pending)
  /// nil answers `tokens`; otherwise the error code.
  var refreshError: String?
  var devicePublicKey: Data?
  private(set) var enrollSignatureValid = false
  private(set) var refreshSignaturesValid: [Bool] = []
  private(set) var nonces: [String] = []
  private(set) var refreshCount = 0
  private(set) var issuedAccess: [String] = []
  var currentRefresh = "lfr_initial"

  func transport(server: FakeRemoteServer = FakeRemoteServer()) -> FakeRemoteTransport {
    var binding = Data()
    return FakeRemoteTransport(server: server) { [self] event in
      switch event {
      case .hello(let purpose, _, let channelBinding):
        binding = channelBinding
        guard purpose == "enroll" || purpose == "refresh" else { return [.close(1008)] }
        return [.message(["type": "ready"])]
      case .control(let object):
        return lock.withLock { answer(object, binding: binding) }
      case .audio, .s16:
        return [.close(1008)]
      }
    }
  }

  private func verify(_ signature: String?, message: Data, key: Data?) -> Bool {
    guard let signature, let der = Data(base64URL: signature), let key,
      let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
      let parsed = try? P256.Signing.ECDSASignature(derRepresentation: der)
    else { return false }
    return publicKey.isValidSignature(parsed, for: message)
  }

  private func answer(_ object: [String: Any], binding: Data) -> [FakeServerReply] {
    let op = object["op"] as? Int ?? 0
    switch object["type"] as? String {
    case "enroll":
      let key = Data(base64URL: object["device_key"] as? String ?? "")
      devicePublicKey = key
      enrollSignatureValid = verify(
        object["signature"] as? String, message: Data("localflow-v1-enroll".utf8) + binding,
        key: key)
      nonces.append(binding.base64URL)
      switch enrollAnswer {
      case .enrolled(let state):
        var message: [String: Any] = ["type": "enrolled", "op": op, "state": state.rawValue]
        if state != .rejected { message["refresh_token"] = currentRefresh }
        return [.message(message)]
      case .error(let code):
        return [.message(["type": "error", "op": op, "code": code])]
      }
    case "refresh":
      refreshCount += 1
      let presented = object["refresh_token"] as? String ?? ""
      let digest = Data(SHA256.hash(data: Data(presented.utf8)))
      refreshSignaturesValid.append(
        verify(
          object["signature"] as? String,
          message: Data("localflow-v1-refresh".utf8) + binding + digest, key: devicePublicKey)
          && presented == currentRefresh)
      if let refreshError {
        return [.message(["type": "error", "op": op, "code": refreshError])]
      }
      let access = "lfa_\(refreshCount)"
      issuedAccess.append(access)
      currentRefresh = "lfr_\(refreshCount)"
      return [
        .message([
          "type": "tokens", "op": op, "access_token": access, "expires_in": 900,
          "refresh_token": currentRefresh,
        ])
      ]
    default:
      return [.message(["type": "error", "op": op, "code": "invalid_message"])]
    }
  }
}

@MainActor
final class RemoteEnrollmentTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var preferences: AppPreferences!
  private var credentials: InMemoryRemoteCredentialStore!
  private var keys: SoftwareDeviceKeys!
  private var signIn: FakeIdentitySignIn!
  private var fetcher: FakeIdentityFetcher!
  private var clock: ManualRemoteClock!
  private var flowd: FakeFlowdAccounts!
  private var opener: FakeRemoteTransportOpener!
  private var enrollment: RemoteEnrollment!

  override func setUp() async throws {
    suite = "LocalFlow-enrollment-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    preferences = AppPreferences(defaults: defaults)
    credentials = InMemoryRemoteCredentialStore()
    keys = SoftwareDeviceKeys()
    signIn = FakeIdentitySignIn()
    fetcher = FakeIdentityFetcher(key: FakeRemoteServer.serverKey.publicKey.rawRepresentation)
    clock = ManualRemoteClock()
    flowd = FakeFlowdAccounts()
    let flowd = flowd!
    opener = FakeRemoteTransportOpener { _ in flowd.transport() }
    enrollment = RemoteEnrollment(
      preferences: preferences, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: fetcher, transports: opener, clock: clock, deviceName: "Test Mac")
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func configure() {
    preferences.remoteEnabled = true
    preferences.confirmRemoteConsent()
    preferences.setRemoteServerURL("https://mini.example.com")
  }

  private func pinned() async throws {
    configure()
    try enrollment.pin(try await enrollment.fetchServerIdentity())
  }

  func testNothingConnectsBeforeConsentAndAServerAddress() async throws {
    preferences.setRemoteServerURL("https://mini.example.com")
    do {
      _ = try await enrollment.fetchServerIdentity()
      XCTFail("expected refusal without consent")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .notConfigured) }
    preferences.remoteEnabled = true
    preferences.confirmRemoteConsent()
    preferences.setRemoteServerURL("https://mini.example.com")
    defaults.set("", forKey: "remote.serverURL")
    let reloaded = AppPreferences(defaults: defaults)
    let noURL = RemoteEnrollment(
      preferences: reloaded, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: fetcher, transports: opener, clock: clock, deviceName: "Test Mac")
    do {
      try await noURL.enroll(provider: .apple)
      XCTFail("expected refusal without a server")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .notConfigured) }
    XCTAssertEqual(fetcher.fetches, 0)
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertTrue(credentials.isEmpty)
  }

  func testIdentityIsShownAndPinnedBeforeAnySignIn() async throws {
    configure()
    let identity = try await enrollment.fetchServerIdentity()
    XCTAssertEqual(
      identity.fingerprint,
      RemoteServerIdentity.fingerprint(of: FakeRemoteServer.serverKey.publicKey.rawRepresentation))
    XCTAssertNil(try credentials.read(.serverKey))
    try enrollment.pin(identity)
    XCTAssertEqual(try credentials.read(.serverKey), fetcher.key)
    XCTAssertEqual(preferences.remoteState, .pinned)
    XCTAssertTrue(signIn.nonces.isEmpty)
    XCTAssertEqual(opener.openCount, 0)
  }

  func testEnrollmentSignsWithANewDeviceKeyAndBindsTheNonce() async throws {
    try await pinned()
    let state = try await enrollment.enroll(provider: .apple)
    XCTAssertEqual(state, .pending)
    XCTAssertEqual(preferences.remoteState, .pending)
    XCTAssertEqual(keys.created, 1)
    XCTAssertTrue(flowd.enrollSignatureValid)
    XCTAssertNotNil(try credentials.read(.deviceKey))
    XCTAssertEqual(credentials.string(.refreshToken), "lfr_initial")
    // Apple gets the SHA-256 of the channel binding's base64url form; Google gets it raw.
    let raw = try XCTUnwrap(flowd.nonces.first)
    XCTAssertEqual(signIn.nonces.first?.1, SHA256Digest.hex(Data(raw.utf8)))
    flowd.enrollAnswer = .enrolled(.pending)
    try await enrollment.enroll(provider: .google)
    XCTAssertEqual(signIn.nonces.last?.1, flowd.nonces.last)
  }

  func testEnrolledStatesAreShown() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.rejected)
    let rejected = try await enrollment.enroll(provider: .apple)
    XCTAssertEqual(rejected, .rejected)
    XCTAssertEqual(preferences.remoteState, .rejected)
    XCTAssertNil(try credentials.read(.refreshToken))
    flowd.enrollAnswer = .enrolled(.approved)
    let approved = try await enrollment.enroll(provider: .apple)
    XCTAssertEqual(approved, .approved)
    XCTAssertEqual(preferences.remoteState, .approved)
    // An approved device refreshes at once and has an access token.
    XCTAssertEqual(credentials.string(.accessToken), "lfa_1")
    XCTAssertEqual(flowd.refreshSignaturesValid, [true])
  }

  func testRefreshFollowsTheMonotonicClockAndTokenExpiry() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    XCTAssertEqual(flowd.refreshCount, 1)
    // The refresh timer must be asleep before the clock moves, or its deadline starts late.
    let scheduled = await eventually { @MainActor in self.clock.sleeperCount > 0 }
    XCTAssertTrue(scheduled)
    // Within 12 minutes the stored token is used as it is.
    clock.advance(by: .seconds(11 * 60))
    let cached = await enrollment.accessToken()
    XCTAssertEqual(cached, "lfa_1")
    XCTAssertEqual(flowd.refreshCount, 1)
    // At 12 minutes the scheduled refresh runs.
    clock.advance(by: .seconds(60))
    let refreshed = await eventually { @MainActor in self.flowd.refreshCount == 2 }
    XCTAssertTrue(refreshed)
    XCTAssertTrue(flowd.refreshSignaturesValid.allSatisfy { $0 })
    // `token_expired` refreshes immediately.
    let renewed = await enrollment.accessTokenExpired()
    XCTAssertEqual(renewed, "lfa_3")
    XCTAssertEqual(credentials.string(.refreshToken), "lfr_3")
  }

  func testPendingDeviceRefreshesOnceAtDictationStart() async throws {
    try await pinned()
    try await enrollment.enroll(provider: .apple)
    XCTAssertEqual(preferences.remoteState, .pending)
    flowd.refreshError = "not_approved"
    enrollment.refreshIfPending()
    let tried = await eventually { @MainActor in self.flowd.refreshCount == 1 }
    XCTAssertTrue(tried)
    XCTAssertEqual(preferences.remoteState, .pending)
    // `not_approved` leaves the refresh token as it was.
    XCTAssertEqual(credentials.string(.refreshToken), "lfr_initial")
    flowd.refreshError = nil
    enrollment.refreshIfPending()
    let approved = await eventually { @MainActor in self.preferences.remoteState == .approved }
    XCTAssertTrue(approved)
    XCTAssertEqual(credentials.string(.accessToken), "lfa_2")
  }

  func testRevokedDeletesTokens() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    flowd.refreshError = "revoked"
    let token = await enrollment.accessTokenExpired()
    XCTAssertNil(token)
    XCTAssertEqual(preferences.remoteState, .revoked)
    XCTAssertNil(try credentials.read(.accessToken))
    XCTAssertNil(try credentials.read(.refreshToken))
    let none = await enrollment.accessToken()
    XCTAssertNil(none)
  }

  func testNotApprovedAndRevokedDuringAnOperationUpdateTheState() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    enrollment.apply(.notApproved)
    XCTAssertEqual(preferences.remoteState, .pending)
    XCTAssertNil(try credentials.read(.accessToken))
    XCTAssertNotNil(try credentials.read(.refreshToken))
    enrollment.apply(.revoked)
    XCTAssertEqual(preferences.remoteState, .revoked)
    XCTAssertNil(try credentials.read(.refreshToken))
    enrollment.apply(.unsupportedVersion)
    XCTAssertEqual(preferences.remoteNotice, .updateRequired)
  }

  func testAChangedServerKeyIsAPinMismatchAndIsNeverRepinned() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    let pinnedKey = try credentials.read(.serverKey)
    // The server was reinstalled with a new key: it cannot open our hello.
    let flowd = flowd!
    let other = FakeRemoteTransportOpener { _ in
      flowd.transport(server: FakeRemoteServer(privateKey: .init()))
    }
    let later = RemoteEnrollment(
      preferences: preferences, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: fetcher, transports: other, clock: clock, deviceName: "Test Mac")
    let token = await later.accessTokenExpired()
    XCTAssertNil(token)
    XCTAssertEqual(preferences.remoteState, .pinMismatch)
    XCTAssertEqual(try credentials.read(.serverKey), pinnedKey)
    XCTAssertEqual(fetcher.fetches, 1)
    let none = await later.accessToken()
    XCTAssertNil(none)
  }

  func testALostDeviceKeyRequiresSigningInAgain() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    keys.lostHandles.insert(try XCTUnwrap(try credentials.read(.deviceKey)))
    let token = await enrollment.accessTokenExpired()
    XCTAssertNil(token)
    XCTAssertEqual(preferences.remoteState, .pinned)
    XCTAssertEqual(preferences.remoteNotice, .signInAgain)
    XCTAssertNil(try credentials.read(.refreshToken))
    XCTAssertNil(try credentials.read(.deviceKey))
    XCTAssertFalse(preferences.remoteSettings().routesToServer)
    XCTAssertEqual(flowd.refreshCount, 1)
  }

  func testTurningOffDeletesCredentialsAndSettingsButNotHistory() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    preferences.rewriteEnabled = true
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let reservation = try await history.reserve()
    _ = try await history.commit(
      reservation: reservation,
      entry: try TranscriptionEntry(
        id: UUID(), text: "kept", createdAtMilliseconds: 1, quality: .complete,
        stopReason: .keyRelease, recognitionPath: .server))
    enrollment.turnOff()
    XCTAssertTrue(credentials.isEmpty)
    XCTAssertEqual(defaults.object(forKey: "remote.enabled") as? Bool, false)
    for key in AppPreferences.remoteKeys where key != "remote.enabled" {
      XCTAssertNil(defaults.object(forKey: key), key)
    }
    XCTAssertTrue(preferences.rewriteEnabled)
    let entries = try await history.recent(limit: 20)
    XCTAssertEqual(entries.count, 1)
    let none = await enrollment.accessToken()
    XCTAssertNil(none)
  }

  func testChannelURLIsTheWebSocketPath() {
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "https://mini.example.com")!)?.absoluteString,
      "wss://mini.example.com/v1/remote/channel")
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "https://mini.example.com:8443")!)?
        .absoluteString, "wss://mini.example.com:8443/v1/remote/channel")
  }
}
