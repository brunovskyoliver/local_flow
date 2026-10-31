import CryptoKit
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// A scripted flowd for the phone: enrollment, refresh and session hellos.
private final class FakePhoneFlowd: @unchecked Sendable {
  let lock = NSLock()
  var enrollState = "pending"
  /// nil answers `tokens`; otherwise the error code.
  var refreshError: String?
  /// nil answers `enrolled`; otherwise the error code.
  var pairError: String?
  private(set) var pairTokens: [String] = []
  /// nil answers `ready` to a session hello; otherwise the error code.
  var sessionError: String?
  private(set) var refreshCount = 0
  private(set) var sessionTokens: [String?] = []

  func transport(server: FakeRemoteServer = FakeRemoteServer()) -> FakeRemoteTransport {
    FakeRemoteTransport(server: server) { [self] event in
      lock.withLock {
        switch event {
        case .hello(let purpose, let token, _):
          if purpose == "session" {
            sessionTokens.append(token)
            if let sessionError { return [.message(["type": "error", "code": sessionError])] }
          }
          return [.message(["type": "ready"])]
        case .control(let object):
          let op = object["op"] as? Int ?? 0
          switch object["type"] as? String {
          case "enroll":
            var message: [String: Any] = ["type": "enrolled", "op": op, "state": enrollState]
            if enrollState != "rejected" { message["refresh_token"] = "lfr_initial" }
            return [.message(message)]
          case "pair":
            pairTokens.append(object["pairing_token"] as? String ?? "")
            if let pairError {
              return [.message(["type": "error", "op": op, "code": pairError])]
            }
            return [
              .message([
                "type": "enrolled", "op": op, "state": "approved", "refresh_token": "lfr_initial",
              ])
            ]
          case "refresh":
            refreshCount += 1
            if let refreshError {
              return [.message(["type": "error", "op": op, "code": refreshError])]
            }
            return [
              .message([
                "type": "tokens", "op": op, "access_token": "lfa_\(refreshCount)",
                "expires_in": 900, "refresh_token": "lfr_\(refreshCount)",
              ])
            ]
          default:
            return [.message(["type": "error", "op": op, "code": "invalid_message"])]
          }
        case .audio, .s16:
          return [.close(1008)]
        }
      }
    }
  }
}

