import AppKit
import CoreImage
import LocalFlowCore
import SwiftUI

/// A row of `flowd admin token list --json`: never a hash or a value.
struct AdminPairingToken: Decodable, Identifiable, Equatable, Sendable {
  var id: Int
  var label: String
  var state: String
  var userID: Int
  var deviceID: Int
  var expiresAt: String

  enum CodingKeys: String, CodingKey {
    case id, label, state
    case userID = "user_id"
    case deviceID = "device_id"
    case expiresAt = "expires_at"
  }
}

/// `flowd admin token create --json`, the only time a token's value exists outside its holder.
struct CreatedPairingToken: Decodable, Equatable, Sendable {
  var label: String
  var expiresAt: String
  var token: String
  var link: String

  enum CodingKeys: String, CodingKey {
    case label, token, link
    case expiresAt = "expires_at"
  }
}

/// An address a token's link can name.
struct ServerAddress: Identifiable, Equatable, Sendable {
  var title: String
  var origin: String
  var id: String { origin }
}

@MainActor @Observable
final class TokensModel {
  struct User: Identifiable, Equatable {
    var id: Int
    var display: String
  }
  enum Lifetime: String, CaseIterable, Identifiable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"
    var id: String { rawValue }
    var title: String {
      switch self {
      case .hour: "1 hour"
      case .day: "24 hours"
      case .week: "7 days"
      }
    }
  }

  let addresses: [ServerAddress]
  private(set) var tokens: [AdminPairingToken] = []
  private(set) var users: [User] = []
  /// Kept here and nowhere else; `clearCreated` runs when the sheet closes.
  private(set) var created: CreatedPairingToken?
  private(set) var message: String?
  private(set) var busy = false
  @ObservationIgnored private let admin: ServerAdmin

  init(admin: ServerAdmin, addresses: [ServerAddress]) {
    self.admin = admin
    self.addresses = addresses
  }

  /// Users a new device can join, from `flowd admin list`: its padded columns end in a state
  /// and a date, and display names may hold spaces.
  nonisolated static func approvedUsers(_ text: String) -> [User] {
    let line = /^user (\d+)\s+\S+\s+(.*?)\s+approved\s+created .*$/
    return text.split(separator: "\n").compactMap { row in
      guard let match = try? line.wholeMatch(in: row), let id = Int(match.1) else { return nil }
      return User(id: id, display: String(match.2))
    }
  }

  func reload() async {
    async let listed = admin.run(["token", "list", "--json"])
    async let people = admin.run(["list"])
    let (list, people2) = await (listed, people)
    guard list.succeeded else {
      message = Self.failure("list", list)
      return
    }
    tokens =
      (try? JSONDecoder().decode([AdminPairingToken].self, from: Data(list.output.utf8))) ?? []
    if people2.succeeded { users = Self.approvedUsers(people2.output) }
  }

  func create(label: String, user: Int?, lifetime: Lifetime, address: String?) async {
    busy = true
    defer { busy = false }
    var arguments = ["token", "create", "--label", label, "--ttl", lifetime.rawValue, "--json"]
    if let user { arguments += ["--user", String(user)] }
    if let address { arguments += ["--address", address] }
    let result = await admin.run(arguments)
    guard result.succeeded,
      let value = try? JSONDecoder().decode(
        CreatedPairingToken.self, from: Data(result.output.utf8))
    else {
      message = Self.failure("create", result)
      return
    }
    created = value
    message = nil
    await reload()
  }

  func revokeToken(_ id: Int) async {
    await apply(["token", "revoke", String(id)], name: "token revoke")
  }

  func revokeDevice(_ id: Int) async {
    await apply(["revoke", "device", String(id)], name: "revoke")
  }

  func clearCreated() { created = nil }

  private func apply(_ arguments: [String], name: String) async {
    busy = true
    defer { busy = false }
    let result = await admin.run(arguments)
    message =
      result.succeeded
      ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : Self.failure(name, result)
    await reload()
  }

  /// stderr only, which never holds a value. A flowd from before pairing answers with its usage.
  private static func failure(_ verb: String, _ result: ServerProcessResult) -> String {
    result.succeeded
      ? "flowd admin \(verb) answered with something unexpected."
      : result.reason.hasPrefix("usage:")
        ? "This server's flowd has no pairing tokens. Update the server first."
        : "flowd admin \(verb) failed: \(result.reason)"
  }
}

enum PairingQRCode {
  /// nil only if Core Image refuses the text; nearest-neighbor keeps the modules sharp.
  static func image(for text: String, side: CGFloat) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage, output.extent.width > 0,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    let result = NSImage(cgImage: image, size: NSSize(width: side, height: side))
    return result
  }
}

/// Create, show once, list and revoke. Opened from Settings › Server; closing it forgets the value.
struct TokensView: View {
  @Bindable var model: TokensModel
  @Environment(\.dismiss) private var dismiss
  @State private var label = ""
  @State private var user = 0  // 0 is a new person
  @State private var lifetime = TokensModel.Lifetime.day
  @State private var address = ""  // "" is no address
  @State private var confirm: Confirm?

