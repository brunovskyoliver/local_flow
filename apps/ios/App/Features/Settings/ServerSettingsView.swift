import LocalFlowCore
import SwiftUI

/// Settings › Server (contracts/phone-ui.md): address, identity check and Confirm,
/// Sign in with Google, the state line, Sign out, and the two meeting switches.
struct ServerSettingsView: View {
  @Bindable var connection: PhoneServerConnection
  @State private var confirmSignOut = false
  @FocusState private var addressFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("https://server.example", text: $connection.addressDraft)
          .keyboardType(.URL)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($addressFocused)
          .submitLabel(.go)
          .onSubmit(checkIdentity)
        Button("Check identity", action: checkIdentity)
          .disabled(connection.busy || connection.draftOrigin == nil)
      } header: {
        Text("Server address")
      } footer: {
        if let error = connection.error {
          Text(error).foregroundStyle(.red)
        } else {
          Text("Your LocalFlow server's https:// address, for example its Tailscale name.")
        }
      }

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
      }

      if connection.settings.origin != nil {
        Section {
          LabeledContent("State") {
            HStack(spacing: 6) {
              if connection.busy { ProgressView() }
              Text(connection.status.text)
            }
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
      }
    }
    .navigationTitle("Server")
    .navigationBarTitleDisplayMode(.inline)
    .task { await connection.refresh() }
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

  private var stateFooter: String? {
    switch connection.status {
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
