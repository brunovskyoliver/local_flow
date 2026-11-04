import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Server mode with a fake launchd and a temp home: no real agent, port, key or data (T026, T029).
@MainActor
final class ServerModeControllerTests: XCTestCase {
  /// launchd as far as these tests need: loaded labels, and a new PID per start.
  final class FakeLaunchd: ServerProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String> = []
    private var nextPID: Int32 = 100
    private var recorded: [(path: String, arguments: [String])] = []
    /// `flowd admin` and `flowd-speech` answers; launchctl is modelled.
    var other: @Sendable (String, [String]) -> ServerProcessResult = { _, _ in
      ServerProcessResult(status: 0, output: "", error: "")
    }

    var calls: [(path: String, arguments: [String])] { lock.withLock { recorded } }
    func load(_ label: String) { lock.withLock { _ = loaded.insert(label) } }
    func isLoaded(_ label: String) -> Bool { lock.withLock { loaded.contains(label) } }

    func run(_ path: String, _ arguments: [String]) async -> ServerProcessResult {
      lock.withLock { recorded.append((path, arguments)) }
      guard path == "/bin/launchctl" else { return other(path, arguments) }
      return lock.withLock {
        let label = arguments.last?.components(separatedBy: "/").last ?? ""
        switch arguments[0] {
        case "print":
          guard loaded.contains(label) else {
            return ServerProcessResult(status: 113, output: "", error: "not found")
          }
          return ServerProcessResult(
            status: 0, output: "\tstate = running\n\tpid = \(nextPID)\n\t\tpid = 1\n", error: "")
        case "bootout": loaded.remove(label)
        case "bootstrap":
          let plist = arguments[2]
          loaded.insert(URL(fileURLWithPath: plist).deletingPathExtension().lastPathComponent)
          nextPID += 1
        default: break
        }
        return ServerProcessResult(status: 0, output: "", error: "")
      }
    }
  }

  private var home: URL!
  private var contents: URL!
  private var suite = ""
  private var defaults: UserDefaults!
  private var launchd: FakeLaunchd!
  private let files = FileManager.default

  override func setUp() async throws {
    home = files.temporaryDirectory.appending(path: "server-mode-\(UUID())")
    contents = home.appending(path: "App/Contents")
    let helpers = contents.appending(path: "Helpers")
    let resources = contents.appending(path: "Resources")
    try files.createDirectory(at: helpers, withIntermediateDirectories: true)
    try files.createDirectory(at: resources, withIntermediateDirectories: true)
    for name in ["flowd", "flowd-speech", "flowd-meeting", "localflow-whisper-engine"] {
      files.createFile(
        atPath: helpers.appending(path: name).path, contents: Data(name.utf8),
        attributes: [.posixPermissions: 0o755])
    }
    try files.createDirectory(
      at: helpers.appending(path: "FluidAudio_FluidAudio.bundle/Contents"),
      withIntermediateDirectories: true)
    let descriptor = #"{"files":[{"path":"model.bin","size":1000}]}"#
    for name in [
      "parakeet-v3", "parakeet-ctc-110m", "whisper-large-v3-turbo", "speaker-diarization-offline",
    ] {
      try Data(descriptor.utf8).write(to: resources.appending(path: name + ".json"))
    }
    suite = "LocalFlow-server-mode-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    launchd = FakeLaunchd()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
    try? files.removeItem(at: home)
  }

  private func identity(dev: Bool) -> AppIdentity {
    AppIdentity(infoDictionary: ["LocalFlowVariant": dev ? "dev" : "production"], home: home)
  }

  private func controller(
    dev: Bool = true,
    healthy: @escaping @Sendable () -> Bool = { true }
  ) -> ServerModeController {
    ServerModeController(
      identity: identity(dev: dev), defaults: defaults, runner: launchd, contents: contents,
      uid: 501,
      pollInterval: .milliseconds(1),
      probe: { _ in healthy() ? .init(fingerprint: "aaaa-bbbb") : nil })
  }

  private func plistArguments(_ url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    let plist =
      try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    return plist["ProgramArguments"] as! [String]
  }

  /// A plist as the install script writes it, with a sign-in flag the app doesn't know about.
  private func writeScriptInstalledPlist(_ paths: ServerModePaths) throws -> Data {
    try files.createDirectory(
      at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": paths.label, "KeepAlive": true,
        "ProgramArguments": [
          "/script/flowd", "serve", "--remote-listen", "127.0.0.1:\(paths.remotePort)",
          "--google-client-id", "abc.apps.googleusercontent.com",
        ],
      ] as [String: Any], format: .xml, options: 0)
    try data.write(to: paths.plist)
    return data
  }

  private var launchctlRuns: [[String]] {
    launchd.calls.filter { $0.path == "/bin/launchctl" }.map(\.arguments)
  }
  private var changes: [[String]] { launchctlRuns.filter { $0[0] != "print" } }

  // MARK: Labels, ports and paths

  func testExactLabelsPortsAndDirectories() {
    let production = ServerModePaths(identity: identity(dev: false))
    XCTAssertEqual(production.label, "org.localflow.LocalFlow.remote")
    XCTAssertEqual(production.mtplxLabel, "org.localflow.LocalFlow.remote.mtplx")
    XCTAssertEqual(
      [production.remotePort, production.localPort, production.mtplxPort, production.adminPort],
      [8090, 8091, 8092, 8093])
    XCTAssertEqual(
      production.dataDir.path, home.path + "/Library/Application Support/LocalFlow Server")
    XCTAssertEqual(production.logDir.path, home.path + "/Library/Logs/LocalFlow Server")
    let dev = ServerModePaths(identity: identity(dev: true))
    XCTAssertEqual(dev.label, "org.localflow.LocalFlow.dev.remote")
    XCTAssertEqual(dev.mtplxLabel, "org.localflow.LocalFlow.dev.remote.mtplx")
    XCTAssertEqual(
      [dev.remotePort, dev.localPort, dev.mtplxPort, dev.adminPort], [18090, 18091, 18092, 18093])
    XCTAssertEqual(
      dev.dataDir.path, home.path + "/Library/Application Support/LocalFlow Server Dev")
  }

  // MARK: A new install

  func testNewInstallOpensToAllNetworksWithDevIsolation() async throws {
    let server = controller()
    try await server.turnOn()
    let paths = server.paths
    let arguments = try plistArguments(paths.plist)
    XCTAssertEqual(arguments[0], paths.flowd.path)
    XCTAssertEqual(arguments.value(after: "--remote-listen"), "0.0.0.0:18090")
    XCTAssertEqual(arguments.value(after: "--listen"), "127.0.0.1:18091")
    XCTAssertEqual(arguments.value(after: "--admin-listen"), "127.0.0.1:18093")
    XCTAssertEqual(arguments.value(after: "--backend"), "http://127.0.0.1:18092/v1")
    XCTAssertTrue(arguments.contains("--dev"))
    XCTAssertEqual(
      arguments.value(after: "--meeting-processor"),
      paths.binDir.appending(path: "flowd-meeting").path)
    XCTAssertEqual(server.ownership(loaded: true), .managed)
    // Private data directory, helpers installed, one init with the dev flag.
    let mode = try files.attributesOfItem(atPath: paths.dataDir.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)
    for name in ["flowd", "flowd-speech", "flowd-meeting", "localflow-whisper-engine"] {
      XCTAssertTrue(files.isExecutableFile(atPath: paths.binDir.appending(path: name).path), name)
    }
    XCTAssertTrue(
      files.fileExists(atPath: paths.binDir.appending(path: "FluidAudio_FluidAudio.bundle").path))
    XCTAssertTrue(files.fileExists(atPath: paths.binDir.appending(path: "parakeet-v3.json").path))
    XCTAssertEqual(
      launchd.calls.filter { $0.path == paths.flowd.path }.map(\.arguments),
      [["admin", "--data-dir", paths.dataDir.path, "--dev", "init"]])
    XCTAssertEqual(
      changes,
      [
        ["enable", "gui/501/org.localflow.LocalFlow.dev.remote"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testAFailedInitLoadsNothing() async {
    launchd.other = { _, _ in ServerProcessResult(status: 1, output: "", error: "locked\n") }
    let server = controller()
    do {
      try await server.turnOn()
      XCTFail("expected a failure")
    } catch {
      XCTAssertEqual(error as? ServerModeError, .failed("flowd admin init failed: locked"))
    }
    XCTAssertFalse(launchctlRuns.contains { $0[0] == "bootstrap" })
    XCTAssertFalse(files.fileExists(atPath: server.paths.plist.path))
  }

  func testWithoutTheHelpersNothingIsInstalled() async throws {
    try files.removeItem(at: contents.appending(path: "Helpers/flowd-speech"))
    let server = controller()
    do {
      try await server.turnOn()
      XCTFail("expected a failure")
    } catch { XCTAssertEqual(error as? ServerModeError, .helpersMissing) }
    XCTAssertTrue(changes.isEmpty)
    let status = await server.status()
    XCTAssertTrue(status.missing.contains(ServerModeError.helpersMissing.errorDescription!))
  }

  func testWithoutFlowdMeetingNothingIsInstalled() async throws {
    try files.removeItem(at: contents.appending(path: "Helpers/flowd-meeting"))
    let server = controller()
    do {
      try await server.turnOn()
      XCTFail("expected a failure")
    } catch { XCTAssertEqual(error as? ServerModeError, .helpersMissing) }
    XCTAssertTrue(changes.isEmpty)
  }

  func testMeetingHandoffNeedsAnExecutableProcessorInBin() async throws {
    let server = controller()
    try await server.turnOn()
    let processor = server.paths.binDir.appending(path: "flowd-meeting")
    try files.removeItem(at: processor)
    try await server.turnOff()
    try await server.turnOn()
    XCTAssertFalse(try plistArguments(server.paths.plist).contains("--meeting-processor"))
    var status = await server.status()
    XCTAssertTrue(status.missing.contains { $0.hasSuffix("this server has no flowd-meeting.") })
    // Copied in by an update, but the plist predates it.
    files.createFile(
      atPath: processor.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    status = await server.status()
    XCTAssertTrue(status.missing.contains { $0.hasSuffix("turn server mode off and on.") })
    try await server.turnOff()
    try await server.turnOn()
    XCTAssertEqual(
      try plistArguments(server.paths.plist).value(after: "--meeting-processor"), processor.path)
    status = await server.status()
    XCTAssertFalse(status.missing.contains { $0.hasPrefix("Meetings sent from a phone") })
  }

  func testWithoutLocalAIRewritingIsListedAsUnavailable() async throws {
    let server = controller()
    try await server.turnOn()
    XCTAssertFalse(files.fileExists(atPath: server.paths.mtplxPlist.path))
    XCTAssertEqual(try plistArguments(server.paths.plist)[1], "serve")
    let status = await server.status()
    XCTAssertTrue(status.missing.contains { $0.hasPrefix("Rewriting and summaries") })
    XCTAssertTrue(status.missing.contains { $0.hasPrefix("Dictation") })
    XCTAssertFalse(status.missing.contains { $0.hasPrefix("Meetings sent from a phone") })
    XCTAssertEqual(status.missingModelBytes, 3000)
    XCTAssertEqual(status.fingerprint, "aaaa-bbbb")
  }

  func testWithLocalAITheKeyStaysOutOfThePlist() async throws {
    let local = home.appending(path: "Library/Application Support/LocalFlow Dev/LocalAI")
    let mtplx = local.appending(path: "venv/bin/mtplx")
    let model = home.appending(path: "model")
    try files.createDirectory(
      at: mtplx.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.createDirectory(at: model, withIntermediateDirectories: true)
    files.createFile(atPath: mtplx.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    try Data(model.path.utf8).write(to: local.appending(path: "model-path"))
    let server = controller()
    try await server.turnOn()
    let paths = server.paths
    let keyFile = paths.dataDir.appending(path: "mtplx-api-key")
    let key = try String(contentsOf: keyFile, encoding: .utf8)
    XCTAssertEqual(key.count, 64)
    XCTAssertEqual(
      try files.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int, 0o600)
    let flowd = try plistArguments(paths.plist)
    XCTAssertEqual(
      Array(flowd.prefix(3)),
      [paths.binDir.appending(path: "localflow-remote-flowd").path, keyFile.path, paths.flowd.path])
    let agent = try plistArguments(paths.mtplxPlist)
    XCTAssertEqual(agent.value(after: "--port"), "18092")
    XCTAssertEqual(agent.value(after: "--model"), model.path)
    for plist in [paths.plist, paths.mtplxPlist] {
      XCTAssertFalse(try String(contentsOf: plist, encoding: .utf8).contains(key))
    }
    // MTPLX first, so flowd's backend probe finds it.
    XCTAssertEqual(
      changes.filter { $0[0] == "bootstrap" }.map { $0[2] },
      [paths.mtplxPlist.path, paths.plist.path])
  }

  // MARK: Adoption

  func testAnExistingPlistIsAdoptedNeverRewrittenOrResynced() async throws {
    let server = controller(dev: false)
    let original = try writeScriptInstalledPlist(server.paths)
    try files.createDirectory(at: server.paths.binDir, withIntermediateDirectories: true)
    let oldFlowd = Data("old flowd".utf8)
    try oldFlowd.write(to: server.paths.flowd)
    XCTAssertEqual(server.ownership(loaded: false), .adopted)
    try await server.turnOn()
    await server.resyncIfUpdated()
    XCTAssertEqual(try Data(contentsOf: server.paths.plist), original)
    XCTAssertEqual(try Data(contentsOf: server.paths.flowd), oldFlowd)
    XCTAssertFalse(
      files.fileExists(atPath: server.paths.binDir.appending(path: "flowd-speech").path))
    XCTAssertFalse(launchd.calls.contains { $0.path == server.paths.flowd.path }, "no init")
    XCTAssertEqual(
      try plistArguments(server.paths.plist).value(after: "--google-client-id"),
      "abc.apps.googleusercontent.com")
    XCTAssertNil(defaults.string(forKey: ServerModeController.plistHashKey))
    XCTAssertEqual(
      changes,
      [
        ["enable", "gui/501/org.localflow.LocalFlow.remote"],
        ["bootstrap", "gui/501", server.paths.plist.path],
      ])
  }

  func testALoadedAgentIsLeftRunningAsItIs() async throws {
    let server = controller(dev: false)
    let original = try writeScriptInstalledPlist(server.paths)
    launchd.load(server.paths.label)
    try await server.turnOn()
    XCTAssertTrue(changes.isEmpty)
    XCTAssertEqual(try Data(contentsOf: server.paths.plist), original)
  }

  func testALoadedAgentWithNoPlistIsAdopted() {
    XCTAssertEqual(controller().ownership(loaded: true), .adopted)
    XCTAssertEqual(controller().ownership(loaded: false), .none)
  }

  func testAPlistChangedBehindTheAppIsAdoptedAgain() async throws {
    let server = controller()
    try await server.turnOn()
    XCTAssertEqual(server.ownership(loaded: true), .managed)
    _ = try writeScriptInstalledPlist(server.paths)
    XCTAssertEqual(server.ownership(loaded: true), .adopted)
    await server.resyncIfUpdated()
    XCTAssertEqual(try plistArguments(server.paths.plist)[0], "/script/flowd")
  }

  func testResyncReplacesHelpersOnlyAfterAnUpdateOfAManagedServer() async throws {
    let server = controller()
    try await server.turnOn()
    let before = launchd.calls.count
    await server.resyncIfUpdated()
    XCTAssertEqual(
      launchd.calls.dropFirst(before).filter { $0.arguments[0] != "print" }.count, 0,
      "nothing changed, nothing restarted")
    try Data("new flowd, longer".utf8).write(to: contents.appending(path: "Helpers/flowd"))
    await server.resyncIfUpdated()
    XCTAssertEqual(try Data(contentsOf: server.paths.flowd), Data("new flowd, longer".utf8))
    XCTAssertEqual(
      changes.suffix(2),
      [
        ["bootout", "gui/501/org.localflow.LocalFlow.dev.remote"],
        ["bootstrap", "gui/501", server.paths.plist.path],
      ])
    XCTAssertTrue(launchd.isLoaded(server.paths.label))
  }

  // MARK: Open to the network

  func testOpenChangesOnlyTheListenAddressAndAdoptedStaysAdopted() async throws {
    let server = controller(dev: false)
    let original = try writeScriptInstalledPlist(server.paths)
    launchd.load(server.paths.label)
    let before = try plistArguments(server.paths.plist)
    let outcome = await server.openToNetwork(deadline: .seconds(5))
    XCTAssertEqual(outcome, .opened)
    var expected = before
    expected[3] = "0.0.0.0:8090"
    XCTAssertEqual(try plistArguments(server.paths.plist), expected)
    let plist =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: server.paths.plist), format: nil) as! [String: Any]
    XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    XCTAssertEqual(server.ownership(loaded: true), .adopted)
    let backup = home.appending(
      path: "Library/Application Support/LocalFlow/ServerMode/org.localflow.LocalFlow.remote.plist")
    XCTAssertEqual(try Data(contentsOf: backup), original, "the previous plist is kept")
  }

  func testOpenRestoresThePreviousPlistWhenNotHealthy() async throws {
    let server = controller(dev: false, healthy: { false })
    let original = try writeScriptInstalledPlist(server.paths)
    launchd.load(server.paths.label)
    let outcome = await server.openToNetwork(deadline: .milliseconds(30))
    guard case .rolledBack = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(try Data(contentsOf: server.paths.plist), original)
    XCTAssertTrue(launchd.isLoaded(server.paths.label), "the old configuration runs again")
    XCTAssertEqual(changes.filter { $0[0] == "bootstrap" }.count, 2)
  }

  func testAnOpenInterruptedByQuittingIsUndoneAtLaunch() async throws {
    let server = controller(dev: false)
    let original = try writeScriptInstalledPlist(server.paths)
    launchd.load(server.paths.label)
    let outcome = await server.openToNetwork(deadline: .seconds(5))
    XCTAssertEqual(outcome, .opened)
    await server.recoverInterruptedOpen()
    XCTAssertNotEqual(try Data(contentsOf: server.paths.plist), original, "a finished open stands")

    defaults.set(true, forKey: ServerModeController.openPendingKey)
    await server.recoverInterruptedOpen()
    XCTAssertEqual(try Data(contentsOf: server.paths.plist), original)
    XCTAssertTrue(launchd.isLoaded(server.paths.label))
    XCTAssertFalse(defaults.bool(forKey: ServerModeController.openPendingKey))
  }

  func testOpenOfAManagedServerStaysManaged() async throws {
    let server = controller()
    try await server.turnOn()
    // A managed plist rendered with a loopback bind, as an earlier open's rollback leaves it.
    let outcome = await server.openToNetwork(deadline: .seconds(5))
    XCTAssertEqual(outcome, .opened)
    XCTAssertEqual(server.ownership(loaded: true), .managed)
  }

  func testOpenWithoutAListenFlagChangesNothing() async throws {
    let server = controller(dev: false)
    let outcome = await server.openToNetwork(deadline: .seconds(1))
    XCTAssertEqual(outcome, .failed("This server's plist has no --remote-listen to change."))
    XCTAssertTrue(changes.isEmpty)
  }

  // MARK: Off (T029)

  func testOffStopsTheAgentAndDeletesNothing() async throws {
    let server = controller()
    let database = server.paths.dataDir.appending(path: "flowd-remote.sqlite")
    launchd.other = { [database] _, arguments in
      if arguments.last == "init" {
        FileManager.default.createFile(atPath: database.path, contents: Data())
      }
      return ServerProcessResult(status: 0, output: "", error: "")
    }
    try await server.turnOn()
    let paths = server.paths
    let listed = { [files] in
      (try? files.subpathsOfDirectory(atPath: paths.dataDir.path).sorted()) ?? []
    }
    let before = listed()
    try await server.turnOff()
    XCTAssertFalse(launchd.isLoaded(paths.label))
    XCTAssertEqual(listed(), before)
    XCTAssertTrue(files.fileExists(atPath: paths.plist.path))
    // `disable` keeps launchd from loading the plist again at login.
    XCTAssertTrue(changes.contains(["disable", "gui/501/org.localflow.LocalFlow.dev.remote"]))
    let plist = try Data(contentsOf: paths.plist)
    try await server.turnOn()
    XCTAssertEqual(try Data(contentsOf: paths.plist), plist)
    XCTAssertEqual(
      changes.suffix(2).first, ["enable", "gui/501/org.localflow.LocalFlow.dev.remote"])
    XCTAssertEqual(
      launchd.calls.filter { $0.arguments.contains("init") }.count, 1,
      "the identity is created once"
    )
  }

  func testOnAndOffLeaveLocalDictationPreferencesUnchanged() async throws {
    let preferences = AppPreferences(defaults: defaults, identity: identity(dev: true))
    preferences.remoteFallbackThresholdMs = 2_000
    preferences.keepModelReady = true
    let before = defaults.persistentDomain(forName: suite) ?? [:]
    let settings = preferences.serverRouting.remote
    let server = controller()
    try await server.turnOn()
    try await server.turnOff()
    let after = (defaults.persistentDomain(forName: suite) ?? [:])
      .filter { !$0.key.hasPrefix("serverMode.") }
    XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: before))
    XCTAssertEqual(preferences.serverRouting.remote, settings)
  }

  func testADevelopmentBuildNeverAddressesAProductionAgent() async throws {
    let server = controller()
    try await server.turnOn()
    _ = await server.status()
    _ = await server.openToNetwork(deadline: .seconds(1))
    try await server.downloadModels()
    await server.resyncIfUpdated()
    try await server.turnOff()
    let production = "org.localflow.LocalFlow.remote"
    for call in launchd.calls {
      XCTAssertFalse(call.arguments.joined(separator: " ").contains(production), "\(call)")
      XCTAssertFalse(
        call.arguments.contains("--data-dir") && !call.arguments.contains("--dev"), "\(call)")
      for argument in call.arguments {
        XCTAssertFalse(argument.contains("/LocalFlow Server/"), argument)
      }
    }
    for port in ["8090", "8091", "8092", "8093", "8080"] {
      XCTAssertFalse(
        try plistArguments(server.paths.plist).contains { $0.hasSuffix(":\(port)") }, port)
    }
  }

  // MARK: Models

  func testModelDownloadStopsFlowdRunsProvisionAndStartsIt() async throws {
    let server = controller()
    try await server.turnOn()
    try await server.downloadModels()
    let paths = server.paths
    let provision = launchd.calls.first { $0.arguments.first == "provision" }
    XCTAssertEqual(provision?.path, paths.binDir.appending(path: "flowd-speech").path)
    XCTAssertEqual(
      provision?.arguments,
      ["provision", "--models", paths.dataDir.appending(path: "Models").path, "--meeting"])
    XCTAssertTrue(launchd.isLoaded(paths.label))
  }

  func testNothingDownloadsWithoutAskingOnTurnOn() async throws {
    let server = controller()
    try await server.turnOn()
    XCTAssertFalse(launchd.calls.contains { $0.arguments.first == "provision" })
  }

  func testAFailedDownloadStillStartsTheServer() async throws {
    let server = controller()
    try await server.turnOn()
    launchd.other = { _, arguments in
      ServerProcessResult(status: arguments.first == "provision" ? 1 : 0, output: "", error: "")
    }
    do {
      try await server.downloadModels()
      XCTFail("expected a failure")
    } catch {}
    XCTAssertTrue(launchd.isLoaded(server.paths.label))
  }

  func testInstalledModelsAreNotListed() async throws {
    let server = controller()
    try await server.turnOn()
    for root in [
      "parakeet-v3", "whisper-large-v3-turbo", "speaker-diarization-offline/speaker-diarization",
    ] {
      let directory = server.paths.dataDir.appending(path: "Models/\(root)")
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(count: 1000).write(to: directory.appending(path: "model.bin"))
    }
    let status = await server.status()
    XCTAssertEqual(status.missingModelBytes, 0)
    XCTAssertFalse(status.missing.contains { $0.hasPrefix("Dictation") })
  }

  // MARK: Addresses (T027)

  func testAddressTable() {
    let list = ServerAddresses.list(
      ips: [
        "127.0.0.1", "::1", "192.168.1.20", "100.100.1.2", "169.254.3.4", "fe80::1", "8.8.8.8",
        "fd7a:115c:a1e0::2", "192.168.1.20", "fd00::9",
      ], port: 8090)
    XCTAssertEqual(
      list.map(\.title),
      [
        "Tailscale: http://100.100.1.2:8090", "Tailscale: http://[fd7a:115c:a1e0::2]:8090",
        "Local network: http://192.168.1.20:8090", "Local network: http://[fd00::9]:8090",
      ])
    XCTAssertEqual(list[0].origin, "http://100.100.1.2:8090")
  }

  func testAddressesFollowTheBindAndTheCustomAddressIsValidated() {
    let server = controller()
    XCTAssertEqual(
      server.addresses(listen: "0.0.0.0:18090", interfaces: ["10.0.0.2"]).map(\.origin),
      ["http://10.0.0.2:18090"])
    XCTAssertTrue(
      server.addresses(listen: "127.0.0.1:18090", interfaces: ["10.0.0.2"]).isEmpty,
      "a loopback bind isn't reachable on the machine's addresses")
    XCTAssertEqual(
      server.addresses(listen: "10.0.0.7:18090", interfaces: ["10.0.0.2"]).map(\.origin),
      ["http://10.0.0.7:18090"], "a bind to one address lists only that one")
    XCTAssertFalse(server.setCustomAddress("http://example.com"), "public http is refused")
    XCTAssertFalse(server.setCustomAddress("https://example.com/path"))
    XCTAssertEqual(server.customAddress, "")
    XCTAssertTrue(server.setCustomAddress("https://mini.example.com"))
    XCTAssertEqual(
      server.addresses(listen: "127.0.0.1:18090", interfaces: []).map(\.origin),
      ["https://mini.example.com"])
    XCTAssertTrue(server.setCustomAddress(""))
    XCTAssertEqual(server.customAddress, "")
  }

  func testRealInterfacesAreReadWithoutLoopback() {
    XCTAssertFalse(ServerAddresses.interfaceIPs().contains("127.0.0.1"))
  }

  // MARK: The view's model (T028)

  func testTurningOnNeedsConfirmationAndNamesTheRightAction() async throws {
    let server = controller(dev: false)
    let model = ServerModeModel(controller: server, interfaces: { [] })
    await model.refresh()
    model.requestToggle(true)
    XCTAssertEqual(model.confirm, .turnOn)
    XCTAssertTrue(changes.isEmpty, "nothing starts before the owner confirms")
    _ = try writeScriptInstalledPlist(server.paths)
    await model.refresh()
    model.requestToggle(true)
    XCTAssertEqual(model.confirm, .turnOnExisting)
    await model.perform(.turnOnExisting)
    XCTAssertTrue(model.isOn)
    XCTAssertTrue(model.status.canOpenToNetwork)
    XCTAssertFalse(model.status.missing.isEmpty)
    model.requestToggle(false)
    XCTAssertEqual(model.confirm, .turnOff)
  }

  func testNoClientYetIsReportedFromTheAdminList() async throws {
    let server = controller()
    try await server.turnOn()
    launchd.other = { _, arguments in
      ServerProcessResult(
        status: 0,
        output: arguments.last == "list"
          ? "user 1 token Ada approved created 2026-10-31 10:00\n  device 1 x approved enrolled 2026-10-31 10:01  last seen never\n"
          : "", error: "")
    }
    var status = await server.status()
    XCTAssertFalse(status.clientConnected)
    launchd.other = { _, _ in
      ServerProcessResult(
        status: 0,
        output: "  device 1 x approved enrolled 2026-10-31 10:01  last seen 2026-10-31 11:00\n",
        error: "")
    }
    status = await server.status()
    XCTAssertTrue(status.clientConnected)
  }

  func testTheTokensSheetDropsItsModelOnClose() async throws {
    let model = ServerModeModel(controller: controller(), interfaces: { ["10.0.0.2"] })
    model.showTokens()
    XCTAssertNotNil(model.tokens)
    model.tokens = nil
    XCTAssertNil(model.tokens)
  }
}

extension [String] {
  fileprivate func value(after flag: String) -> String? {
    guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
    return self[i + 1]
  }
}
