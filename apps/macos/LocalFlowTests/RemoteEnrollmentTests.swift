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
  /// nil answers `enrolled`; otherwise the error code. `pairDrops` closes without a reply
  /// once, as a lost reply looks to the client.
  var pairError: String?
  var pairDrops = 0
  /// A flowd from before Feature 027: `pair` is an unknown message type.
  var oldServer = false
  private(set) var pairs: [(token: String, key: Data?, signatureValid: Bool)] = []
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
    case "pair":
      if oldServer {
        return [.message(["type": "error", "code": "invalid_message"]), .close(1008)]
      }
      let key = Data(base64URL: object["device_key"] as? String ?? "")
      devicePublicKey = key
      pairs.append(
        (
          object["pairing_token"] as? String ?? "", key,
          verify(
            object["signature"] as? String, message: Data("localflow-v1-pair".utf8) + binding,
            key: key)
        ))
      if pairDrops > 0 {
        pairDrops -= 1
        return [.close(1006)]
      }
      if let pairError { return [.message(["type": "error", "op": op, "code": pairError])] }
      return [
        .message([
          "type": "enrolled", "op": op, "state": "approved", "refresh_token": currentRefresh,
        ])
      ]
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

  // MARK: Pairing (Feature 027)

  private func pairingToken(key: Data = FakeRemoteServer.serverKey.publicKey.rawRepresentation)
    throws -> PairingToken
  {
    let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    return try XCTUnwrap(PairingToken("lfp_" + (key + random).base64URL))
  }

  func testPairPinsStoresCredentialsAndRefreshes() async throws {
    configure()
    let token = try pairingToken()
    try await enrollment.pair(token: token)
    XCTAssertEqual(flowd.pairs.map(\.token), [token.value])
    XCTAssertEqual(flowd.pairs.first?.signatureValid, true)
    XCTAssertEqual(try credentials.read(.serverKey), token.serverKey)
    XCTAssertNotNil(try credentials.read(.deviceKey))
    XCTAssertEqual(preferences.remoteState, .approved)
    // The enrolled refresh token was swapped straight away.
    XCTAssertEqual(flowd.refreshSignaturesValid, [true])
    XCTAssertEqual(credentials.string(.accessToken), "lfa_1")
    XCTAssertTrue(signIn.nonces.isEmpty)
  }

  func testNothingConnectsBeforeConsent() async throws {
    preferences.setRemoteServerURL("https://mini.example.com")
    do {
      try await enrollment.pair(token: try pairingToken())
      XCTFail("expected refusal without consent")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .notConfigured) }
    XCTAssertEqual(fetcher.fetches, 0)
    XCTAssertEqual(opener.openCount, 0)
  }

  /// SC-003: the identity endpoint names another key, so no socket opens at all.
  func testAWrongKeyAtTheAddressNeverReceivesTheToken() async throws {
    configure()
    let token = try pairingToken(
      key: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
    do {
      try await enrollment.pair(token: token)
      XCTFail("expected a wrong-server refusal")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .wrongServer) }
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertTrue(flowd.pairs.isEmpty)
    XCTAssertTrue(credentials.isEmpty)
    XCTAssertEqual(preferences.remoteState, .off)
  }

  /// An impostor repeats the token's key at the identity endpoint but can't hold the private
  /// key: the hello doesn't open, and the token is never sent.
  func testAnImpostorRepeatingTheKeyNeverReceivesTheToken() async throws {
    configure()
    let impostor = FakeRemoteServer(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let transport = flowd.transport(server: impostor)
    let enrollment = RemoteEnrollment(
      preferences: preferences, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: fetcher, transports: FakeRemoteTransportOpener { _ in transport },
      clock: clock, deviceName: "Test Mac")
    do {
      try await enrollment.pair(token: try pairingToken())
      XCTFail("expected a wrong-server refusal")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .wrongServer) }
    XCTAssertTrue(transport.receivedEvents.isEmpty)
    XCTAssertTrue(credentials.isEmpty)
  }

  /// flowd's decoder refuses an unknown type with invalid_message; a newer schema is
  /// unsupported_version. Both mean: update, and the token is unspent.
  func testAnOldServerMapsToUpdateRequired() async throws {
    for code in ["invalid_message", "unsupported_version"] {
      configure()
      flowd.pairError = code
      do {
        try await enrollment.pair(token: try pairingToken())
        XCTFail("expected update required")
      } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .updateRequired) }
      XCTAssertEqual(preferences.remoteNotice, .updateRequired)
      XCTAssertEqual(preferences.remoteState, .off)
      XCTAssertTrue(credentials.isEmpty)
    }
  }

  func testARefusedTokenLeavesAWorkingDeviceAlone() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
    let refresh = credentials.string(.refreshToken)
    let device = try credentials.read(.deviceKey)
    for code in ["pairing_token_invalid", "unauthorized", "revoked", "busy"] {
      flowd.pairError = code
      do {
        try await enrollment.pair(token: try pairingToken())
        XCTFail("expected a refusal")
      } catch {
        XCTAssertEqual(error as? RemoteChannelError, .server(RemoteErrorCode(rawValue: code)!))
      }
      XCTAssertEqual(preferences.remoteState, .approved)
      XCTAssertEqual(credentials.string(.refreshToken), refresh)
      XCTAssertEqual(try credentials.read(.deviceKey), device)
    }
  }

  /// The server may have spent the token before the reply was lost; only the same key may
  /// retry, so a retry must not make a new one.
  func testALostReplyRetriesWithTheSameDeviceKey() async throws {
    configure()
    flowd.pairDrops = 1
    let token = try pairingToken()
    do {
      try await enrollment.pair(token: token)
      XCTFail("expected the channel to fail")
    } catch { XCTAssertEqual(error as? RemoteChannelError, .unreachable) }
    XCTAssertTrue(credentials.isEmpty)
    try await enrollment.pair(token: token)
    XCTAssertEqual(keys.created, 1)
    XCTAssertEqual(flowd.pairs.count, 2)
    XCTAssertEqual(flowd.pairs[0].key, flowd.pairs[1].key)
    XCTAssertEqual(preferences.remoteState, .approved)
  }

  // MARK: Changing the address (Feature 027, FR-013)

  private func approvedDevice() async throws {
    try await pinned()
    flowd.enrollAnswer = .enrolled(.approved)
    try await enrollment.enroll(provider: .apple)
  }

  func testANewAddressWithThePinnedKeyChangesOnlyTheAddress() async throws {
    try await approvedDevice()
    let before = try RemoteCredentialItem.allCases.map { try credentials.read($0) }
    let refreshes = flowd.refreshCount
    let opened = opener.openCount
    let created = keys.created
    try await enrollment.updateAddress(to: try XCTUnwrap(URL(string: "http://192.168.1.20:8090")))
    XCTAssertEqual(preferences.remoteServerURL, "http://192.168.1.20:8090")
    XCTAssertEqual(try RemoteCredentialItem.allCases.map { try credentials.read($0) }, before)
    XCTAssertEqual(preferences.remoteState, .approved)
    XCTAssertEqual(flowd.refreshCount, refreshes)
    // One channel to prove the route; it sends nothing but its hello.
    XCTAssertEqual(opener.openCount, opened + 1)
    XCTAssertEqual(keys.created, created)
    XCTAssertTrue(signIn.nonces.count == 1)
    // The access token still works, and the next refresh goes to the new address.
    let token = await enrollment.accessToken()
    XCTAssertEqual(token, "lfa_1")
    _ = await enrollment.accessTokenExpired()
    XCTAssertEqual(opener.urls.last?.absoluteString, "ws://192.168.1.20:8090/v1/remote/channel")
  }

  func testANewAddressWithAnotherKeyIsRefusedAndChangesNothing() async throws {
    try await approvedDevice()
    let before = try RemoteCredentialItem.allCases.map { try credentials.read($0) }
    fetcher.key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    do {
      try await enrollment.updateAddress(to: try XCTUnwrap(URL(string: "https://other.example")))
      XCTFail("expected a refusal")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .wrongServer) }
    XCTAssertEqual(preferences.remoteServerURL, "https://mini.example.com")
    XCTAssertEqual(try RemoteCredentialItem.allCases.map { try credentials.read($0) }, before)
    XCTAssertEqual(preferences.remoteState, .approved)
  }

  /// A proxy that answers HTTP but strips WebSocket upgrades: reported as a bad route, and
  /// neither the address nor the token moves.
  func testARouteWithoutWebSocketsIsReportedAndChangesNothing() async throws {
    try await approvedDevice()
    let before = try RemoteCredentialItem.allCases.map { try credentials.read($0) }
    let stripped = RemoteEnrollment(
      preferences: preferences, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: fetcher, transports: UnreachableTransportOpener(),
      clock: clock, deviceName: "Test Mac")
    do {
      try await stripped.updateAddress(to: try XCTUnwrap(URL(string: "https://proxy.example")))
      XCTFail("expected a refusal")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .unusableRoute) }
    XCTAssertEqual(preferences.remoteServerURL, "https://mini.example.com")
    XCTAssertEqual(try RemoteCredentialItem.allCases.map { try credentials.read($0) }, before)
    do {
      try await stripped.pair(token: try pairingToken())
      XCTFail("expected a refusal")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .unusableRoute) }
    XCTAssertTrue(flowd.pairs.isEmpty)
    XCTAssertEqual(
      pairingFailureMessage(RemoteEnrollmentError.unusableRoute),
      "This address isn't a usable LocalFlow route: it answers, but a proxy may be blocking WebSockets or changing paths."
    )
  }

  func testAnAddressChangeNeedsAPinAndAPermittedAddress() async throws {
    configure()
    let url = try XCTUnwrap(URL(string: "https://other.example"))
    do {
      try await enrollment.updateAddress(to: url)
      XCTFail("no pin")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .notConfigured) }
    try await pinned()
    let fetches = fetcher.fetches
    do {
      try await enrollment.updateAddress(to: try XCTUnwrap(URL(string: "http://8.8.8.8")))
      XCTFail("public http")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .notConfigured) }
    XCTAssertEqual(fetcher.fetches, fetches)
  }

  // MARK: Existing installs (Feature 027, US5)

  /// The whole old-server answer: an unknown type gets invalid_message with no op, then a close.
  /// The server has no tokens, so nothing was spent; a working device stays as it was, and
  /// the same token still goes through after the server is updated.
  func testANewClientAgainstAnOldServer() async throws {
    try await approvedDevice()
    let before = try RemoteCredentialItem.allCases.map { try credentials.read($0) }
    let token = try pairingToken()
    flowd.oldServer = true
    do {
      try await enrollment.pair(token: token)
      XCTFail("expected update required")
    } catch { XCTAssertEqual(error as? RemoteEnrollmentError, .updateRequired) }
    XCTAssertEqual(preferences.remoteState, .approved)
    XCTAssertEqual(try RemoteCredentialItem.allCases.map { try credentials.read($0) }, before)
    XCTAssertEqual(
      pairingFailureMessage(RemoteEnrollmentError.updateRequired),
      "Update the LocalFlow server to pair with a token. The token was not used.")
    flowd.oldServer = false
    try await enrollment.pair(token: token)
    XCTAssertEqual(flowd.pairs.map(\.token), [token.value])
  }

  /// `scripts/test-pairing-e2e.sh` serves real flowd code on loopback and names it here.
  /// The client is the real one down to `URLSession`; only the device key and Keychain are
  /// test doubles.
  func testPairAgainstARealServer() async throws {
    let info = ProcessInfo.processInfo.environment["LOCALFLOW_E2E_INFO"] ?? ""
    try XCTSkipIf(info.isEmpty, "LOCALFLOW_E2E_INFO not set")
    let served = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: info)))
        as? [String: String])
    configure()
    XCTAssertTrue(preferences.setRemoteServerURL(try XCTUnwrap(served["origin"])))
    let enrollment = RemoteEnrollment(
      preferences: preferences, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: URLSessionIdentityFetcher(), transports: URLSessionRemoteTransportOpener(),
      deviceName: "E2E Mac")
    let token = try XCTUnwrap(PairingToken(try XCTUnwrap(served["token"])))
    try await enrollment.pair(token: token)
    XCTAssertEqual(preferences.remoteState, .approved)
    XCTAssertEqual(try credentials.read(.serverKey), token.serverKey)
    let access = credentials.string(.accessToken)
    XCTAssertTrue(access?.hasPrefix("lfa_") == true, "the refresh after pairing failed")
    // A session hello with that token gets `ready`.
    let channel = try RemoteChannel(
      transport: URLSessionRemoteTransport(
        url: try XCTUnwrap(
          RemoteEnrollment.channelURL(origin: try XCTUnwrap(URL(string: served["origin"]!))))),
      serverKey: token.serverKey)
    try await channel.open(purpose: .session, accessToken: try XCTUnwrap(access))
    await channel.close()
    // The same origin is a legal address change to itself: the identity matches the pin.
    try await enrollment.updateAddress(to: try XCTUnwrap(URL(string: served["origin"]!)))
  }

  func testChannelURLIsTheWebSocketPath() {
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "https://mini.example.com")!)?.absoluteString,
      "wss://mini.example.com/v1/remote/channel")
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "https://mini.example.com:8443")!)?
        .absoluteString, "wss://mini.example.com:8443/v1/remote/channel")
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "http://[fd7a:115c:a1e0::1]:8090")!)?
        .absoluteString, "ws://[fd7a:115c:a1e0::1]:8090/v1/remote/channel")
    XCTAssertEqual(
      RemoteEnrollment.channelURL(origin: URL(string: "http://mini.local:8090")!)?.absoluteString,
      "ws://mini.local:8090/v1/remote/channel")
    // A refused origin never gets a socket, however it got here.
    XCTAssertNil(RemoteEnrollment.channelURL(origin: URL(string: "http://example.com")!))
    XCTAssertNil(RemoteEnrollment.channelURL(origin: URL(string: "http://8.8.8.8:8090")!))
    XCTAssertNil(RemoteEnrollment.channelURL(origin: URL(string: "https://a.example/x")!))
  }
}

/// A route that answers the identity request and then fails the WebSocket upgrade.
private final class UnreachableTransport: RemoteTransport, @unchecked Sendable {
  func send(_ data: Data) async throws { throw RemoteTransportError.unreachable }
  func receive() async throws -> RemoteTransportMessage { throw RemoteTransportError.unreachable }
  func close(code: Int) {}
}

private struct UnreachableTransportOpener: RemoteTransportOpening {
  func open(_ url: URL) async throws -> any RemoteTransport { UnreachableTransport() }
}
