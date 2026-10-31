import CryptoKit
import Darwin
import Foundation
import LocalFlowCore

/// A finished child process. Token values reach the app only through `output`, on stdout.
struct ServerProcessResult: Sendable, Equatable {
  var status: Int32
  var output: String
  var error: String
  var succeeded: Bool { status == 0 }
  /// The first line of stderr, for showing to the owner.
  var reason: String {
    error.split(separator: "\n").first.map(String.init) ?? "exit \(status)"
  }
}

/// Every `launchctl` and `flowd admin` run goes through this, so tests never start one.
protocol ServerProcessRunner: Sendable {
  func run(_ path: String, _ arguments: [String]) async -> ServerProcessResult
}

/// Runs an executable by absolute path, never through a shell, off the main actor.
struct SystemServerProcessRunner: ServerProcessRunner {
  func run(_ path: String, _ arguments: [String]) async -> ServerProcessResult {
    await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      let out = Pipe()
      let err = Pipe()
      process.standardOutput = out
      process.standardError = err
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch {
        return ServerProcessResult(status: -1, output: "", error: "could not start \(path)")
      }
      // stderr on its own thread: a child that fills it while stdout is open must not block.
      let errorRead = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
      let output = out.fileHandleForReading.readDataToEndOfFile()
      let error = await errorRead.value
      process.waitUntilExit()
      return ServerProcessResult(
        status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
        error: String(decoding: error, as: UTF8.self))
    }.value
  }
}

/// The server's labels, ports and directories, the same ones scripts/install-remote-server.sh
/// uses. Separate from the client's own agents, and a development build has only its own.
struct ServerModePaths: Sendable, Equatable {
  let dev: Bool
  let home: URL

  init(identity: AppIdentity) {
    dev = identity.variant == .dev
    home = identity.home
  }

  var label: String {
    dev ? "org.localflow.LocalFlow.dev.remote" : "org.localflow.LocalFlow.remote"
  }
  var mtplxLabel: String { label + ".mtplx" }
  var remotePort: Int { dev ? 18090 : 8090 }
  var localPort: Int { dev ? 18091 : 8091 }
  var mtplxPort: Int { dev ? 18092 : 8092 }
  var adminPort: Int { dev ? 18093 : 8093 }
  private var directoryName: String { dev ? "LocalFlow Server Dev" : "LocalFlow Server" }
  var dataDir: URL { home.appending(path: "Library/Application Support/\(directoryName)") }
  var binDir: URL { dataDir.appending(path: "bin") }
  var flowd: URL { binDir.appending(path: "flowd") }
  var logDir: URL { home.appending(path: "Library/Logs/\(directoryName)") }
  var plist: URL { home.appending(path: "Library/LaunchAgents/\(label).plist") }
  var mtplxPlist: URL { home.appending(path: "Library/LaunchAgents/\(mtplxLabel).plist") }
}

/// `flowd admin` for this server. It always runs the data directory's own flowd: a newer one
/// from the app would migrate an adopted server's database past what that server can open.
struct ServerAdmin: Sendable {
  let paths: ServerModePaths
  let runner: any ServerProcessRunner

  func run(_ arguments: [String]) async -> ServerProcessResult {
    await runner.run(
      paths.flowd.path,
      ["admin", "--data-dir", paths.dataDir.path] + (paths.dev ? ["--dev"] : []) + arguments)
  }
}

/// Who owns the agent at the server's label. Only an agent this app wrote may be rewritten.
enum ServerOwnership: Sendable, Equatable {
  case none, managed, adopted
}

struct ServerModeStatus: Sendable, Equatable {
  var ownership: ServerOwnership = .none
  var loaded = false
  var running = false
  /// `--remote-listen` from the plist.
  var listen: String?
  /// The running server's own answer, from its public identity route; no Keychain access.
  var fingerprint: String?
  /// Services that can't work yet, and why.
  var missing: [String] = []
  /// Bytes left to download for the speech and meeting models.
  var missingModelBytes: Int64 = 0
  var clientConnected = false

  /// A loopback bind is reachable only through a local proxy or tunnel.
  var canOpenToNetwork: Bool {
    guard let listen else { return false }
    return ServerModeController.isLoopback(listen: listen)
  }
}

