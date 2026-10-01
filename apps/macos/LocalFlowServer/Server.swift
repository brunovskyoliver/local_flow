import Foundation

/// Where the production server lives, as scripts/install-remote-server.sh installs it.
/// `LOCALFLOW_SERVER_HOME` replaces the home directory, so the app can be run against
/// copied logs and plists on a development Mac.
enum Server {
  static let label = "org.localflow.LocalFlow.remote"
  static let mtplxLabel = label + ".mtplx"
  static let localHTTP = URL(string: "http://127.0.0.1:8091")!
  static let omlx = URL(string: "http://127.0.0.1:8443")!

  static let home: URL =
    ProcessInfo.processInfo.environment["LOCALFLOW_SERVER_HOME"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser

  static let dataDir = home.appending(path: "Library/Application Support/LocalFlow Server")
  static let flowd = dataDir.appending(path: "bin/flowd")
  static let logDir = home.appending(path: "Library/Logs/LocalFlow Server")
  static let log = logDir.appending(path: "flowd.log")
  static let rotatedLog = logDir.appending(path: "flowd.log.1")
  static let plist = home.appending(path: "Library/LaunchAgents/\(label).plist")
  static let mtplxPlist = home.appending(path: "Library/LaunchAgents/\(mtplxLabel).plist")
  static let omlxSettings = home.appending(path: ".omlx/settings.json")
  /// The app's own state (stats history, plist backups); never the server's data directory.
  static let appSupport = home.appending(
    path: "Library/Application Support/org.localflow.LocalFlow.server")

  static var domain: String { "gui/\(getuid())" }
}

/// A finished child process. Output is decoded as UTF-8.
struct ProcessResult: Sendable {
  var status: Int32
  var output: String
  var error: String
  var succeeded: Bool { status == 0 }
}

/// Runs an executable by absolute path, never through a shell, off the main actor.
func runProcess(_ path: String, _ arguments: [String]) async -> ProcessResult {
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
      return ProcessResult(status: -1, output: "", error: "could not start \(path)")
    }
    // Read before waiting so a full pipe cannot block the child.
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let error = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
      status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
      error: String(decoding: error, as: UTF8.self))
  }.value
}

/// What `launchctl print gui/<uid>/<label>` says about one agent.
struct LaunchJob: Equatable, Sendable {
  var running: Bool
  var pid: Int32?

  /// Parses the top-level `state = …` and `pid = …` lines; nested blocks are indented
  /// deeper and ignored.
  static func parse(_ text: String) -> LaunchJob {
    var job = LaunchJob(running: false, pid: nil)
    for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
      guard parts.count == 2 else { continue }
      switch parts[0] {
      case "state": job.running = parts[1] == "running"
      case "pid": job.pid = Int32(parts[1])
      default: break
      }
    }
    return job
  }
}

enum Launchctl {
  /// nil when the agent is not loaded.
  static func job(_ label: String) async -> LaunchJob? {
    let result = await runProcess("/bin/launchctl", ["print", "\(Server.domain)/\(label)"])
    return result.succeeded ? LaunchJob.parse(result.output) : nil
  }

  static func kickstart(_ label: String) async -> ProcessResult {
    await runProcess("/bin/launchctl", ["kickstart", "-k", "\(Server.domain)/\(label)"])
  }
}

/// A launch agent plist's `ProgramArguments`, as the installer rendered them.
enum AgentPlist {
  static func arguments(_ url: URL) -> [String]? {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return plist["ProgramArguments"] as? [String]
  }
}

extension [String] {
  /// The value after `flag`, e.g. `--model` in `… --model localflow …`.
  func value(after flag: String) -> String? {
    guard let i = firstIndex(of: flag), index(after: i) < endIndex else { return nil }
    return self[index(after: i)]
  }
}
