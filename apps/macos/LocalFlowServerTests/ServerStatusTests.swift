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