enum ServerModeError: LocalizedError, Equatable {
  case helpersMissing
  case noPlist
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .helpersMissing: "This build of LocalFlow doesn't include the server helpers."
    case .noPlist: "The server's launch agent has no plist to start from."
    case .failed(let reason): reason
    }
  }
}

/// A launch agent as `launchctl print` reports it; nested blocks are indented deeper.
struct ServerAgentJob: Equatable, Sendable {
  var running = false
  var pid: Int32?

  static func parse(_ text: String) -> ServerAgentJob {
    var job = ServerAgentJob()
    for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
      guard parts.count == 2 else { continue }
      if parts[0] == "state" { job.running = parts[1] == "running" }
      if parts[0] == "pid" { job.pid = Int32(parts[1]) }
    }
    return job
  }
}

/// Server mode (research R8): installs and runs the same launch agent as
/// scripts/install-remote-server.sh. flowd stays a separate process, and nothing here touches
/// the client's own agents or preferences.
///
/// The app records a hash of each plist it writes. A plist that doesn't match, a loaded agent
/// with no plist or lost preferences all mean someone else made this server, so it is adopted:
/// its plist and binaries stay as they are. Failing towards adoption can only cost a resync.
@MainActor
final class ServerModeController {
  nonisolated static let plistHashKey = "serverMode.plistSHA256"
  nonisolated static let helpersStampKey = "serverMode.helpersStamp"
  nonisolated static let enabledKey = "serverMode.enabled"
  nonisolated static let customAddressKey = "serverMode.customAddress"
  /// Models the server needs, as `flowd-speech provision --meeting` fetches them.
  private static let models: [(file: String, root: String, service: String)] = [
    ("parakeet-v3.json", "parakeet-v3", "Dictation"),
    ("whisper-large-v3-turbo.json", "whisper-large-v3-turbo", "Meetings"),
    (
      "speaker-diarization-offline.json", "speaker-diarization-offline/speaker-diarization",
      "Meetings"
    ),
  ]
  private static let helpers = ["flowd", "flowd-speech", "localflow-whisper-engine"]
  private static let resourceBundle = "FluidAudio_FluidAudio.bundle"

  let paths: ServerModePaths
  let admin: ServerAdmin
  private let localAI: URL
  private let backups: URL
  private let defaults: UserDefaults
  private let runner: any ServerProcessRunner
  private let contents: URL
  private let uid: UInt32
  private let probe: @Sendable (URL) async -> RemoteIdentityAnswer?
  private let pollInterval: Duration
  private let files = FileManager.default

  /// The part of `GET /v1/remote/identity` this needs.
  struct RemoteIdentityAnswer: Sendable, Equatable { var fingerprint: String }

  /// `contents` is the app's Contents folder.
  init(
    identity: AppIdentity, defaults: UserDefaults, runner: any ServerProcessRunner, contents: URL,
    uid: UInt32 = getuid(), pollInterval: Duration = .seconds(3),
    probe: @escaping @Sendable (URL) async -> RemoteIdentityAnswer?
  ) {
    paths = ServerModePaths(identity: identity)
    admin = ServerAdmin(paths: paths, runner: runner)
    localAI = identity.applicationSupportDirectory.appending(path: "LocalAI")
    backups = identity.applicationSupportDirectory.appending(path: "ServerMode")
    self.defaults = defaults
    self.runner = runner
    self.contents = contents
    self.uid = uid
    self.pollInterval = pollInterval
    self.probe = probe
  }

  // MARK: Status

  func ownership(loaded: Bool) -> ServerOwnership {
    guard let data = try? Data(contentsOf: paths.plist) else { return loaded ? .adopted : .none }
    return Self.hash(data) == defaults.string(forKey: Self.plistHashKey) ? .managed : .adopted
  }

