import SwiftUI

/// Settings › Remote dictation (Feature 014, User Story 2): consent, server address,
/// fingerprint, sign-in and the device's state. Nothing connects before the consent step
/// is confirmed with a server address; turning off asks first and deletes this device's
/// credentials but not its history.
@MainActor @Observable
final class RemoteDictationModel {
  /// Version `AppPreferences.remoteConsentVersion` (Feature 018 FR-033).
  static let consentText =
    "Dictation audio, transcripts, Dictionary terms and rewrite text will leave this Mac for the server below while remote dictation is on. With Use this server for everything, so will meeting audio, meeting transcripts and the text summaries are made from. The server's administrator can see audio while it is being processed. Nothing is sent until the administrator approves this device; dictation stays local whenever the server can't be reached."

  private(set) var showingConsent = false
  private(set) var confirmingTurnOff = false
  var serverDraft = ""
  /// The identity fetched for the user to compare with `flowd admin identity`.
  private(set) var identity: RemoteServerIdentity?
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let preferences: AppPreferences
  @ObservationIgnored private let enrollment: @MainActor () -> RemoteEnrollment?
  @ObservationIgnored private let turnOffAction: @MainActor () -> Void
  @ObservationIgnored private let signInAvailable: @MainActor (IdentityProvider) -> Bool

  init(
    preferences: AppPreferences, enrollment: @escaping @MainActor () -> RemoteEnrollment?,
    turnOff: @escaping @MainActor () -> Void,
    signInAvailable: @escaping @MainActor (IdentityProvider) -> Bool = { _ in true }
  ) {
    self.preferences = preferences
    self.enrollment = enrollment
    turnOffAction = turnOff
    self.signInAvailable = signInAvailable
  }

  var isOn: Bool { preferences.remoteEnabled }
  var state: RemoteDictationState { preferences.remoteState }
  var serverURL: String { preferences.remoteServerURL }
  var draftOrigin: URL? { RemoteDictationSettings.origin(serverDraft) }
  func isAvailable(_ provider: IdentityProvider) -> Bool { signInAvailable(provider) }

  /// The pinned server's fingerprint, shown after pinning.
  var pinnedFingerprint: String? {
    enrollment()?.pinnedKey.map(RemoteServerIdentity.fingerprint(of:))
  }

  /// What the next step is: trust a fetched identity, sign in, or nothing.
  var needsTrust: Bool { identity != nil && state != .pinned }
  var needsSignIn: Bool { isOn && state == .pinned && identity == nil }

  /// The one-line state, or nil when remote dictation is off.
  var statusText: String? {
    guard isOn else { return nil }
    if preferences.remoteNotice == .updateRequired { return "Update LocalFlow or the server" }
    switch state {
    case .off: return identity == nil ? "Checking the server…" : "Compare the fingerprint"
    case .pinned:
      return preferences.remoteNotice == .signInAgain ? "Sign in again" : "Sign in to finish"
    case .pending: return "Waiting for approval"
    case .approved: return "Approved"
    case .rejected: return "Rejected"
    case .revoked: return "Removed from the server"
    case .pinMismatch: return "Server identity changed"
    }
  }

  func requestTurnOn() {
    error = nil
    serverDraft = preferences.remoteServerURL
    showingConsent = true
  }

  /// Cancel leaves everything off: no address, no switch, no connection.
  func cancelConsent() {
    showingConsent = false
    serverDraft = ""
  }

  /// The consent step: only now are the address and the switch stored.
  func confirmConsent() async {
    guard preferences.setRemoteServerURL(serverDraft) else {
      error = "Enter the server's https:// address without a path."
      return
    }
    preferences.confirmRemoteConsent()
    preferences.remoteEnabled = true
    showingConsent = false
    await fetchIdentity()
  }

