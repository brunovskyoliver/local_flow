import AppKit
import LocalFlowCore
import SwiftUI

@MainActor @Observable
final class ServerModeModel {
  enum Confirm: Identifiable, Equatable {
    case turnOn, turnOnExisting, turnOff, open, download
    var id: Self { self }
  }

  private(set) var status = ServerModeStatus()
  private(set) var busy = false
  private(set) var progress: String?
  private(set) var message: String?
  var confirm: Confirm?
  var customDraft: String
  /// The tokens sheet's model; dropped on close with whatever it held.
  var tokens: TokensModel?
  @ObservationIgnored private let controller: ServerModeController
  @ObservationIgnored private let interfaces: () -> [String]

  init(controller: ServerModeController, interfaces: @escaping () -> [String]) {
    self.controller = controller
    self.interfaces = interfaces
    customDraft = controller.customAddress
  }

  var isOn: Bool { status.loaded }
  var addresses: [ServerAddress] {
    controller.addresses(listen: status.listen, interfaces: interfaces())
  }

  var statusLine: String {
    if !status.loaded {
      return status.ownership == .adopted
        ? "Off. The server already on this Mac stays as it was set up." : "Off"
    }
    if !status.running { return "Starting…" }
    guard let listen = status.listen else { return "Running" }
    return status.canOpenToNetwork
      ? "Running on \(listen), reachable only through a local proxy or tunnel"
      : "Running on \(listen), open to all networks"
  }

  var modelDownloadSize: String {
    ByteCountFormatter.string(fromByteCount: status.missingModelBytes, countStyle: .file)
  }

  func refresh() async { status = await controller.status() }

  func requestToggle(_ on: Bool) {
    confirm = !on ? .turnOff : status.ownership == .adopted ? .turnOnExisting : .turnOn
  }

  func perform(_ action: Confirm) async {
    busy = true
    message = nil
    defer { busy = false }
    do {
      switch action {
      case .turnOn, .turnOnExisting:
        progress = "Starting the server…"
        try await controller.turnOn()
      case .turnOff:
        progress = "Stopping the server…"
        try await controller.turnOff()
      case .open:
        progress = "Waiting up to 60 s for the server to report healthy…"
        switch await controller.openToNetwork() {
        case .opened: message = "The server is open to the network."
        case .rolledBack(let reason): message = "Previous settings restored. \(reason)"
        case .failed(let reason): message = reason
        }
      case .download:
        progress = "Downloading models…"
        try await controller.downloadModels()
      }
    } catch { message = error.localizedDescription }
    progress = nil
    await refresh()
  }

  func saveCustomAddress() {
    message =
      controller.setCustomAddress(customDraft) ? nil : "That isn't an address clients can use."
  }

  func showTokens() {
    tokens = TokensModel(admin: controller.admin, addresses: addresses)
  }
}

