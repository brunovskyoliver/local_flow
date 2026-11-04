import LocalFlowCore
import SwiftUI

/// Settings › Server (contracts/phone-ui.md): address, identity check and Confirm,
/// Sign in with Google, the state line, Sign out, the two meeting switches, and (Feature 028)
/// the invite code while pending and "Your devices".
struct ServerSettingsView: View {
  @Bindable var connection: PhoneServerConnection
  @State private var confirmSignOut = false
  @State private var removing: RemoteAccountDevice?
  @FocusState private var addressFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("https://server.example" as String, text: $connection.addressDraft)
          .keyboardType(.URL)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($addressFocused)
          .submitLabel(.go)
          .onSubmit(checkIdentity)
        Button("Check identity", action: checkIdentity)
          .disabled(connection.busy || connection.draftOrigin == nil)
        if connection.canUpdateAddress {
          Button("Update address") { Task { await connection.updateAddress() } }
            .accessibilityIdentifier("server.addressEdit")
        }
      } header: {
        Text("Server address")
      } footer: {
        if let error = connection.error {
          Text(error).foregroundStyle(SottoPalette.warning)
        } else if let notice = RemoteDictationSettings.addressNotice(connection.addressDraft) {
          Text(notice)
        } else {
          Text("Your LocalFlow server's address, for example its Tailscale name.")
        }
      }
      .sottoRow()

      if let identity = connection.identity {
        Section {
          Text(identity.fingerprint)
            .font(.body.monospaced())
            .textSelection(.enabled)
          Button("Confirm") { connection.confirmIdentity() }
          Button("Cancel", role: .cancel) { connection.cancelIdentity() }
        } header: {
          Text("Server fingerprint")
        } footer: {
          Text("Compare it with `flowd admin identity` on the server before you confirm.")
        }
        .sottoRow()
      }

      if connection.offersPairing {
        Section {
          Button("Pair with token") { connection.requestPairing() }
            .disabled(connection.busy)
            .accessibilityIdentifier("server.pairWithToken")
        } footer: {
          Text("Use a token from your server's owner instead of signing in.")
        }
        .sottoRow()
      }

      if connection.settings.origin != nil {
        Section {
          LabeledContent("State") {
            HStack(spacing: 6) {
              if connection.busy { ProgressView() }
              Text(connection.status.text)
            }
          }
          if let code = connection.inviteCode {
            LabeledContent("Code") {
              Text(code).font(.title2.monospacedDigit()).textSelection(.enabled)
            }
            .accessibilityIdentifier("server.inviteCode")
          }
          if let fingerprint = connection.pinnedFingerprint, connection.identity == nil {
            LabeledContent("Fingerprint") {
              Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
            }
          }
          if connection.needsSignIn {
            if connection.googleAvailable {
              Button("Sign in with Google") {
                Task { await connection.signInWithGoogle() }
              }
              .disabled(connection.busy)
            } else {
              Text("Google sign-in isn't set up in this build.")
                .foregroundStyle(.secondary)
            }
          }
          if connection.signedIn {
            Button("Sign out", role: .destructive) { confirmSignOut = true }
          }
        } header: {
          Text("This iPhone")
        } footer: {
          if let footer = stateFooter { Text(footer) }
        }
        .sottoRow()

        if let devices = connection.devices {
          Section {
            ForEach(devices) { device in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(device.thisDevice ? "\(device.name) (this iPhone)" : device.name)
                  Text(Self.detail(device)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(device.thisDevice ? "This wasn't me" : "Remove", role: .destructive) {
                  removing = device
                }
                .buttonStyle(.borderless)
                .disabled(connection.busy)
                .accessibilityIdentifier(
                  device.thisDevice ? "server.yourDeviceNotMe" : "server.yourDeviceRemove")
              }
            }
          } header: {
            Text("Your devices")
          } footer: {
            Text(
              "Remove a device you no longer use. If you didn't add this iPhone, tap This wasn't me."
            )
          }
          .accessibilityIdentifier("server.yourDevices")
          .sottoRow()
        }

        Section {
          Toggle(
            "Process meetings on this server",
            isOn: Binding(
              get: { connection.settings.processMeetings },
              set: { connection.setProcessMeetings($0) }))
          Toggle(
            "Copy meetings to my Mac",
            isOn: Binding(
              get: { connection.settings.copyToMac },
              set: { connection.settings.copyToMac = $0 }))
        } header: {
          Text("Meetings")
        } footer: {
          Text(PhoneServerConnection.consentText)
        }
        .sottoRow()
      }
    }
    .sottoList()
    .navigationTitle("Server")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: connection.state) {
      await connection.refresh()
      await connection.loadDevices()
      await connection.watchApproval(every: .seconds(5))
    }
    .confirmationDialog(
      removing?.thisDevice == true ? "Remove this iPhone from the account?" : "Remove this device?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { device in
      Button("Remove", role: .destructive) { Task { await connection.remove(device) } }
    } message: { device in
      Text(
        device.thisDevice
          ? "This iPhone stops using the server at once. Your recordings stay here."
          : "\(device.name) stops using the server at once.")
    }
    .confirmationDialog(
      "Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible
    ) {
      Button("Sign out", role: .destructive) { Task { await connection.signOut() } }
    } message: {
      Text("This iPhone's credentials are deleted. Your recordings stay on this iPhone.")
    }
  }

  private func checkIdentity() {
    addressFocused = false
    Task { await connection.checkIdentity() }
  }

  /// Kind, then whether it's pending, connected or when it was last seen.
  static func detail(_ device: RemoteAccountDevice) -> String {
    let kind =
      switch device.kind {
      case .mac: "Mac"
      case .windows: "Windows PC"
      case .iphone: "iPhone"
      case nil: "Unknown"
      }
    let seen =
      if device.state == .pending {
        "Waiting for confirmation"
      } else if device.connected {
        "Connected now"
      } else if let last = device.lastSeenAt {
        "Last seen \(last.formatted(.relative(presentation: .named)))"
      } else {
        "Never connected"
      }
    return "\(kind) · \(seen)"
  }

  private var stateFooter: String? {
    switch connection.status {
    case .waitingForApproval where connection.inviteCode != nil:
      "Check that your other device shows the same code, then confirm there. Nothing is sent until then."
    case .waitingForApproval:
      "Approve this iPhone on the server. Meetings wait here until then."
    case .rejected: "The server's administrator rejected this iPhone."
    case .revoked:
      "The server removed this iPhone. Nothing is sent; your recordings stay here."
    case .identityChanged:
      "The server's identity no longer matches. Nothing is sent until you check and confirm it again."
    case .unreachable: "Meetings wait here until the server can be reached."
    default: nil
    }
  }
}

/// Feature 027: the address, the token and the consent text. Pair connects; opening a
/// link only fills this in.
struct PhonePairingSheet: View {
  @Bindable var connection: PhoneServerConnection

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("https://server.example" as String, text: $connection.addressDraft)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Server address")
        } footer: {
          if let notice = RemoteDictationSettings.addressNotice(connection.addressDraft) {
            Text(notice)
          }
        }
        .sottoRow()
        Section {
          SecureField("lfp_…", text: $connection.pairingToken)
            .accessibilityIdentifier("server.pairToken")
        } header: {
          Text("Token")
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            if let error = connection.error {
              Text(error).foregroundStyle(SottoPalette.warning)
            }
            Text(PhoneServerConnection.consentText)
          }
        }
        .sottoRow()
        if let host = connection.draftOrigin?.host() {
          Section { LabeledContent("Server", value: host) }.sottoRow()
        }
      }
      .sottoList()
      .navigationTitle("Pair with token")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { connection.cancelPairing() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Pair") { Task { await connection.pair() } }
            .disabled(!connection.canConfirmPairing)
        }
      }
    }
  }
}
