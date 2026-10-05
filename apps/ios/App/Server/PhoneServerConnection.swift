import AuthenticationServices
import Foundation
import LocalFlowCore
import Security
import UIKit
import os

/// Settings › Server (`server.*` in UserDefaults). The address, the display state the
/// enrollment writes, the consent version and the two switches. Tokens and keys live in
/// the Keychain (`RemoteCredentialStore`), never here.
@MainActor
@Observable
final class PhoneServerSettings: RemoteEnrollmentSettings {
  /// The version of `PhoneServerConnection.consentText` the owner accepted by turning
  /// "Process meetings on this server" on.
  static let consentVersion = 1
  static let keys = [
    "server.address", "server.state", "server.notice", "server.consentVersion",
    "server.processMeetings", "server.copyToMac",
  ]

  @ObservationIgnored private let defaults: UserDefaults

  /// The server origin as `https://host[:port]`; empty before the owner enters one.
  private(set) var serverAddress: String {
    didSet { defaults.set(serverAddress, forKey: "server.address") }
  }
  var remoteState: RemoteDictationState {
    didSet { defaults.set(remoteState.rawValue, forKey: "server.state") }
  }
  var remoteNotice: RemoteDictationNotice? {
    didSet { defaults.set(remoteNotice?.rawValue, forKey: "server.notice") }
  }
  private(set) var consentVersion: Int {
    didSet { defaults.set(consentVersion, forKey: "server.consentVersion") }
  }
  /// "Process meetings on this server". Off until the owner turns it on.
  private(set) var processMeetings: Bool {
    didSet { defaults.set(processMeetings, forKey: "server.processMeetings") }
  }
  /// "Copy meetings to my Mac" (FR-040). On by default.
  var copyToMac: Bool {
    didSet { defaults.set(copyToMac, forKey: "server.copyToMac") }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    serverAddress =
      RemoteDictationSettings.origin(defaults.string(forKey: "server.address") ?? "")?
      .absoluteString ?? ""
    remoteState =
      RemoteDictationState(rawValue: defaults.string(forKey: "server.state") ?? "") ?? .off
    remoteNotice = RemoteDictationNotice(rawValue: defaults.string(forKey: "server.notice") ?? "")
    consentVersion = defaults.integer(forKey: "server.consentVersion")
    processMeetings = defaults.bool(forKey: "server.processMeetings")
    copyToMac = defaults.object(forKey: "server.copyToMac") as? Bool ?? true
  }

  var origin: URL? { RemoteDictationSettings.origin(serverAddress) }

  /// Entering an address is the owner's request to talk to that server; nothing connects
  /// before it.
  var remoteEnrollmentOrigin: URL? { origin }

  @discardableResult func setServerAddress(_ text: String) -> Bool {
    guard let origin = RemoteDictationSettings.origin(text) else { return false }
    serverAddress = origin.absoluteString
    return true
  }

  /// Turning the switch on is the consent to the current text (FR-013).
  func setProcessMeetings(_ on: Bool) {
    if on { consentVersion = Self.consentVersion }
    processMeetings = on
  }

  var consentCurrent: Bool { consentVersion >= Self.consentVersion }

  /// Meeting audio may leave the phone: approved, switch on under the current consent
  /// text, and a server address (SC-008).
  var sendsMeetings: Bool {
    origin != nil && remoteState == .approved && processMeetings && consentCurrent
  }

  /// Sign-out: every `server.*` setting goes except "Copy meetings to my Mac".
  func resetRemote() {
    serverAddress = ""
    remoteState = .off
    remoteNotice = nil
    consentVersion = 0
    processMeetings = false
    for key in Self.keys where key != "server.copyToMac" { defaults.removeObject(forKey: key) }
  }
}

/// This iPhone's link to the owner's LocalFlow server (User Story 4): enrollment with
/// Google, the pinned identity, the state line, sign-out, and the channel pool meetings
/// use. Every session channel is refused unless `settings.sendsMeetings` holds.
@MainActor
@Observable
final class PhoneServerConnection {
  /// FR-013, version `PhoneServerSettings.consentVersion`.
  static let consentText =
    "Meeting audio and transcripts are sent to this server and stored there until this iPhone has the result, at most 7 days. Nothing is sent until the administrator approves this iPhone."

  /// The state line in Settings › Server (FR-012).
  enum Status: Equatable {
    case notSignedIn
    case compareFingerprint
    case signIn
    case signInAgain
    case waitingForApproval
    case approved
    case rejected
    case revoked
    case identityChanged
    case unreachable
    case updateRequired

    var text: String {
      switch self {
      case .notSignedIn: "Not signed in"
      case .compareFingerprint: "Compare the fingerprint"
      case .signIn: "Sign in to finish"
      case .signInAgain: "Sign in again"
      case .waitingForApproval: "Waiting for approval"
      case .approved: "Approved"
      case .rejected: "Rejected"
      case .revoked: "Revoked"
      case .identityChanged: "Server identity changed"
      case .unreachable: "Unreachable"
      case .updateRequired: "Update LocalFlow or the server"
      }
    }
  }