/// Settings › Server, the part that makes this Mac a server (research R8). Dictation on this
/// Mac doesn't depend on any of it.
struct ServerModeView: View {
  @Bindable var model: ServerModeModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsRow("Server mode", detail: model.statusLine) {
        Toggle(
          "Server mode",
          isOn: Binding(get: { model.isOn }, set: { model.requestToggle($0) })
        )
        .labelsHidden().toggleStyle(.switch).disabled(model.busy)
        .accessibilityIdentifier("settings.serverMode")
      }
      if let progress = model.progress {
        Text(progress).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
      }
      if let message = model.message {
        Text(message).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
      }
      if model.isOn { details }
      missing
    }
    .task { await model.refresh() }
    .confirmationDialog(
      title,
      isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } })
    ) {
      Button(button) {
        guard let action = model.confirm else { return }
        Task { await model.perform(action) }
      }
    } message: {
      Text(explanation)
    }
    .sheet(
      isPresented: Binding(get: { model.tokens != nil }, set: { if !$0 { model.tokens = nil } })
    ) {
      if let tokens = model.tokens { TokensView(model: tokens) }
    }
  }

  @ViewBuilder private var details: some View {
    SottoPalette.line.frame(height: 1)
    SettingsRow("Addresses", detail: addressText) { EmptyView() }
      .textSelection(.enabled)
      .accessibilityIdentifier("settings.serverModeAddress")
    if model.status.canOpenToNetwork {
      SottoPalette.line.frame(height: 1)
      SettingsRow(
        "Open to the network",
        detail: "Changes only the listen address. Tokens control who can connect."
      ) {
        Button("Open…") { model.confirm = .open }
          .buttonStyle(PrototypeButtonStyle(minimumWidth: 99)).disabled(model.busy)
          .accessibilityIdentifier("settings.serverModeOpen")
      }
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Custom address", detail: "A proxy or a name that reaches this Mac") {
      HStack(spacing: 8) {
        RewriteInputSurface(symbol: "link") {
          TextField("https://server.example.com" as String, text: $model.customDraft)
            .onSubmit { model.saveCustomAddress() }
            .accessibilityIdentifier("settings.serverModeCustomAddress")
        }
        .frame(width: 240)
        Button("Save") { model.saveCustomAddress() }
          .buttonStyle(PrototypeButtonStyle())
      }
    }
    if let fingerprint = model.status.fingerprint {
      SottoPalette.line.frame(height: 1)
      SettingsRow("Fingerprint", detail: fingerprint) {
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(fingerprint, forType: .string)
        }
        .buttonStyle(PrototypeButtonStyle())
      }
      .textSelection(.enabled)
      .accessibilityIdentifier("settings.serverModeFingerprint")
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Pairing tokens", detail: "One token pairs one device, with no sign-in") {
      Button("Manage…") { model.showTokens() }
        .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
        .accessibilityIdentifier("settings.tokenManage")
    }
    if !model.status.clientConnected {
      note(
        "No client has connected yet. If one can't reach this Mac, check that macOS Firewall allows flowd."
      )
    }
    note(
      "The server runs in your login session and its key is in your login Keychain, so this Mac needs to stay logged in. Turn on automatic login if it restarts unattended."
    )
  }

  @ViewBuilder private var missing: some View {
    if !model.status.missing.isEmpty {
      SottoPalette.line.frame(height: 1)
      SettingsRow(
        "Not available yet", detail: model.status.missing.joined(separator: "\n")
      ) {
        if model.status.missingModelBytes > 0 && model.status.ownership != .none {
          Button("Download…") { model.confirm = .download }
            .buttonStyle(PrototypeButtonStyle(minimumWidth: 99)).disabled(model.busy)
            .accessibilityIdentifier("settings.serverModeDownload")
        }
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).lineSpacing(4)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
  }

  private var addressText: String {
    let lines = model.addresses.map(\.title)
    if !lines.isEmpty { return lines.joined(separator: "\n") }
    return model.status.canOpenToNetwork
      ? "This server listens only on this Mac. Use your proxy's address, or open it to the network."
      : "None found on this Mac's network connections."
  }

  private var title: String {
    switch model.confirm {
    case .turnOn: "Turn on server mode?"
    case .turnOnExisting: "Start the server on this Mac?"
    case .turnOff: "Turn off server mode?"
    case .open: "Open this server to the network?"
    case .download: "Download models?"
    case nil: ""
    }
  }

  private var button: String {
    switch model.confirm {
    case .turnOn: "Turn On"
    case .turnOnExisting: "Start"
    case .turnOff: "Turn Off"
    case .open: "Open and Restart"
    case .download: "Download"
    case nil: ""
    }
  }

  private var explanation: String {
    switch model.confirm {
    case .turnOn:
      "The server starts at login and listens on all networks, not just this one. Anyone who can reach this Mac can try to connect, and tokens control who gets in. Dictation on this Mac keeps working, and the server loads its own models beside this Mac's, so the two together use more memory. Nothing is downloaded until you confirm it."
    case .turnOnExisting:
      "The server keeps the address and settings it already has."
    case .turnOff:
      "The server stops and stays off until you turn it on. Accounts, tokens, models and the server's identity stay on this Mac."
    case .open:
      "The server restarts and listens on all networks, not just this Mac. Anyone who can reach it can try to connect, and tokens control who gets in. If it isn't healthy within 60 seconds, the previous settings come back."
    case .download:
      "About \(model.modelDownloadSize) of speech and meeting models for the server. The server restarts for the download and is unavailable until it finishes."
    case nil: ""
    }
  }
}