@MainActor
final class PhoneServerConnectionTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var settings: PhoneServerSettings!
  private var credentials: InMemoryRemoteCredentialStore!
  private var signIn: FakeIdentitySignIn!
  private var fetcher: FakeIdentityFetcher!
  private var flowd: FakePhoneFlowd!
  private var opener: FakeRemoteTransportOpener!
  private var connection: PhoneServerConnection!
  /// When set, every new socket reaches a server with this key instead of the pinned one.
  private nonisolated(unsafe) var impostor: Curve25519.KeyAgreement.PrivateKey?

  override func setUp() async throws {
    suite = "LocalFlowPhone-server-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    settings = PhoneServerSettings(defaults: defaults)
    credentials = InMemoryRemoteCredentialStore()
    signIn = FakeIdentitySignIn()
    fetcher = FakeIdentityFetcher(key: FakeRemoteServer.serverKey.publicKey.rawRepresentation)
    flowd = FakePhoneFlowd()
    let flowd = flowd!
    opener = FakeRemoteTransportOpener { [unowned self] _ in
      flowd.transport(
        server: FakeRemoteServer(privateKey: self.impostor ?? FakeRemoteServer.serverKey))
    }
    connection = PhoneServerConnection(
      settings: settings, credentials: credentials, keys: SoftwareDeviceKeys(), signIn: signIn,
      identityFetcher: fetcher, transports: opener, deviceName: "Test iPhone")
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  /// Address, identity, Confirm, Google sign-in.
  private func enroll(as state: String) async {
    flowd.enrollState = state
    connection.addressDraft = "https://server.example"
    await connection.checkIdentity()
    connection.confirmIdentity()
    await connection.signInWithGoogle()
  }

  private func approvedWithSwitchOn() async {
    await enroll(as: "approved")
    connection.setProcessMeetings(true)
    XCTAssertTrue(settings.sendsMeetings)
  }

  // MARK: Fingerprint before sign-in

  func testFingerprintIsConfirmedBeforeSignIn() async {
    XCTAssertEqual(connection.status, .notSignedIn)
    connection.addressDraft = "https://Server.Example/"
    await connection.checkIdentity()

    XCTAssertEqual(settings.serverAddress, "https://server.example")
    let key = FakeRemoteServer.serverKey.publicKey.rawRepresentation
    XCTAssertEqual(connection.identity?.fingerprint, RemoteServerIdentity.fingerprint(of: key))
    XCTAssertEqual(connection.status, .compareFingerprint)
    XCTAssertFalse(connection.needsSignIn)

    // Sign-in before Confirm does nothing: no socket, no provider.
    await connection.signInWithGoogle()
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertTrue(signIn.nonces.isEmpty)
    XCTAssertNil(try credentials.read(.serverKey))

    connection.confirmIdentity()
    XCTAssertEqual(try credentials.read(.serverKey), key)
    XCTAssertEqual(connection.status, .signIn)
    XCTAssertTrue(connection.needsSignIn)
    XCTAssertEqual(connection.pinnedFingerprint, RemoteServerIdentity.fingerprint(of: key))

    await connection.signInWithGoogle()
    XCTAssertEqual(signIn.nonces.map(\.0), [.google])
    XCTAssertEqual(connection.status, .waitingForApproval)
  }

  func testAnInvalidAddressFetchesNothing() async {
    connection.addressDraft = "http://server.example/path"
    await connection.checkIdentity()
    XCTAssertNotNil(connection.error)
    XCTAssertEqual(fetcher.fetches, 0)
    XCTAssertEqual(settings.serverAddress, "")
  }

  // MARK: States

  func testPendingThenApproved() async {
    await enroll(as: "pending")
    XCTAssertEqual(connection.status, .waitingForApproval)
    XCTAssertNotNil(try credentials.read(.refreshToken))
    XCTAssertEqual(connection.status.text, "Waiting for approval")

    // The administrator approved: the next refresh finds out.
    await connection.refresh()
    XCTAssertEqual(connection.state, .approved)
    XCTAssertEqual(connection.status.text, "Approved")
  }

  func testApprovedAtEnrollment() async {
    await enroll(as: "approved")
    XCTAssertEqual(connection.status, .approved)
    XCTAssertEqual(credentials.string(.accessToken), "lfa_1")
    XCTAssertEqual(defaults.string(forKey: "server.state"), "approved")
  }

  func testRejected() async {
    await enroll(as: "rejected")
    XCTAssertEqual(connection.status, .rejected)
    XCTAssertNil(try credentials.read(.refreshToken))
  }

  func testRevokedOnTheNextChannelStopsSending() async throws {
    await approvedWithSwitchOn()
    flowd.lock.withLock { flowd.sessionError = "revoked" }
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("A revoked device opened a channel")
    } catch {}
    XCTAssertEqual(connection.status, .revoked)
    XCTAssertEqual(connection.status.text, "Revoked")
    XCTAssertFalse(settings.sendsMeetings)
    XCTAssertNil(try credentials.read(.refreshToken))

    let opened = opener.openCount
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("A revoked device opened a channel")
    } catch {}
    XCTAssertEqual(opener.openCount, opened)
  }

  func testRevokedAtRefresh() async {
    await enroll(as: "pending")
    flowd.lock.withLock { flowd.refreshError = "revoked" }
    await connection.refresh()
    XCTAssertEqual(connection.status, .revoked)
  }

  func testApprovedChannelOpensAsSession() async throws {
    await approvedWithSwitchOn()
    let channel = try await connection.openSessionChannel()
    await channel.close()
    XCTAssertEqual(flowd.lock.withLock { flowd.sessionTokens }, ["lfa_1"])
    XCTAssertEqual(connection.status, .approved)
    XCTAssertNotNil(connection.capabilities)

    // The pool uses the same opener.
    let (pooled, op) = try await connection.pool.lease(.background)
    XCTAssertEqual(op, 1)
    await connection.pool.release(.background, channel: pooled, nextOp: nil)
    XCTAssertEqual(flowd.lock.withLock { flowd.sessionTokens.count }, 2)
  }

  func testUnreachableServerShowsUnreachable() async throws {
    await approvedWithSwitchOn()
    let failing = FakeRemoteTransportOpener { _ in nil }
    connection = PhoneServerConnection(
      settings: settings, credentials: credentials, keys: SoftwareDeviceKeys(), signIn: signIn,
      identityFetcher: fetcher, transports: failing, deviceName: "Test iPhone")
    // A fresh connection has no issue time, so it refreshes first and that fails.
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened without a server")
    } catch {}
    XCTAssertEqual(connection.status, .unreachable)
    XCTAssertEqual(connection.state, .approved)
  }

  // MARK: Changed identity

  func testChangedIdentityBlocksSendingUntilReconfirmed() async throws {
    await approvedWithSwitchOn()
    let other = FakeRemoteServer(privateKey: Curve25519.KeyAgreement.PrivateKey())
    impostor = other.privateKey

    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened a channel to a different server")
    } catch let error as RemoteChannelError {
      XCTAssertEqual(error, .pinMismatch)
    }
    XCTAssertEqual(connection.status, .identityChanged)
    XCTAssertFalse(settings.sendsMeetings)
    let opened = opener.openCount
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Sent after an identity change")
    } catch {}
    XCTAssertEqual(opener.openCount, opened)

    // Re-confirming the new identity pins it; enrollment has to run again.
    fetcher.key = other.publicKey
    await connection.checkIdentity()
    XCTAssertEqual(
      connection.identity?.fingerprint, RemoteServerIdentity.fingerprint(of: other.publicKey))
    connection.confirmIdentity()
    XCTAssertEqual(try credentials.read(.serverKey), other.publicKey)
    XCTAssertEqual(connection.status, .signIn)
    XCTAssertFalse(settings.sendsMeetings)

    flowd.enrollState = "approved"
    await connection.signInWithGoogle()
    XCTAssertEqual(connection.status, .approved)
    XCTAssertTrue(settings.sendsMeetings)
    let channel = try await connection.openSessionChannel()
    await channel.close()
  }

  // MARK: Nothing opened

  func testNothingOpensWhilePendingEvenWithTheSwitchOn() async {
    await enroll(as: "pending")
    connection.setProcessMeetings(true)
    let opened = opener.openCount
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("A pending device opened a channel")
    } catch {}
    do {
      _ = try await connection.pool.lease(.background)
      XCTFail("A pending device leased a channel")
    } catch {}
    XCTAssertEqual(opener.openCount, opened)
  }

  func testNothingOpensWithTheSwitchOff() async {
    await enroll(as: "approved")
    XCTAssertFalse(settings.processMeetings)
    XCTAssertFalse(settings.sendsMeetings)
    let opened = opener.openCount
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened with the switch off")
    } catch {}
    XCTAssertEqual(opener.openCount, opened)

    connection.setProcessMeetings(true)
    connection.setProcessMeetings(false)
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened with the switch off")
    } catch {}
    XCTAssertEqual(opener.openCount, opened)
  }

  func testNothingOpensWithoutAnAddress() async {
    settings.setProcessMeetings(true)
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened without a server")
    } catch {}
    await connection.refresh()
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertEqual(fetcher.fetches, 0)
  }

  // MARK: Settings

  func testSwitchRecordsConsentAndCopyDefaultsOn() {
    XCTAssertTrue(settings.copyToMac)
    XCTAssertFalse(settings.consentCurrent)
    settings.setProcessMeetings(true)
    XCTAssertEqual(
      defaults.integer(forKey: "server.consentVersion"), PhoneServerSettings.consentVersion)
    settings.copyToMac = false

    let reloaded = PhoneServerSettings(defaults: defaults)
    XCTAssertTrue(reloaded.processMeetings)
    XCTAssertTrue(reloaded.consentCurrent)
    XCTAssertFalse(reloaded.copyToMac)
  }

  // MARK: Sign out

  func testSignOutDeletesCredentials() async throws {
    await approvedWithSwitchOn()
    XCTAssertFalse(credentials.isEmpty)
    settings.copyToMac = false

    await connection.signOut()
    XCTAssertTrue(credentials.isEmpty)
    XCTAssertEqual(connection.status, .notSignedIn)
    XCTAssertEqual(settings.serverAddress, "")
    XCTAssertFalse(settings.processMeetings)
    XCTAssertFalse(settings.consentCurrent)
    XCTAssertFalse(connection.signedIn)
    for key in PhoneServerSettings.keys where key != "server.copyToMac" {
      XCTAssertNil(defaults.object(forKey: key), key)
    }
    XCTAssertFalse(settings.copyToMac)

    let opened = opener.openCount
    do {
      _ = try await connection.openSessionChannel()
      XCTFail("Opened after sign-out")
    } catch {}
    await connection.refresh()
    XCTAssertEqual(opener.openCount, opened)
  }

  func testANewAddressSignsOutOfTheOldServer() async {
    await approvedWithSwitchOn()
    connection.addressDraft = "https://other.example"
    await connection.checkIdentity()
    XCTAssertNil(try credentials.read(.refreshToken))
    XCTAssertNil(try credentials.read(.serverKey))
    XCTAssertEqual(settings.serverAddress, "https://other.example")
    XCTAssertFalse(settings.processMeetings)
    XCTAssertEqual(connection.status, .compareFingerprint)
  }

  // MARK: Pairing (Feature 027)

  private var tokenValue: String {
    "lfp_"
      + (FakeRemoteServer.serverKey.publicKey.rawRepresentation + Data(repeating: 7, count: 32))
      .base64URL
  }

  /// Opening a link fills in the form and spends nothing.
  func testALinkOnlyFillsInTheForm() async throws {
    let address = "https%3A%2F%2Fserver.example"
    let url = try XCTUnwrap(URL(string: "localflow://pair?address=\(address)#token=\(tokenValue)"))
    connection.requestPairing(try XCTUnwrap(PairingLink(url)))
    XCTAssertTrue(connection.showingPairing)
    XCTAssertEqual(connection.addressDraft, "https://server.example")
    XCTAssertEqual(connection.pairingToken, tokenValue)
    XCTAssertTrue(connection.canConfirmPairing)
    XCTAssertEqual(fetcher.fetches, 0)
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertEqual(settings.serverAddress, "")
    XCTAssertNil(defaults.string(forKey: "server.address"))
  }

  func testAWholeLinkPastedAsTheTokenFillsBothFields() {
    let value =
      "lfp_"
      + (FakeRemoteServer.serverKey.publicKey.rawRepresentation
      + Data(repeating: 7, count: 32)).base64URL
    connection.requestPairing()
    connection.pairingToken =
      "localflow://pair?address=http%3A%2F%2F192.168.1.20%3A8090#token=\(value)"
    XCTAssertEqual(connection.pairingToken, value)
    XCTAssertEqual(connection.addressDraft, "http://192.168.1.20:8090")
    XCTAssertTrue(connection.canConfirmPairing)
    XCTAssertEqual(opener.openCount, 0)
  }

  /// FR-013: same key, new address, nothing else moves. Another key: nothing at all.
  func testUpdatingTheAddressKeepsTheDevice() async throws {
    await approvedWithSwitchOn()
    let refresh = credentials.string(.refreshToken)
    let device = try credentials.read(.deviceKey)
    XCTAssertFalse(connection.canUpdateAddress)
    connection.addressDraft = "http://192.168.1.20:8090"
    XCTAssertTrue(connection.canUpdateAddress)
    await connection.updateAddress()
    XCTAssertEqual(settings.serverAddress, "http://192.168.1.20:8090")
    XCTAssertEqual(connection.addressDraft, "http://192.168.1.20:8090")
    XCTAssertEqual(settings.remoteState, .approved)
    XCTAssertTrue(settings.processMeetings)
    XCTAssertEqual(credentials.string(.refreshToken), refresh)
    XCTAssertEqual(try credentials.read(.deviceKey), device)

    connection.addressDraft = "https://other.example"
    fetcher.key = Data(repeating: 9, count: 32)
    await connection.updateAddress()
    XCTAssertNotNil(connection.error)
    XCTAssertEqual(settings.serverAddress, "http://192.168.1.20:8090")
    XCTAssertEqual(settings.remoteState, .approved)
    XCTAssertEqual(credentials.string(.refreshToken), refresh)
  }

  func testPairApprovesAndLeavesMeetingsOff() async {
    connection.requestPairing()
    connection.addressDraft = "https://server.example"
    connection.pairingToken = tokenValue
    await connection.pair()
    XCTAssertNil(connection.error)
    XCTAssertEqual(flowd.pairTokens, [tokenValue])
    XCTAssertEqual(connection.status, .approved)
    XCTAssertFalse(connection.showingPairing)
    XCTAssertEqual(connection.pairingToken, "")
    XCTAssertEqual(settings.serverAddress, "https://server.example")
    XCTAssertFalse(settings.sendsMeetings)
    for key in PhoneServerSettings.keys {
      XCTAssertFalse("\(defaults.object(forKey: key) ?? "")".contains("lfp_"))
    }
  }

  func testARefusedTokenSaysSoAndCancelLeavesNothing() async {
    flowd.pairError = "pairing_token_invalid"
    connection.requestPairing()
    connection.addressDraft = "https://server.example"
    connection.pairingToken = tokenValue
    await connection.pair()
    XCTAssertEqual(
      connection.error, "This token has expired, been used or been revoked. Ask for a new one.")
    XCTAssertTrue(connection.showingPairing)
    XCTAssertEqual(connection.state, .off)
    connection.cancelPairing()
    XCTAssertEqual(settings.serverAddress, "")
    XCTAssertEqual(connection.addressDraft, "")
    XCTAssertEqual(connection.pairingToken, "")
    XCTAssertNil(connection.error)
  }

  func testAWrongServerNeverReceivesTheToken() async throws {
    fetcher.key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    connection.requestPairing()
    connection.addressDraft = "https://server.example"
    connection.pairingToken = tokenValue
    await connection.pair()
    XCTAssertEqual(
      connection.error,
      "This address reaches a different server. Check the address or ask for a new token.")
    XCTAssertEqual(opener.openCount, 0)
    XCTAssertTrue(flowd.pairTokens.isEmpty)
  }

  func testAnOldServerAsksForAnUpdate() async {
    flowd.pairError = "invalid_message"
    connection.requestPairing()
    connection.addressDraft = "https://server.example"
    connection.pairingToken = tokenValue
    await connection.pair()
    XCTAssertEqual(connection.status, .updateRequired)
    XCTAssertEqual(
      connection.error, "Update the LocalFlow server to pair with a token. The token was not used.")
  }

  /// Pairing never replaces another server's credentials: the owner signs out first.
  func testPairingAnotherServerIsRefusedUntilSignOut() async {
    await enroll(as: "approved")
    connection.requestPairing()
    connection.addressDraft = "https://other.example"
    connection.pairingToken = tokenValue
    await connection.pair()
    XCTAssertEqual(connection.error, "This iPhone already uses another server. Sign out first.")
    XCTAssertEqual(settings.serverAddress, "https://server.example")
    XCTAssertEqual(connection.state, .approved)
    XCTAssertTrue(flowd.pairTokens.isEmpty)
  }
}
