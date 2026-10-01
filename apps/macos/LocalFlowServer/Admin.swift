import Foundation

/// Users, devices and the audit log, read from and changed through the existing
/// `flowd admin` commands (specs/014-remote-dictation-server/contracts/flowd-cli.md).
/// The app runs in the GUI session, where the login Keychain is unlocked.
struct AdminUser: Identifiable, Equatable, Sendable {
  var id: Int
  var provider: String
  var display: String
  var state: String
  var created: String
  var devices: [AdminDevice] = []
}

struct AdminDevice: Identifiable, Equatable, Sendable {
  var id: Int
  var name: String
  var state: String
  var enrolled: String
  var lastSeen: String
}

struct AuditEntry: Identifiable, Equatable, Sendable {
  var id: Int
  var time: String
  var actor: String
  var action: String
  var target: String
  var outcome: String
}

enum Admin {
  /// `flowd admin list`: a user line, then its devices indented by two spaces. Columns are
  /// padded and names may hold spaces, so each line is matched from both ends.
  static func parseList(_ text: String) -> [AdminUser] {
    let states = "(pending|approved|rejected|revoked)"
    let time = #"(\d{4}-\d\d-\d\d \d\d:\d\d)"#
    let user = try! Regex(
      #"^user (\d+)\s+(\S+)\s+(.*?)\s+"# + states + #"\s+created "# + time + "$")
    let device = try! Regex(
      #"^\s+device (\d+)\s+(.*?)\s+"# + states + #"\s+enrolled "# + time + #"\s+last seen (never|"#
        + time.dropFirst() + "$")
    var users: [AdminUser] = []
    for line in text.split(separator: "\n") {
      if let m = try? user.wholeMatch(in: line) {
        users.append(
          AdminUser(
            id: Int(m[1].substring!)!, provider: String(m[2].substring!),
            display: String(m[3].substring!), state: String(m[4].substring!),
            created: String(m[5].substring!)))
      } else if let m = try? device.wholeMatch(in: line), !users.isEmpty {
        users[users.count - 1].devices.append(
          AdminDevice(
            id: Int(m[1].substring!)!, name: String(m[2].substring!),
            state: String(m[3].substring!),
            enrolled: String(m[4].substring!), lastSeen: String(m[5].substring!)))
      }
    }
    return users
  }

  /// `flowd admin audit`: time, actor, action, target and outcome, two spaces apart.
  static func parseAudit(_ text: String) -> [AuditEntry] {
    text.split(separator: "\n").enumerated().compactMap { index, line in
      let cells = line.components(separatedBy: "  ")
      guard cells.count == 5 else { return nil }
      return AuditEntry(
        id: index, time: cells[0], actor: cells[1], action: cells[2], target: cells[3],
        outcome: cells[4])
    }
  }

  /// The admin verbs a row offers, by kind and state. flowd enforces the transitions;
  /// this only hides buttons that would be refused.
  static func actions(kind: String, state: String) -> [String] {
    switch (kind, state) {
    case ("user", "pending"): ["approve", "reject"]
    case ("user", "approved"), ("device", "approved"): ["revoke"]
    case ("device", "pending"): ["approve", "revoke"]
    case ("user", "revoked"), ("user", "rejected"), ("device", "revoked"): ["approve"]
    default: []
    }
  }

  static func run(_ arguments: [String]) async -> ProcessResult {
    await runProcess(Server.flowd.path, ["admin", "--data-dir", Server.dataDir.path] + arguments)
  }
}
