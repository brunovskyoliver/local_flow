import AppKit
import CoreImage
import Observation
import SwiftUI

@MainActor @Observable
final class PairingModel {
  private(set) var tokens: [AdminPairingToken] = []
  private(set) var users: [AdminUser] = []
  /// In this state only; `clearCreated` runs when the result is dismissed or the tab goes away.
  private(set) var created: CreatedPairingToken?
  private(set) var message: String?
  private(set) var busy = false
  @ObservationIgnored private let run: @Sendable ([String]) async -> ProcessResult

  init(run: @escaping @Sendable ([String]) async -> ProcessResult = { await Admin.run($0) }) {
    self.run = run
  }

  func reload() async {
    async let listed = run(["token", "list", "--json"])
    async let people = run(["list"])
    let (list, users) = await (listed, people)
    if list.succeeded { tokens = Admin.parseTokens(list.output) }
    if users.succeeded {
      self.users = Admin.parseList(users.output).filter { $0.state == "approved" }
    }
    if !list.succeeded { message = Self.failure("token list", list) }
  }

  func create(label: String, user: Int?, ttl: String, address: String) async {
    busy = true
    defer { busy = false }
    let result = await run(
      Admin.tokenCreateArguments(label: label, user: user, ttl: ttl, address: address))
    guard result.succeeded,
      let value = try? JSONDecoder().decode(
        CreatedPairingToken.self, from: Data(result.output.utf8))
    else {
      message = Self.failure("token create", result)
      return
    }
    created = value
    message = nil
    await reload()
  }

  func revoke(_ id: Int) async {
    await apply(["token", "revoke", String(id)], name: "token revoke")
  }
  func revokeDevice(_ id: Int) async {
    await apply(["revoke", "device", String(id)], name: "revoke")
  }
  func clearCreated() { created = nil }

  private func apply(_ arguments: [String], name: String) async {
    busy = true
    defer { busy = false }
    let result = await run(arguments)
    message =
      result.succeeded
      ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : Self.failure(name, result)
    await reload()
  }

  /// stderr only, which never holds a value. A flowd from before pairing answers with its usage.
  private static func failure(_ verb: String, _ result: ProcessResult) -> String {
    let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
    return reason.hasPrefix("usage:")
      ? "This flowd has no pairing tokens. Update the server first."
      : "flowd admin \(verb) failed: \(reason)"
  }
}

struct PairingView: View {
  let model: PairingModel
  @State private var label = ""
  @State private var user = 0  // 0 is a new person
  @State private var ttl = "24h"
  @State private var address = ""
  @State private var confirm: (isDevice: Bool, id: Int, name: String)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Each token pairs one device, once. This tab runs `flowd admin token`.")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Refresh") { Task { await model.reload() } }
      }
      if let message = model.message { Text(message).font(.callout) }
      if let created = model.created { result(created) } else { form }
      List {
        ForEach(model.tokens) { token in
          HStack {
            VStack(alignment: .leading) {
              Text(token.label)
              Text("expires \(Self.date(token.expiresAt))").font(.caption).foregroundStyle(
                .secondary)
            }
            Spacer()
            Text(token.state).foregroundStyle(token.state == "live" ? .green : .secondary)
            if token.state == "live" {
              Button("Revoke") { confirm = (false, token.id, token.label) }
            } else if token.deviceID != 0 {
              Button("Revoke Device") { confirm = (true, token.deviceID, token.label) }
            }
          }
        }
        if model.tokens.isEmpty { Text("No tokens yet.").foregroundStyle(.secondary) }
      }
    }
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
          if confirm.isDevice {
            await model.revokeDevice(confirm.id)
          } else {
            await model.revoke(confirm.id)
          }
        }
      }
    } message: {
      Text(
        confirm?.isDevice == true
          ? "The device stops getting service at once; approve undoes it."
          : "Nobody can pair with this token any more.")
    }
  }

  private var form: some View {
    GroupBox("New token") {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        GridRow {
          Text("Label")
          TextField("Ada's iPhone", text: $label)
        }
        GridRow {
          Text("For")
          Picker("For", selection: $user) {
            Text("A new person").tag(0)
            ForEach(model.users) { Text($0.display).tag($0.id) }
          }
          .labelsHidden()
        }
        GridRow {
          Text("Expires after")
          Picker("Expires after", selection: $ttl) {
            Text("1 hour").tag("1h")
            Text("24 hours").tag("24h")
            Text("7 days").tag("7d")
          }
          .labelsHidden()
        }
        GridRow {
          Text("Address")
          TextField("Optional, for a link: http://192.168.1.20:8090" as String, text: $address)
        }
      }
      .padding(4)
      HStack {
        Spacer()
        Button("Create Token") {
          let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
          let origin = address.trimmingCharacters(in: .whitespacesAndNewlines)
          Task {
            await model.create(label: name, user: user == 0 ? nil : user, ttl: ttl, address: origin)
            if model.created != nil { label = "" }
          }
        }
        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func result(_ created: CreatedPairingToken) -> some View {
    GroupBox("\(created.label): shown once") {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Text(created.token).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          HStack {
            Button("Copy Token") { copy(created.token) }
            if !created.link.isEmpty { Button("Copy Link") { copy(created.link) } }
            Button("Done") { model.clearCreated() }
          }
          Text(
            "Pasting the token is safest: on an iPhone another installed app could claim a link. Anyone who gets it first can use it. Expires \(Self.date(created.expiresAt))."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if !created.link.isEmpty, let code = Self.qrCode(created.link) {
          // The white quiet zone is what makes it scan in dark mode.
          Image(nsImage: code).interpolation(.none).padding(12).background(Color.white)
            .accessibilityLabel("QR code with the pairing link")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
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

  private static func date(_ text: String) -> String {
    (try? Date(text, strategy: .iso8601))?.formatted(date: .abbreviated, time: .shortened) ?? text
  }

  nonisolated static func qrCode(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
    // Whole points per module and doubled pixels keep the modules sharp.
    let points = (160 / output.extent.width).rounded(.up)
    let scaled = output.transformed(by: CGAffineTransform(scaleX: points * 2, y: points * 2))
    guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(
      cgImage: image, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2)
    )
  }
}