  /// Fetches the identity to compare; also how a changed identity is enrolled again.
  func fetchIdentity() async {
    guard let enrollment = enrollment() else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      identity = try await enrollment.fetchServerIdentity()
    } catch {
      identity = nil
      self.error = "The server did not answer with a LocalFlow identity. Check the address."
    }
  }

  func trustServer() {
    guard let identity, let enrollment = enrollment() else { return }
    do {
      try enrollment.pin(identity)
      self.identity = nil
    } catch {
      self.error = "The server identity could not be saved."
    }
  }

  func signIn(_ provider: IdentityProvider) async {
    guard let enrollment = enrollment() else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      try await enrollment.enroll(provider: provider)
    } catch RemoteEnrollmentError.signInFailed {
      error = "Sign-in did not finish."
    } catch RemoteChannelError.pinMismatch {
      error = nil
    } catch {
      self.error = "The server could not be reached. Try again."
    }
  }

  /// Approved under the first consent text: summaries and meetings stay on this Mac
  /// until the current text is confirmed once.
  var needsConsentUpdate: Bool { isOn && !preferences.remoteConsentCurrent }
  private(set) var showingConsentUpdate = false
  func reviewConsentUpdate() { showingConsentUpdate = true }
  func cancelConsentUpdate() { showingConsentUpdate = false }
  func confirmConsentUpdate() {
    preferences.confirmRemoteConsent()
    showingConsentUpdate = false
  }

  func requestTurnOff() { confirmingTurnOff = true }
  func cancelTurnOff() { confirmingTurnOff = false }

  func confirmTurnOff() {
    confirmingTurnOff = false
    identity = nil
    error = nil
    turnOffAction()
  }
}

struct RemoteDictationView: View {
  @Bindable var model: RemoteDictationModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsRow("Remote dictation", detail: detail) {
        Toggle(
          "Remote dictation",
          isOn: Binding(
            get: { model.isOn },
            set: { $0 ? model.requestTurnOn() : model.requestTurnOff() })
        )
        .labelsHidden().toggleStyle(.switch)
        .accessibilityIdentifier("settings.remoteEnabled")
      }
      if model.isOn {
        SottoPalette.line.frame(height: 1)
        VStack(alignment: .leading, spacing: 12) {
          if let identity = model.identity {
            Text("Server fingerprint").font(.flow(size: 12, weight: .medium))
              .foregroundStyle(SottoPalette.muted)
            Text(identity.fingerprint).font(.system(size: 13, design: .monospaced))
              .textSelection(.enabled).accessibilityIdentifier("settings.remoteFingerprint")
            Text("Compare it with `flowd admin identity` on the server before trusting it.")
              .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
            Button("Trust This Server") { model.trustServer() }
              .accessibilityIdentifier("settings.remoteTrust")
          } else if let pinned = model.pinnedFingerprint {
            Text("Pinned fingerprint  \(pinned)").font(.system(size: 12, design: .monospaced))
              .foregroundStyle(SottoPalette.muted).textSelection(.enabled)
          }
          if model.needsSignIn {
            HStack(spacing: 8) {
              Button("Sign in with Apple") { Task { await model.signIn(.apple) } }
                .accessibilityIdentifier("settings.remoteSignInApple")
              if model.isAvailable(.google) {
                Button("Sign in with Google") { Task { await model.signIn(.google) } }
                  .accessibilityIdentifier("settings.remoteSignInGoogle")
              }
            }.disabled(model.busy)
          }
          if model.state == .pinMismatch || model.state == .revoked || model.state == .rejected {
            Button("Enroll Again") { Task { await model.fetchIdentity() } }.disabled(model.busy)
          }
          if let error = model.error {
            Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
      }
    }
    .sheet(isPresented: .constant(model.showingConsent)) { consent }
    .confirmationDialog(
      "Turn off remote dictation?", isPresented: .constant(model.confirmingTurnOff)
    ) {
      Button("Turn Off", role: .destructive) { model.confirmTurnOff() }
      Button("Cancel", role: .cancel) { model.cancelTurnOff() }
    } message: {
      Text(
        "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on."
      )
    }
  }

  private var detail: String {
    guard model.isOn else {
      return "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run."
    }
    return [model.serverURL, model.statusText].compactMap { $0 }.filter { !$0.isEmpty }
      .joined(separator: " · ")
  }

  private var consent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Use your LocalFlow server?").font(.flow(size: 17, weight: .medium))
      RewriteInputSurface(symbol: "server.rack") {
        TextField("https://server.example.com", text: $model.serverDraft)
          .accessibilityIdentifier("settings.remoteServerURL")
      }
      Text(RemoteDictationModel.consentText).font(.flow(size: 13)).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      if let origin = model.draftOrigin {
        Text("Server: \(origin.host() ?? origin.absoluteString)").font(
          .flow(size: 13, weight: .medium))
      }
      if let error = model.error {
        Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
      HStack {
        Spacer()
        Button("Cancel") { model.cancelConsent() }.keyboardShortcut(.cancelAction)
        Button("Turn On") { Task { await model.confirmConsent() } }
          .keyboardShortcut(.defaultAction).disabled(model.draftOrigin == nil)
          .accessibilityIdentifier("settings.remoteConsentConfirm")
      }
    }
    .padding(24).frame(width: 460)
  }
}