  func status() async -> ServerModeStatus {
    let job = await self.job(paths.label)
    var status = ServerModeStatus()
    status.loaded = job != nil
    status.running = job?.running == true
    status.ownership = ownership(loaded: job != nil)
    status.listen = arguments(paths.plist)?.value(after: "--remote-listen")
    if status.ownership == .none {
      status.listen = nil
      if !helpersPresent { status.missing.append(ServerModeError.helpersMissing.errorDescription!) }
    }
    if status.running, let port = status.listen.flatMap(Self.port(listen:)) {
      status.fingerprint = await probe(healthURL(port: port))?.fingerprint
      let people = await admin.run(["list"])
      status.clientConnected = people.succeeded && people.output.contains(/last seen \d/)
    }
    let (missing, bytes) = missingModels()
    status.missing += missing
    status.missingModelBytes = bytes
    if status.ownership != .none {
      if !files.fileExists(atPath: paths.mtplxPlist.path) {
        status.missing.append(
          "Rewriting and summaries: set up local AI in LocalFlow, then turn server mode off and on."
        )
      }
      if !files.isExecutableFile(atPath: paths.binDir.appending(path: "flowd-meeting").path) {
        status.missing.append("Meetings sent from a phone: this server has no flowd-meeting.")
      }
    }
    return status
  }

