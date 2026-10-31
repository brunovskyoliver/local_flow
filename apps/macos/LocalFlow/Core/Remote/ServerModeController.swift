import Foundation

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