  let settings: PhoneServerSettings
  @ObservationIgnored let enrollment: RemoteEnrollment
  @ObservationIgnored let credentials: any RemoteCredentialStoring
  @ObservationIgnored private let transports: any RemoteTransportOpening
  @ObservationIgnored private let signIn: any IdentitySignIn
  /// The channels meeting work leases (purpose `.session`).
  @ObservationIgnored private(set) var pool: RemoteChannelPool!

  var addressDraft: String
  /// The identity fetched for the owner to compare with `flowd admin identity`.
  private(set) var identity: RemoteServerIdentity?
  private(set) var busy = false
  private(set) var error: String?
  /// False after the last channel could not reach the server; true again on the next
  /// channel that opens.
  private(set) var reachable = true
  /// What the server offered in its last `ready`.
  private(set) var capabilities: RemoteCapabilities?
  /// Feature 020: the enrollment state or a switch changed; the meeting queue looks again.
  @ObservationIgnored var onChange: (() -> Void)?

  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "server")

  init(
    settings: PhoneServerSettings, credentials: any RemoteCredentialStoring,
    keys: any RemoteDeviceKeys, signIn: any IdentitySignIn,
    identityFetcher: any RemoteIdentityFetching, transports: any RemoteTransportOpening,
    clock: any RemoteClock = SystemRemoteClock(), deviceName: String
  ) {
    self.settings = settings
    self.credentials = credentials
    self.transports = transports
    self.signIn = signIn
    enrollment = RemoteEnrollment(
      preferences: settings, credentials: credentials, keys: keys, signIn: signIn,
      identityFetcher: identityFetcher, transports: transports, clock: clock,
      deviceName: deviceName)
    addressDraft = settings.serverAddress
    pool = RemoteChannelPool(open: { [weak self] in
      guard let self else { throw RemoteChannelError.closed }
      return try await self.openSessionChannel()
    })
  }

  /// The production wiring: Keychain items readable after first unlock (research R7), the
  /// Secure Enclave, Google sign-in with the phone's own client (R8).
  static func system(bundle: Bundle = .main) -> PhoneServerConnection {
    let service = (bundle.bundleIdentifier ?? "org.localflow.LocalFlowPhone") + ".remote"
    return PhoneServerConnection(
      settings: PhoneServerSettings(),
      credentials: RemoteCredentialStore(
        service: service, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
      keys: SecureEnclaveDeviceKeys(),
      signIn: SystemIdentitySignIn(
        googleClientID: bundle.object(forInfoDictionaryKey: "LocalFlowGoogleClientID") as? String,
        presentationAnchor: Self.keyWindow),
      identityFetcher: URLSessionIdentityFetcher(), transports: URLSessionRemoteTransportOpener(),
      deviceName: UIDevice.current.name)
  }

  /// Sign-in starts from Settings › Server, so a window scene is always connected.
  private static func keyWindow() -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap(\.windows)
    if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
    guard let scene = scenes.first else { preconditionFailure("Sign-in without a window scene") }
    return UIWindow(windowScene: scene)
  }

  // MARK: State

  var googleAvailable: Bool { signIn.isAvailable(.google) }
  var state: RemoteDictationState { settings.remoteState }
  var draftOrigin: URL? { RemoteDictationSettings.origin(addressDraft) }

  /// The pinned server's fingerprint once the owner confirmed it.
  var pinnedFingerprint: String? {
    settings.origin == nil ? nil : enrollment.pinnedKey.map(RemoteServerIdentity.fingerprint(of:))
  }

  /// A fetched identity waits for Confirm.
  var needsConfirm: Bool { identity != nil }
  /// Pinned and not yet enrolled (or enrollment must run again).
  var needsSignIn: Bool { settings.origin != nil && state == .pinned && identity == nil }
  /// Anything to sign out of: an address, a pin or credentials.
  var signedIn: Bool { settings.origin != nil && state != .off }

  var status: Status {
    if settings.remoteNotice == .updateRequired { return .updateRequired }
    switch state {
    case .off: return identity == nil ? .notSignedIn : .compareFingerprint
    case .pinned: return settings.remoteNotice == .signInAgain ? .signInAgain : .signIn
    case .pending: return .waitingForApproval
    case .approved: return reachable ? .approved : .unreachable
    case .rejected: return .rejected
    case .revoked: return .revoked
    case .pinMismatch: return .identityChanged
    }
  }

  // MARK: Enrollment

  /// Check identity: stores the address (a different one signs out of the old server
  /// first) and fetches the identity to compare. Nothing is pinned yet.
  func checkIdentity() async {
    error = nil
    guard let origin = draftOrigin else {
      error = "Enter the server's https:// address without a path."
      return
    }
    if settings.origin != origin {
      if settings.origin != nil { await signOut() }
      settings.setServerAddress(origin.absoluteString)
    }
    addressDraft = settings.serverAddress
    busy = true
    defer { busy = false }
    do {
      identity = try await enrollment.fetchServerIdentity()
    } catch {
      identity = nil
      self.error = "The server did not answer with a LocalFlow identity. Check the address."
    }
  }

  /// Confirm: pins the identity the owner compared. Sign-in comes next; a changed
  /// identity is re-confirmed the same way and needs a new sign-in.
  func confirmIdentity() {
    guard let identity else { return }
    do {
      try enrollment.pin(identity)
      self.identity = nil
      reachable = true
    } catch {
      self.error = "The server identity could not be saved."
    }
  }

  func cancelIdentity() { identity = nil }

  func signInWithGoogle() async {
    guard needsSignIn else { return }
    busy = true
    defer { busy = false }
    error = nil
    defer { onChange?() }
    do {
      try await enrollment.enroll(provider: .google)
      reachable = true
    } catch RemoteEnrollmentError.signInFailed {
      error = "Sign-in did not finish."
    } catch RemoteEnrollmentError.deviceKeyUnavailable {
      error = "This iPhone can't create a device key."
    } catch RemoteChannelError.pinMismatch {
      error = nil
    } catch {
      self.error = "The server could not be reached. Try again."
    }
  }

  /// Settings opened or the app came forward: a pending device asks whether it was
  /// approved; an approved one refreshes its token, which also notices a revocation.
  func refresh() async {
    guard settings.origin != nil else { return }
    defer { onChange?() }
    switch state {
    case .pending:
      await enrollment.refreshNow()
    case .approved:
      if await enrollment.accessToken() != nil {
        reachable = true
      } else if state == .approved {
        reachable = false
      }
    default: break
    }
  }

  /// "Process meetings on this server". Turning it off closes idle channels.
  func setProcessMeetings(_ on: Bool) {
    settings.setProcessMeetings(on)
    if !on { Task { await pool.closeAll() } }
    onChange?()
  }

  /// Sign out (FR-012, scenario 5): the four Keychain items and the `server.*` settings
  /// go; recordings stay.
  func signOut() async {
    enrollment.turnOff()
    identity = nil
    error = nil
    reachable = true
    capabilities = nil
    addressDraft = ""
    await pool.closeAll()
    onChange?()
    Self.log.notice("Signed out of the server")
  }

  // MARK: Channels

  /// A session channel for meeting work. Refused without opening anything unless the
  /// device is approved and the switch is on; an expired token is refreshed once.
  func openSessionChannel() async throws -> RemoteChannel {
    guard settings.sendsMeetings, let origin = settings.origin,
      let url = RemoteEnrollment.channelURL(origin: origin), let key = enrollment.pinnedKey
    else { throw RemoteChannelError.closed }
    guard var token = await enrollment.accessToken() else {
      if state == .approved { reachable = false }
      throw RemoteChannelError.unreachable
    }
    var retried = false
    while true {
      // The state may have changed while the token was fetched.
      guard settings.sendsMeetings else { throw RemoteChannelError.closed }
      let channel: RemoteChannel
      do {
        channel = try RemoteChannel(transport: try await transports.open(url), serverKey: key)
      } catch {
        reachable = false
        throw RemoteChannelError.unreachable
      }
      do {
        try await channel.open(purpose: .session, accessToken: token)
        reachable = true
        capabilities = await channel.capabilities
        return channel
      } catch RemoteChannelError.server(.tokenExpired) where !retried {
        retried = true
        await channel.close()
        guard let fresh = await enrollment.accessTokenExpired() else {
          throw RemoteChannelError.server(.tokenExpired)
        }
        token = fresh
      } catch let failure as RemoteChannelError {
        await channel.close()
        switch failure {
        case .pinMismatch: enrollment.handlePinMismatch()
        case .server(let code): enrollment.apply(code)
        case .unreachable, .timeout, .closed: reachable = false
        case .protocolError: break
        }
        throw failure
      }
    }
  }
}

extension PhoneServerConnection {
  /// Whether meeting audio may go to the server now (SC-008), and why not: enrollment
  /// state, the switch under the current consent text, and the `handoff` op.
  var uploadGate: MeetingUploader.Gate {
    typealias Detail = MeetingUploader.Detail
    guard settings.origin != nil else { return .closed(Detail.notSignedIn) }
    switch state {
    case .off, .pinned: return .closed(Detail.notSignedIn)
    case .pending: return .closed(Detail.pending)
    case .rejected: return .closed(Detail.rejected)
    case .revoked: return .closed(Detail.revoked)
    case .pinMismatch: return .closed(Detail.identityChanged)
    case .approved: break
    }
    guard settings.processMeetings, settings.consentCurrent else {
      return .closed(Detail.processingOff)
    }
    if settings.remoteNotice == .updateRequired { return .closed(Detail.outdated) }
    if let capabilities, !capabilities.offers(op: "handoff") { return .closed(Detail.outdated) }
    return .open(copyToMac: settings.copyToMac)
  }
}
