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
  /// `mac`, `windows`, `iphone`, or nil when the device never said (or flowd predates kinds).
  var kind: String? = nil
  var state: String
  var enrolled: String
  var lastSeen: String

  var kindLabel: String {
    switch kind {
    case "mac": "Mac"
    case "windows": "Windows"
    case "iphone": "iPhone"
    default: "Unknown"
    }
  }
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

  /// `list --json`, or the text `list` when this flowd predates it: an older flowd exits 1
  /// with its usage line and no JSON (specs/028-server-users-and-rewrite-warmup/contracts/admin-cli.md).
  static func listUsers(
    run: @Sendable ([String]) async -> ProcessResult = { await Admin.run($0) }
  ) async -> (result: ProcessResult, users: [AdminUser]) {
    let json = await run(["list", "--json"])
    if json.succeeded {
      guard let users = parseListJSON(json.output) else {
        return (ProcessResult(status: 1, output: "", error: "list --json: unreadable output"), [])
      }
      return (json, users)
    }
    guard json.status == 1, !json.output.contains("{") else { return (json, []) }
    let text = await run(["list"])
    return (text, text.succeeded ? parseList(text.output) : [])
  }

  /// `list --json` with `schema_version` 1; nil for anything else.
  static func parseListJSON(_ text: String) -> [AdminUser]? {
    struct Device: Decodable {
      var id: Int
      var name: String
      var kind: String?
      var state: String
      var enrolledAt: String
      var lastSeenAt: String?
    }
    struct User: Decodable {
      var id: Int
      var provider: String
      var display: String?
      var state: String
      var createdAt: String
      var devices: [Device]
    }
    struct List: Decodable {
      var schemaVersion: Int
      var users: [User]
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let list = try? decoder.decode(List.self, from: Data(text.utf8)),
      list.schemaVersion == 1
    else { return nil }
    return list.users.map { user in
      AdminUser(
        id: user.id, provider: user.provider, display: user.display ?? "-", state: user.state,
        created: localTime(user.createdAt),
        devices: user.devices.map { device in
          AdminDevice(
            id: device.id, name: device.name, kind: device.kind, state: device.state,
            enrolled: localTime(device.enrolledAt),
            lastSeen: device.lastSeenAt.map { localTime($0) } ?? "never")
        })
    }
  }

  /// RFC 3339 UTC to the text form's local "yyyy-MM-dd HH:mm"; unparseable input passes through.
  static func localTime(_ rfc3339: String, in zone: TimeZone = .current) -> String {
    guard let date = ISO8601DateFormatter().date(from: rfc3339) else { return rfc3339 }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  static func run(_ arguments: [String]) async -> ProcessResult {
    await runProcess(Server.flowd.path, ["admin", "--data-dir", Server.dataDir.path] + arguments)
  }
}

extension Admin {
  /// Why a Devices reload failed, or nil once `list` and `audit` both succeed (UI-11).
  static func loadError(listed: ProcessResult, audited: ProcessResult) -> String? {
    guard let failed = !listed.succeeded ? listed : !audited.succeeded ? audited : nil
    else { return nil }
    return "flowd admin failed: " + failed.error.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A row of `flowd admin token list --json`: never a hash or a value.
struct AdminPairingToken: Decodable, Identifiable, Equatable, Sendable {
  var id: Int
  var label: String
  var state: String
  var deviceID: Int
  var expiresAt: String

  enum CodingKeys: String, CodingKey {
    case id, label, state
    case deviceID = "device_id"
    case expiresAt = "expires_at"
  }
}

/// `flowd admin token create --json`: shown once, held only in the Pairing tab's state.
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

extension Admin {
  static func parseTokens(_ text: String) -> [AdminPairingToken] {
    (try? JSONDecoder().decode([AdminPairingToken].self, from: Data(text.utf8))) ?? []
  }

  static func tokenCreateArguments(label: String, user: Int?, ttl: String, address: String)
    -> [String]
  {
    var arguments = ["token", "create", "--label", label, "--ttl", ttl, "--json"]
    if let user { arguments += ["--user", String(user)] }
    if !address.isEmpty { arguments += ["--address", address] }
    return arguments
  }
}