  private enum Confirm: Identifiable {
    case token(AdminPairingToken)
    case device(AdminPairingToken)
    var id: String {
      switch self {
      case .token(let token): "token\(token.id)"
      case .device(let token): "device\(token.id)"
      }
    }
    var name: String {
      switch self {
      case .token(let token), .device(let token): token.label
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Pairing tokens").font(.flow(size: 17, weight: .medium))
          Spacer()
          Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 8)
        if let created = model.created { result(created) } else { form }
        if let message = model.message {
          Text(message).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        }
        SottoPalette.line.frame(height: 1)
        list
      }
      .padding(24)
    }
    .frame(width: 540, height: 620)
    .disabled(model.busy)
    .task { await model.reload() }
    .onDisappear { model.clearCreated() }
    .confirmationDialog(
      "Revoke \(confirm?.name ?? "")?",
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    ) {
      Button("Revoke", role: .destructive) {
        guard let confirm else { return }
        Task {
          switch confirm {
          case .token(let token): await model.revokeToken(token.id)
          case .device(let token): await model.revokeDevice(token.deviceID)
          }
        }
      }
    } message: {
      switch confirm {
      case .device:
        Text("The device stops getting service at once. Its user and data stay on the server.")
      default: Text("Nobody can pair with this token any more.")
      }
    }
  }

  @ViewBuilder private var form: some View {
    SettingsRow("Label", detail: "Who or what this token is for") {
      RewriteInputSurface(symbol: "tag") {
        TextField("Ada's iPhone", text: $label).accessibilityIdentifier("settings.tokenLabel")
      }
      .frame(width: 220)
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("For") {
      Picker("For", selection: $user) {
        Text("A new person").tag(0)
        ForEach(model.users) { Text($0.display).tag($0.id) }
      }
      .labelsHidden().tint(SottoPalette.ink).frame(width: 220)
      .accessibilityIdentifier("settings.tokenUser")
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Expires after") {
      Picker("Expires after", selection: $lifetime) {
        ForEach(TokensModel.Lifetime.allCases) { Text($0.title).tag($0) }
      }
      .labelsHidden().tint(SottoPalette.ink).frame(width: 220)
      .accessibilityIdentifier("settings.tokenLifetime")
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Address", detail: "A link and QR code need one; the token alone does not") {
      Picker("Address", selection: $address) {
        Text("None").tag("")
        ForEach(model.addresses) { Text($0.title).tag($0.origin) }
      }
      .labelsHidden().tint(SottoPalette.ink).frame(width: 220)
      .accessibilityIdentifier("settings.tokenAddress")
    }
    SottoPalette.line.frame(height: 1)
    HStack {
      Spacer()
      Button("Create Token") {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
          await model.create(
            label: name, user: user == 0 ? nil : user, lifetime: lifetime,
            address: address.isEmpty ? nil : address)
          if model.created != nil { label = "" }
        }
      }
      .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
      .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("settings.tokenCreate")
    }
    .padding(.vertical, 14)
  }

  private func result(_ created: CreatedPairingToken) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(created.label): shown once. It can't be shown again after you close this.")
        .font(.flow(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
      Text(created.token).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings.tokenValue")
      HStack(spacing: 8) {
        Button("Copy Token") { copy(created.token) }
          .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
          .accessibilityIdentifier("settings.tokenCopy")
        if !created.link.isEmpty {
          Button("Copy Link") { copy(created.link) }
            .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
            .accessibilityIdentifier("settings.tokenCopyLink")
        }
      }
      if !created.link.isEmpty, let code = PairingQRCode.image(for: created.link, side: 180) {
        Image(nsImage: code).interpolation(.none).accessibilityLabel(
          "QR code with the pairing link")
      }
      Text(
        "Pasting the token is safest: on an iPhone another installed app could claim a link. Anyone who gets the token first can use it, so send it privately. Expires \(TokensView.date(created.expiresAt))."
      )
      .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).lineSpacing(4)
      .fixedSize(horizontal: false, vertical: true)
      Button("Done") { model.clearCreated() }
        .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
    }
    .padding(.vertical, 14)
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.tokens.isEmpty {
        Text("No tokens yet.").font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          .padding(.vertical, 14)
      }
      ForEach(model.tokens) { token in
        SettingsRow(
          token.label, detail: "\(token.state) · expires \(TokensView.date(token.expiresAt))"
        ) {
          if token.state == "live" {
            Button("Revoke") { confirm = .token(token) }
              .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
              .accessibilityIdentifier("settings.tokenRevoke")
          } else if token.deviceID != 0 {
            Button("Revoke Device") { confirm = .device(token) }
              .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
              .accessibilityIdentifier("settings.tokenRevokeDevice")
          }
        }
        SottoPalette.line.frame(height: 1)
      }
    }
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    // Clipboard managers skip concealed items (nspasteboard.org).
    pasteboard.setData(
      Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
  }

  static func date(_ text: String) -> String {
    (try? Date(text, strategy: .iso8601))?.formatted(date: .abbreviated, time: .shortened) ?? text
  }
}
