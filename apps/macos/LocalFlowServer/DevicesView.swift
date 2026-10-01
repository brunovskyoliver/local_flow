import Observation
import SwiftUI

@MainActor @Observable
final class DevicesModel {
  private(set) var users: [AdminUser] = []
  private(set) var audit: [AuditEntry] = []
  private(set) var message: String?
  private(set) var busy = false

  func reload() async {
    async let list = Admin.run(["list"])
    async let log = Admin.run(["audit", "--limit", "200"])
    let (listed, audited) = await (list, log)
    if listed.succeeded { users = Admin.parseList(listed.output) }
    if audited.succeeded { audit = Admin.parseAudit(audited.output) }
    if !listed.succeeded || !audited.succeeded {
      message = "flowd admin failed: " + (listed.succeeded ? audited : listed).error
    }
  }

  func apply(_ verb: String, _ kind: String, _ id: Int) async {
    busy = true
    let result = await Admin.run([verb, kind, String(id)])
    message =
      result.succeeded
      ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      : "flowd admin \(verb) failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"
    await reload()
    busy = false
  }
}

struct DevicesView: View {
  let model: DevicesModel
  @State private var confirm: (verb: String, kind: String, id: Int, name: String)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(
          "Approval and revocation run `flowd admin`; the running flowd applies them within a second."
        )
        .foregroundStyle(.secondary)
        Spacer()
        Button("Refresh") { Task { await model.reload() } }
      }
      if let message = model.message { Text(message).font(.callout) }
      List {
        ForEach(model.users) { user in
          Section {
            ForEach(user.devices) { device in
              row(
                kind: "device", id: device.id, title: device.name, state: device.state,
                detail: "enrolled \(device.enrolled) · last seen \(device.lastSeen)")
            }
          } header: {
            row(
              kind: "user", id: user.id, title: Snapshot.active ? "user@example.com" : user.display,
              state: user.state, detail: "\(user.provider) · created \(user.created)")
          }
        }
        if model.users.isEmpty { Text("No users yet.").foregroundStyle(.secondary) }
      }
      .frame(minHeight: 160)
      Text("Audit log").font(.headline)
      Table(model.audit) {
        TableColumn("Time", value: \.time).width(130)
        TableColumn("Actor", value: \.actor)
        TableColumn("Action", value: \.action)
        TableColumn("Target", value: \.target)
        TableColumn("Outcome", value: \.outcome)
      }
    }
    .disabled(model.busy)
    .task { await model.reload() }
    .confirmationDialog(
      "\(confirm?.verb.capitalized ?? "") \(confirm?.name ?? "")?",
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    ) {
      Button(confirm?.verb.capitalized ?? "", role: .destructive) {
        guard let confirm else { return }
        Task { await model.apply(confirm.verb, confirm.kind, confirm.id) }
      }
    } message: {
      Text("A revoked or rejected device stops getting service at once; approve undoes it.")
    }
  }

  private func row(kind: String, id: Int, title: String, state: String, detail: String)
    -> some View
  {
    HStack {
      Image(systemName: kind == "user" ? "person.crop.circle" : "laptopcomputer")
      VStack(alignment: .leading) {
        Text(title).font(kind == "user" ? .headline : .body)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(state).foregroundStyle(
        state == "approved" ? .green : state == "pending" ? .orange : .red)
      ForEach(Admin.actions(kind: kind, state: state), id: \.self) { verb in
        Button(verb.capitalized) {
          if verb == "approve" {
            Task { await model.apply(verb, kind, id) }
          } else {
            confirm = (verb, kind, id, title)
          }
        }
      }
    }
  }
}