  /// Compares file sizes against the pinned descriptors, the ones installed with the server
  /// when it has them. `provision` does the full hash check when it runs.
  private func missingModels() -> (services: [String], bytes: Int64) {
    struct Descriptor: Decodable {
      struct File: Decodable {
        var path: String
        var size: Int64
      }
      var files: [File]
    }
    var services: [String] = []
    var total: Int64 = 0
    for model in Self.models {
      let installed = paths.binDir.appending(path: model.file)
      let url =
        files.fileExists(atPath: installed.path)
        ? installed : contents.appending(path: "Resources/\(model.file)")
      guard let data = try? Data(contentsOf: url),
        let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data)
      else { continue }
      let root = paths.dataDir.appending(path: "Models/\(model.root)")
      let bytes = descriptor.files.reduce(into: Int64(0)) { sum, file in
        let path = root.appending(path: file.path).path
        let size = (try? files.attributesOfItem(atPath: path))?[.size] as? Int64
        if size != file.size { sum += file.size }
      }
      total += bytes
      let line = "\(model.service): models not downloaded."
      if bytes > 0, !services.contains(line) { services.append(line) }
    }
    return (services, total)
  }

  /// Reachable addresses for a token's link: none while the server binds only to loopback.
  func addresses(listen: String?, interfaces: [String]) -> [ServerAddress] {
    var found: [ServerAddress] = []
    if let listen, !Self.isLoopback(listen: listen), let port = Self.port(listen: listen) {
      found = ServerAddresses.list(ips: interfaces, port: port)
    }
    if let custom = defaults.string(forKey: Self.customAddressKey),
      let origin = RemoteDictationSettings.origin(custom)?.absoluteString
    {
      found.append(ServerAddress(title: "Custom: \(origin)", origin: origin))
    }
    return found
  }

  /// False if the text is not a usable address; empty clears it.
  func setCustomAddress(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      defaults.removeObject(forKey: Self.customAddressKey)
      return true
    }
    guard let origin = RemoteDictationSettings.origin(trimmed) else { return false }
    defaults.set(origin.absoluteString, forKey: Self.customAddressKey)
    return true
  }

  var customAddress: String { defaults.string(forKey: Self.customAddressKey) ?? "" }

  // MARK: On and off

  func turnOn() async throws {
    let loaded = await job(paths.label) != nil
    if loaded { return }
    switch ownership(loaded: false) {
    case .adopted: break
    case .none:
      try await install(listen: "0.0.0.0:\(paths.remotePort)")
    case .managed:
      guard helpersPresent else { throw ServerModeError.helpersMissing }
      if defaults.string(forKey: Self.helpersStampKey) != helpersStamp { try syncHelpers() }
      let listen = arguments(paths.plist)?.value(after: "--remote-listen")
      try await install(listen: listen ?? "0.0.0.0:\(paths.remotePort)")
    }
    try await start()
    defaults.set(true, forKey: Self.enabledKey)
  }

  /// Stops both agents and keeps them from coming back at login. Deletes nothing.
  func turnOff() async throws {
    for label in [paths.label, paths.mtplxLabel] {
      if await job(label) != nil {
        let result = await launchctl(["bootout", target(label)])
        guard result.succeeded else {
          throw ServerModeError.failed("launchctl bootout failed: \(result.reason)")
        }
        await waitUntilGone(label)
      }
      _ = await launchctl(["disable", target(label)])
    }
    defaults.set(false, forKey: Self.enabledKey)
  }

  /// After an app update: new helpers for a server this app installed. An adopted one is left alone.
  func resyncIfUpdated() async {
    let loaded = await job(paths.label) != nil
    guard ownership(loaded: loaded) == .managed, helpersPresent,
      defaults.string(forKey: Self.helpersStampKey) != helpersStamp
    else { return }
    if loaded {
      _ = await launchctl(["bootout", target(paths.label)])
      await waitUntilGone(paths.label)
    }
    try? syncHelpers()
    if loaded { _ = await launchctl(["bootstrap", domain, paths.plist.path]) }
  }

  /// Runs only after the owner confirmed the size. The worker's model locks need flowd stopped,
  /// and flowd comes back whatever the result.
  func downloadModels() async throws {
    let worker = paths.binDir.appending(path: "flowd-speech").path
    guard files.isExecutableFile(atPath: worker) else { throw ServerModeError.helpersMissing }
    let loaded = await job(paths.label) != nil
    if loaded {
      _ = await launchctl(["bootout", target(paths.label)])
      await waitUntilGone(paths.label)
    }
    let result = await runner.run(
      worker, ["provision", "--models", paths.dataDir.appending(path: "Models").path, "--meeting"])
    if loaded { _ = await launchctl(["bootstrap", domain, paths.plist.path]) }
    guard result.succeeded else {
      throw ServerModeError.failed("A model could not be downloaded or verified. Try again.")
    }
  }

  // MARK: Open to the network

  enum OpenOutcome: Equatable, Sendable {
    case opened
    case rolledBack(String)
    case failed(String)
  }

  /// Changes only `--remote-listen`, keeps the previous plist and restores it unless the server
  /// is healthy within the deadline. An adopted server stays adopted.
  func openToNetwork(deadline: Duration = .seconds(60)) async -> OpenOutcome {
    guard let current = arguments(paths.plist),
      let index = current.firstIndex(of: "--remote-listen"), index + 1 < current.endIndex,
      let port = Self.port(listen: current[index + 1])
    else { return .failed("This server's plist has no --remote-listen to change.") }
    let wasManaged = ownership(loaded: true) == .managed
    let previousPID = await job(paths.label)?.pid
    let backup = backups.appending(path: "\(paths.label).plist")
    var changed = current
    changed[index + 1] = "0.0.0.0:\(port)"
    do {
      try files.createDirectory(at: backups, withIntermediateDirectories: true)
      try? files.removeItem(at: backup)
      try files.copyItem(at: paths.plist, to: backup)
      try Self.writeArguments(changed, to: paths.plist)
    } catch {
      let reason = error.localizedDescription
      return .failed("Could not write \(paths.plist.lastPathComponent): \(reason)")
    }
    if let failure = await reload() {
      await restore(backup: backup)
      return .rolledBack(failure)
    }
    let clock = ContinuousClock()
    let end = clock.now + deadline
    var healthyChecks = 0
    while clock.now < end {
      try? await Task.sleep(for: pollInterval)
      let job = await job(paths.label)
      let healthy: Bool
      if let job, job.running, job.pid != previousPID {
        healthy = await probe(healthURL(port: port)) != nil
      } else {
        healthy = false
      }
      healthyChecks = healthy ? healthyChecks + 1 : 0
      if healthyChecks >= 2 {
        if wasManaged, let data = try? Data(contentsOf: paths.plist) {
          defaults.set(Self.hash(data), forKey: Self.plistHashKey)
        }
        return .opened
      }
    }
    await restore(backup: backup)
    return .rolledBack("The server did not report healthy within \(deadline.components.seconds) s.")
  }

  private func restore(backup: URL) async {
    _ = try? files.replaceItemAt(paths.plist, withItemAt: backup, backupItemName: nil)
    _ = await reload()
  }

  /// bootout, wait for the job to go, bootstrap from the plist. nil on success.
  private func reload() async -> String? {
    if await job(paths.label) != nil {
      _ = await launchctl(["bootout", target(paths.label)])
      await waitUntilGone(paths.label)
    }
    let result = await launchctl(["bootstrap", domain, paths.plist.path])
    return result.succeeded ? nil : "launchctl bootstrap failed: \(result.reason)"
  }

  // MARK: Install

  private var helpersPresent: Bool {
    let directory = contents.appending(path: "Helpers")
    return Self.helpers.allSatisfy {
      files.isExecutableFile(atPath: directory.appending(path: $0).path)
    }
      && files.fileExists(atPath: directory.appending(path: Self.resourceBundle).path)
  }

  /// Changes when an update or a rebuild replaces the helpers.
  private var helpersStamp: String {
    ["flowd", "flowd-speech"].map { name -> String in
      let path = contents.appending(path: "Helpers/\(name)").path
      let attributes = try? files.attributesOfItem(atPath: path)
      let size = attributes?[.size] as? Int64 ?? 0
      let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      return "\(name):\(size):\(date)"
    }.joined(separator: ",")
  }

  /// A new install, or a managed one whose plist is rendered again with its own bind.
  private func install(listen: String) async throws {
    guard helpersPresent else { throw ServerModeError.helpersMissing }
    try files.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.dataDir.path)
    try files.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.logDir.path)
    if !files.fileExists(atPath: paths.flowd.path) { try syncHelpers() }
    // flowd refuses to serve without the identity key; `init` refuses a second run.
    if !files.fileExists(atPath: paths.dataDir.appending(path: "flowd-remote.sqlite").path) {
      let result = await admin.run(["init"])
      guard result.succeeded else {
        throw ServerModeError.failed("flowd admin init failed: \(result.reason)")
      }
    }
    let rewriting = try prepareMTPLX()
    try files.createDirectory(
      at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try Self.plistData(
      label: paths.label, arguments: flowdArguments(listen: listen, rewriting: rewriting),
      stdout: paths.logDir.appending(path: "flowd.stdout.log").path,
      stderr: paths.logDir.appending(path: "flowd.stderr.log").path)
    try data.write(to: paths.plist, options: .atomic)
    defaults.set(Self.hash(data), forKey: Self.plistHashKey)
  }

  private func syncHelpers() throws {
    let helpers = contents.appending(path: "Helpers")
    let resources = contents.appending(path: "Resources")
    try files.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
    for name in Self.helpers {
      try copy(helpers.appending(path: name), to: paths.binDir.appending(path: name), mode: 0o755)
    }
    try replaceDirectory(
      helpers.appending(path: Self.resourceBundle),
      with: paths.binDir.appending(path: Self.resourceBundle))
    // The worker reads the pinned descriptors next to itself.
    for name in [
      "parakeet-v3.json", "parakeet-ctc-110m.json", "whisper-large-v3-turbo.json",
      "speaker-diarization-offline.json",
    ] {
      try copy(resources.appending(path: name), to: paths.binDir.appending(path: name), mode: 0o644)
    }
    // The helper and model licences travel with the install (ADR 0019).
    let licenses = resources.appending(path: "WhisperLicenses")
    if files.fileExists(atPath: licenses.path) {
      try replaceDirectory(licenses, with: paths.binDir.appending(path: "WhisperLicenses"))
    }
    defaults.set(helpersStamp, forKey: Self.helpersStampKey)
  }

  private func copy(_ source: URL, to destination: URL, mode: Int) throws {
    let stage = destination.appendingPathExtension("new")
    try? files.removeItem(at: stage)
    try files.copyItem(at: source, to: stage)
    try files.setAttributes([.posixPermissions: mode], ofItemAtPath: stage.path)
    // A running helper keeps its old file; the rename gives the next start the new one.
    guard rename(stage.path, destination.path) == 0 else {
      throw ServerModeError.failed("Could not install \(destination.lastPathComponent).")
    }
  }

  private func replaceDirectory(_ source: URL, with destination: URL) throws {
    try? files.removeItem(at: destination)
    try files.copyItem(at: source, to: destination)
  }

  /// With the app's local AI runtime the server gets its own MTPLX agent, key and wrapper, so
  /// the key never appears in a plist. An MTPLX plist already there is kept. False without one.
  private func prepareMTPLX() throws -> Bool {
    let mtplx = localAI.appending(path: "venv/bin/mtplx")
    guard files.isExecutableFile(atPath: mtplx.path),
      let raw = try? String(contentsOf: localAI.appending(path: "model-path"), encoding: .utf8)
    else { return files.fileExists(atPath: paths.mtplxPlist.path) }
    let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard files.fileExists(atPath: model) else {
      return files.fileExists(atPath: paths.mtplxPlist.path)
    }
    let key = paths.dataDir.appending(path: "mtplx-api-key")
    if !files.fileExists(atPath: key.path) {
      let value = SymmetricKey(size: .bits256).withUnsafeBytes {
        $0.map { String(format: "%02x", $0) }.joined()
      }
      guard
        files.createFile(
          atPath: key.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
      else { throw ServerModeError.failed("Could not write \(key.lastPathComponent).") }
    }
    let wrapper = paths.binDir.appending(path: "localflow-remote-flowd")
    try Data(Self.wrapperScript.utf8).write(to: wrapper, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    if !files.fileExists(atPath: paths.mtplxPlist.path) {
      try files.createDirectory(
        at: paths.mtplxPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try Self.plistData(
        label: paths.mtplxLabel,
        arguments: mtplxArguments(mtplx: mtplx.path, model: model, key: key.path),
        stdout: "/dev/null", stderr: paths.logDir.appending(path: "mtplx.stderr.log").path)
      try data.write(to: paths.mtplxPlist, options: .atomic)
    }
    return true
  }

  private static let wrapperScript = """
    #!/bin/sh
    # Starts flowd with the server MTPLX key from the file named by $1.
    set -eu
    key_file="$1"
    shift
    LOCALFLOW_BACKEND_TOKEN="$(cat "$key_file")"
    [ -n "$LOCALFLOW_BACKEND_TOKEN" ]
    export LOCALFLOW_BACKEND_TOKEN
    exec "$@"

    """

  /// The installer's flags. `--meeting-processor` stays off: flowd-meeting isn't in the app.
  private func flowdArguments(listen: String, rewriting: Bool) -> [String] {
    let bin = paths.binDir
    let key = paths.dataDir.appending(path: "mtplx-api-key").path
    return (rewriting ? [bin.appending(path: "localflow-remote-flowd").path, key] : [])
      + [
        paths.flowd.path, "serve",
        "--listen", "127.0.0.1:\(paths.localPort)",
        "--remote-listen", listen,
        "--data-dir", paths.dataDir.path,
        "--backend", "http://127.0.0.1:\(paths.mtplxPort)/v1", "--model", "localflow",
        "--speech-worker", bin.appending(path: "flowd-speech").path,
        "--meeting-helper", bin.appending(path: "localflow-whisper-engine").path,
        "--log-file", paths.logDir.appending(path: "flowd.log").path,
        "--admin-listen", "127.0.0.1:\(paths.adminPort)",
      ] + (paths.dev ? ["--dev"] : [])
  }

  /// The serving flags and memory caps of the installer's MTPLX agent.
  private func mtplxArguments(mtplx: String, model: String, key: String) -> [String] {
    [
      "/usr/bin/env", "MTPLX_CLEAR_CACHE_AFTER_REQUEST=always", "MTPLX_MLX_CACHE_LIMIT=268435456",
      "MTPLX_SESSION_BANK_MAX_ENTRIES=1", "MTPLX_SESSION_BANK_MAX_BYTES=512M",
      "MTPLX_SESSION_BANK_PER_SESSION_BYTES=512M", "HF_HUB_DISABLE_TELEMETRY=1", "DO_NOT_TRACK=1",
      mtplx, "serve", "--host", "127.0.0.1", "--port", String(paths.mtplxPort), "--model", model,
      "--model-id", "localflow", "--api-key-file", key, "--scheduler-mode", "serial",
      "--batching-preset", "latency", "--ssd-session-cache", "off", "--context-window", "32768",
      "--fan-mode", "default", "--reasoning", "off", "--adaptive-policy", "expected_value",
      "--no-stats-footer", "--unsafe-force-unverified", "--yes",
    ]
  }

  private static func plistData(label: String, arguments: [String], stdout: String, stderr: String)
    throws -> Data
  {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": label, "ProgramArguments": arguments, "KeepAlive": true, "RunAtLoad": true,
        "LimitLoadToSessionType": "Aqua", "ProcessType": "Standard", "StandardOutPath": stdout,
        "StandardErrorPath": stderr, "ThrottleInterval": 30,
      ] as [String: Any], format: .xml, options: 0)
  }

  /// Rewrites only `ProgramArguments`, keeping every other key.
  private static func writeArguments(_ arguments: [String], to url: URL) throws {
    guard
      var plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as? [String: Any]
    else { throw CocoaError(.propertyListReadCorrupt) }
    plist["ProgramArguments"] = arguments
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url, options: .atomic)
  }

  // MARK: launchctl

  private var domain: String { "gui/\(uid)" }
  private func target(_ label: String) -> String { "\(domain)/\(label)" }

  private func launchctl(_ arguments: [String]) async -> ServerProcessResult {
    await runner.run("/bin/launchctl", arguments)
  }

  private func job(_ label: String) async -> ServerAgentJob? {
    let result = await launchctl(["print", target(label)])
    return result.succeeded ? ServerAgentJob.parse(result.output) : nil
  }

  /// bootstrap fails with error 5 while the old job is still being torn down.
  private func waitUntilGone(_ label: String) async {
    for _ in 0..<50 {
      if await job(label) == nil { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  /// MTPLX first, so flowd's backend probe finds it. `disable` from an earlier turn-off also
  /// blocks bootstrap, so `enable` comes first.
  private func start() async throws {
    guard files.fileExists(atPath: paths.plist.path) else { throw ServerModeError.noPlist }
    for (label, plist) in [(paths.mtplxLabel, paths.mtplxPlist), (paths.label, paths.plist)]
    where files.fileExists(atPath: plist.path) {
      _ = await launchctl(["enable", target(label)])
      if await job(label) == nil {
        let result = await launchctl(["bootstrap", domain, plist.path])
        guard result.succeeded else {
          throw ServerModeError.failed("launchctl bootstrap failed: \(result.reason)")
        }
      }
    }
  }

  // MARK: Helpers

  private func arguments(_ url: URL) -> [String]? {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return plist["ProgramArguments"] as? [String]
  }

  private func healthURL(port: Int) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func port(listen: String) -> Int? {
    listen.split(separator: ":").last.flatMap { Int($0) }
  }

  nonisolated static func isLoopback(listen: String) -> Bool {
    listen.hasPrefix("127.") || listen.hasPrefix("[::1]") || listen.hasPrefix("localhost")
  }
}

extension [String] {
  fileprivate func value(after flag: String) -> String? {
    guard let i = firstIndex(of: flag), index(after: i) < endIndex else { return nil }
    return self[index(after: i)]
  }
}

/// What this Mac can be reached at, by FR-012a's rule (`serverAddressKind`).
enum ServerAddresses {
  /// Pure, for the table test: Tailscale first, then LAN, and only what `origin` accepts.
  static func list(ips: [String], port: Int) -> [ServerAddress] {
    var seen = Set<String>()
    let found = ips.compactMap { ip -> (ServerAddressKind, ServerAddress)? in
      guard let kind = RemoteDictationSettings.serverAddressKind(ip: ip), seen.insert(ip).inserted
      else { return nil }
      let host = ip.contains(":") ? "[\(ip)]" : ip
      guard let origin = RemoteDictationSettings.origin("http://\(host):\(port)")?.absoluteString
      else { return nil }
      let title = kind == .tailscale ? "Tailscale" : "Local network"
      return (kind, ServerAddress(title: "\(title): \(origin)", origin: origin))
    }
    return found.filter { $0.0 == .tailscale }.map(\.1) + found.filter { $0.0 == .lan }.map(\.1)
  }

  /// The numeric addresses of interfaces that are up, without loopback.
  static func interfaceIPs() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var ips: [String] = []
    var cursor = head
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
        let address = current.pointee.ifa_addr,
        address.pointee.sa_family == sa_family_t(AF_INET)
          || address.pointee.sa_family == sa_family_t(AF_INET6)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      ips.append(String(cString: host).components(separatedBy: "%")[0])
    }
    return ips
  }
}
