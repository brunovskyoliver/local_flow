import Foundation

/// One model pack `mtplx models --json` lists.
struct MTPLXModel: Decodable, Identifiable, Equatable, Sendable {
  var repoID: String
  var path: String
  var sizeGB: Double?
  var id: String { path }

  enum CodingKeys: String, CodingKey {
    case path
    case repoID = "repo_id"
    case sizeGB = "size_gb"
  }

  static func parse(_ json: Data) -> [MTPLXModel] {
    struct List: Decodable { var models: [MTPLXModel] }
    return (try? JSONDecoder().decode(List.self, from: json))?.models ?? []
  }
}

/// One model or profile oMLX exposes at `/v1/models` (e.g. `smart`, `smart:fast`).
struct OMLXModel: Decodable, Identifiable, Equatable, Sendable {
  var id: String
  var maxModelLen: Int?

  enum CodingKeys: String, CodingKey {
    case id
    case maxModelLen = "max_model_len"
  }

  static func parse(_ json: Data) -> [OMLXModel] {
    struct List: Decodable { var data: [OMLXModel] }
    return (try? JSONDecoder().decode(List.self, from: json))?.data ?? []
  }
}

/// Where summaries go: flowd's rewrite model, or an oMLX model through
/// `--analysis-backend` (server/cmd/flowd/main.go).
struct AnalysisBackend: Equatable, Sendable {
  var url: String
  var model: String
  var keyFile: String?
}

/// ProgramArguments edits, matching what scripts/install-remote-server.sh renders.
enum AgentArguments {
  static let analysisFlags = [
    "--analysis-backend", "--analysis-model", "--analysis-backend-key-file",
  ]

  static func analysisBackend(_ arguments: [String]) -> AnalysisBackend? {
    guard let url = arguments.value(after: "--analysis-backend"),
      let model = arguments.value(after: "--analysis-model")
    else { return nil }
    return AnalysisBackend(
      url: url, model: model, keyFile: arguments.value(after: "--analysis-backend-key-file"))
  }

  /// Drops any analysis flags and their values, then appends `backend`'s, as the installer
  /// does after the other flags.
  static func setting(_ backend: AnalysisBackend?, in arguments: [String]) -> [String] {
    var out: [String] = []
    var i = arguments.startIndex
    while i < arguments.endIndex {
      if analysisFlags.contains(arguments[i]) {
        i += 2
        continue
      }
      out.append(arguments[i])
      i += 1
    }
    if let backend {
      out += ["--analysis-backend", backend.url, "--analysis-model", backend.model]
      if let keyFile = backend.keyFile { out += ["--analysis-backend-key-file", keyFile] }
    }
    return out
  }

  /// Replaces the value after `flag`; nil when the flag is missing.
  static func replacing(_ flag: String, with value: String, in arguments: [String]) -> [String]? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.endIndex else { return nil }
    var out = arguments
    out[i + 1] = value
    return out
  }

  /// The mtplx executable in the MTPLX agent's arguments (`/usr/bin/env VAR=… <mtplx> serve …`).
  static func mtplxExecutable(_ arguments: [String]) -> String? {
    guard let serve = arguments.firstIndex(of: "serve"), serve > 0 else { return nil }
    return arguments[serve - 1]
  }
}

extension AgentPlist {
  /// Rewrites only `ProgramArguments`, keeping every other key the installer wrote.
  static func write(_ arguments: [String], to url: URL) throws {
    let data = try Data(contentsOf: url)
    guard
      var plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw CocoaError(.propertyListReadCorrupt) }
    plist["ProgramArguments"] = arguments
    let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try out.write(to: url, options: .atomic)
  }
}

/// Swaps an agent's plist, restarts it and keeps the change only if the agent reports
/// healthy within the deadline; otherwise puts the previous plist back and restarts again.
enum AgentChange {
  enum Outcome: Equatable, Sendable {
    case applied
    case rolledBack(String)
    case failed(String)
  }

  static func apply(
    label: String, plist: URL, arguments: [String], deadline: Duration = .seconds(60),
    progress: @MainActor (String) -> Void,
    healthy: @Sendable (_ previousPID: Int32?) async -> Bool
  ) async -> Outcome {
    let backups = Server.appSupport.appending(path: "plist-backups")
    let backup = backups.appending(path: "\(label).plist")
    let previousPID = await Launchctl.job(label)?.pid
    do {
      try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: backup)
      try FileManager.default.copyItem(at: plist, to: backup)
      try AgentPlist.write(arguments, to: plist)
    } catch {
      return .failed("Could not write \(plist.lastPathComponent): \(error.localizedDescription)")
    }
    await progress("Restarting \(label)…")
    if let failure = await Launchctl.reload(label, plist: plist) {
      await restore(label: label, plist: plist, backup: backup)
      return .rolledBack(failure)
    }
    await progress("Waiting up to \(deadline.components.seconds) s for \(label) to report healthy…")
    let clock = ContinuousClock()
    let end = clock.now + deadline
    var healthyChecks = 0
    while clock.now < end {
      try? await Task.sleep(for: .seconds(3))
      healthyChecks = await healthy(previousPID) ? healthyChecks + 1 : 0
      if healthyChecks >= 2 { return .applied }
    }
    await progress("Not healthy; restoring the previous plist…")
    await restore(label: label, plist: plist, backup: backup)
    return .rolledBack("\(label) did not report healthy within \(deadline.components.seconds) s")
  }

  private static func restore(label: String, plist: URL, backup: URL) async {
    _ = try? FileManager.default.replaceItemAt(plist, withItemAt: backup, backupItemName: nil)
    _ = await Launchctl.reload(label, plist: plist)
  }
}

extension Launchctl {
  /// bootout, wait for the job to go, bootstrap from the plist. nil on success.
  static func reload(_ label: String, plist: URL) async -> String? {
    if await job(label) != nil {
      _ = await runProcess("/bin/launchctl", ["bootout", "\(Server.domain)/\(label)"])
      // bootstrap fails with error 5 while the old job is still being torn down.
      for _ in 0..<50 {
        if await job(label) == nil { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    let result = await runProcess("/bin/launchctl", ["bootstrap", Server.domain, plist.path])
    return result.succeeded ? nil : "launchctl bootstrap failed: \(result.error)"
  }
}
