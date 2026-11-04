import XCTest

final class ServerStatusTests: XCTestCase {
  private let launchctlPrint = """
    gui/501/org.localflow.LocalFlow.remote = {
    \tactive count = 1
    \tstate = running
    \tprogram = /Users/test/bin/localflow-remote-flowd
    \tpid = 13148
    \tlast exit code = (never exited)
    \tendpoints = {
    \t\tstate = active
    \t}
    }
    """

  private let health = HealthResponse(
    backend: .init(state: "ready", model: "localflow"), server: .init(version: "0.3.0"))

  func testAdminStatusWithChannelsStillDecodes() throws {
    let json = """
      {"version":"0.4.0","started_at":"2026-11-03T08:00:00Z","counters":{"dictation":{"requests":4,"failures":0}},"analysis":{"backend":"","model":""},"channels":{"open":5,"devices":[{"device_id":3,"channels":2}]}}
      """
    let status = try JSONDecoder().decode(AdminStatus.self, from: Data(json.utf8))
    XCTAssertEqual(status.version, "0.4.0")
  }

  func testLaunchctlPrint() {
    XCTAssertEqual(LaunchJob.parse(launchctlPrint), LaunchJob(running: true, pid: 13148))
    XCTAssertEqual(
      LaunchJob.parse("x = {\n\tstate = not running\n\tlast exit code = 1\n}"),
      LaunchJob(running: false, pid: nil))
  }

  func testHealthDecodesFlowdResponse() throws {
    let json = """
      {"schema_version":1,"service":"localflow-rewrite","protocol_versions":[1,2],"server":{"name":"flowd","version":"0.3.0"},"modes":["clean"],"backend":{"state":"ready","kind":"openai-compatible","model":"localflow"},"prompt_versions":{"clean":6},"shield_version":2}
      """
    XCTAssertEqual(try JSONDecoder().decode(HealthResponse.self, from: Data(json.utf8)), health)
  }

  func testAllReady() {
    let snapshot = ServerSnapshot(
      flowd: .init(running: true, pid: 1), mtplx: .init(running: true, pid: 2),
      rewriteHealth: health,
      workers: WorkerStates(speech: "ready", meeting: "ready"), omlxUp: false)
    XCTAssertEqual(snapshot.statuses.map(\.health), [.ready, .ready, .ready, .ready, .down])
    // oMLX is down but unused, so it does not count.
    XCTAssertEqual(ServerSnapshot.overall(snapshot.statuses), .ready)
  }

  func testOMLXCountsWhenItServesSummaries() {
    var snapshot = ServerSnapshot(
      flowd: .init(running: true, pid: 1), mtplx: .init(running: true, pid: 2),
      rewriteHealth: health,
      workers: WorkerStates(speech: "ready", meeting: "ready"), omlxUp: false)
    snapshot.analysisBackend = "http://127.0.0.1:8443/v1"
    XCTAssertEqual(ServerSnapshot.overall(snapshot.statuses), .down)
  }

  func testStartingUp() {
    var loading = health
    loading.backend.state = "loading"
    let snapshot = ServerSnapshot(
      flowd: .init(running: true, pid: 1), mtplx: .init(running: true, pid: 2),
      rewriteHealth: loading,
      workers: WorkerStates(speech: "starting", meeting: nil), omlxUp: true)
    XCTAssertEqual(snapshot.statuses.map(\.health), [.ready, .loading, .loading, .loading, .ready])
    XCTAssertEqual(ServerSnapshot.overall(snapshot.statuses), .loading)
  }

  func testFlowdDown() {
    let snapshot = ServerSnapshot(
      flowd: nil, mtplx: .init(running: true, pid: 2), rewriteHealth: nil,
      workers: WorkerStates(speech: "ready", meeting: "ready"), omlxUp: true)
    let statuses = snapshot.statuses
    XCTAssertEqual(statuses[0].detail, "agent not loaded")
    // Worker states from the log are stale once flowd is gone.
    XCTAssertEqual(statuses.map(\.health), [.down, .down, .down, .loading, .ready])
    XCTAssertEqual(ServerSnapshot.overall(statuses), .down)
  }

  func testWorkerUnavailableIsDown() {
    let snapshot = ServerSnapshot(
      flowd: .init(running: true, pid: 1), mtplx: .init(running: true, pid: 2),
      rewriteHealth: health,
      workers: WorkerStates(speech: "ready", meeting: "unavailable"), omlxUp: true)
    XCTAssertEqual(snapshot.statuses[2].health, .down)
    XCTAssertEqual(snapshot.statuses[2].detail, "unavailable")
  }

  func testValueAfterFlag() {
    let arguments = ["flowd", "serve", "--model", "localflow", "--analysis-backend"]
    XCTAssertEqual(arguments.value(after: "--model"), "localflow")
    XCTAssertNil(arguments.value(after: "--analysis-backend"))
    XCTAssertNil(arguments.value(after: "--listen"))
  }
}

/// LocalFlow's Turn Off boots both agents out and disables them; launchd modelled, nothing started.
final class LaunchctlRestartTests: XCTestCase {
  final class FakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    var loaded: Set<String> = []
    var disabled: Set<String> = []
    private(set) var verbs: [String] = []

    func run(_ path: String, _ arguments: [String]) -> ProcessResult {
      lock.withLock {
        verbs.append(arguments[0])
        let label = URL(fileURLWithPath: arguments.last ?? "").lastPathComponent
          .replacingOccurrences(of: ".plist", with: "")
        let ok = ProcessResult(status: 0, output: "\tstate = running\n", error: "")
        switch arguments[0] {
        case "print":
          return loaded.contains(label) ? ok : ProcessResult(status: 113, output: "", error: "")
        case "enable":
          disabled.remove(label)
          return ok
        case "bootstrap":
          // launchd's real answer on a disabled label.
          guard !disabled.contains(label) else {
            return ProcessResult(
              status: 5, output: "", error: "Bootstrap failed: 5: Input/output error")
          }
          loaded.insert(label)
          return ok
        case "kickstart": return ok
        default: return ok
        }
      }
    }
  }

  func testRestartStartsAServerThatTurnOffDisabled() async {
    let fake = FakeLaunchd()
    fake.disabled = [Server.label, Server.mtplxLabel]
    let plist = URL(fileURLWithPath: "/tmp/\(Server.label).plist")
    let failure = await Launchctl.restart(Server.label, plist: plist) { fake.run($0, $1) }
    XCTAssertNil(failure)
    XCTAssertTrue(fake.loaded.contains(Server.label))
    XCTAssertFalse(fake.verbs.contains("kickstart"))
  }

  func testRestartKickstartsALoadedServerAndEnablesNothing() async {
    let fake = FakeLaunchd()
    fake.loaded = [Server.label]
    let plist = URL(fileURLWithPath: "/tmp/\(Server.label).plist")
    let failure = await Launchctl.restart(Server.label, plist: plist) { fake.run($0, $1) }
    XCTAssertNil(failure)
    XCTAssertEqual(fake.verbs, ["print", "kickstart"])
  }

  func testReloadEnablesBeforeBootstrap() async {
    let fake = FakeLaunchd()
    fake.disabled = ["agent"]
    let failure = await Launchctl.reload("agent", plist: URL(fileURLWithPath: "/tmp/agent.plist")) {
      fake.run($0, $1)
    }
    XCTAssertNil(failure)
    XCTAssertEqual(fake.verbs, ["print", "enable", "bootstrap"])
  }
}
