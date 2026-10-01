import XCTest

@testable import LocalFlow

/// Feature 018 T040/T041: Settings › Server, its rows and the connection check.
@MainActor
final class ServerSettingsViewModelTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var preferences: AppPreferences!
  private var pings = 0
  private var answer: Duration? = .milliseconds(42)

  override func setUp() async throws {
    suite = "LocalFlow-server-settings-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    preferences = AppPreferences(defaults: defaults)
    pings = 0
  }

  override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

  private func model() -> ServerSettingsModel {
    ServerSettingsModel(
      remote: RemoteDictationModel(preferences: preferences, enrollment: { nil }, turnOff: {}),
      preferences: preferences,
      ping: { [self] in
        pings += 1
        return answer
      })
  }

  private func approve(
    _ state: RemoteDictationState = .approved,
    ops: Set<String> = ["dictation_start", "rewrite", "analysis"]
  ) {
    preferences.setRemoteServerURL("https://mini.example.com")
    preferences.confirmRemoteConsent()
    preferences.remoteEnabled = true
    preferences.remoteState = state
    preferences.serverCapabilities = RemoteCapabilities(ops: ops, meetingJobs: [], models: nil)
  }

  private func places(_ model: ServerSettingsModel) -> [String] {
    ServerSettingsModel.Row.allCases.map(model.place)
  }

  func testOffAndUnapprovedStatesRunEverythingOnThisMac() {
    let model = model()
    XCTAssertFalse(model.approved)
    XCTAssertEqual(Set(places(model)), ["On this Mac"])
    for state in [RemoteDictationState.pending, .rejected, .revoked, .pinMismatch] {
      approve(state)
      XCTAssertFalse(model.approved, state.rawValue)
      XCTAssertEqual(Set(places(model)), ["On this Mac"], state.rawValue)
      XCTAssertFalse(model.hidesRewriteServerFields)
      XCTAssertFalse(model.hidesSummaryServerFields)
    }
  }

  func testApprovedRowsAndTheSwitch() {
    approve()
    let model = model()
    XCTAssertTrue(model.approved)
    XCTAssertTrue(model.useForEverything, "on by default once approved")
    XCTAssertEqual(
      places(model),
      ["On your server", "On your server", "On your server", "Not offered by this server"])
    XCTAssertEqual(model.accessibilityLabel(.rewriting), "Rewriting, on your server")
    XCTAssertTrue(model.hidesRewriteServerFields)
    XCTAssertTrue(model.hidesSummaryServerFields)
    model.useForEverything = false
    // Feature 014 unchanged: dictation and rewriting still use the server.
    XCTAssertEqual(
      places(model), ["On your server", "On your server", "On this Mac", "On this Mac"])
    XCTAssertFalse(model.hidesRewriteServerFields)
    XCTAssertFalse(model.hidesSummaryServerFields)
  }

  /// T048: Settings › Models shows where each model's work runs.
  func testModelsShowWhereTheyRun() {
    let model = model()
    XCTAssertNil(model.modelPlace(.dictation))
    approve()
    XCTAssertEqual(model.modelPlace(.dictation), "On this Mac (used if the server is unreachable)")
    XCTAssertEqual(model.modelPlace(.finalTranscript), "On this Mac", "not offered yet")
    XCTAssertTrue(model.dictationServed)
    XCTAssertTrue(model.localRewriteModelStopped)
    preferences.serverRewriteOverride = .thisMac
    XCTAssertFalse(model.localRewriteModelStopped)
  }

  func testAKeptCustomSummariesServerShowsAsCustom() {
    approve()
    preferences.summaryServer = .remote
    preferences.summaryServerURL = "http://ai-vm:8000/v1"
    preferences.summaryServerModel = "qwen"
    preferences.serverSummariesOverride = .custom
    let model = model()
    XCTAssertEqual(model.place(.summaries), "On your custom server")
    XCTAssertFalse(model.hidesSummaryServerFields)
  }

  func testTheMigrationNoticeShowsOnce() {
    preferences.serverMigrationNotice = [
      "Kept your summaries server ai-vm as a custom server for Summaries."
    ]
    let first = model()
    first.takeNotice()
    XCTAssertEqual(first.notice.count, 1)
    XCTAssertEqual(preferences.serverMigrationNotice, [])
    let second = model()
    second.takeNotice()
    XCTAssertEqual(second.notice, [])
  }

  func testTheCheckTimesOneRoundTripForServedServices() async {
    approve()
    let model = model()
    await model.check()
    XCTAssertEqual(pings, 1)
    XCTAssertEqual(model.checkResults[.dictation], "Answered in 42 ms")
    XCTAssertEqual(model.checkResults[.summaries], "Answered in 42 ms")
    XCTAssertEqual(model.checkResults[.meetings], "Not offered by this server")
  }

  func testAServerThatIsDownReportsTheFallback() async {
    approve()
    answer = nil
    let model = model()
    await model.check()
    XCTAssertEqual(model.checkResults[.rewriting], "Server unreachable · uses this Mac")
    XCTAssertEqual(model.checkResults[.summaries], "Server unreachable · waits for your server")
  }

  func testNothingServedSendsNothing() async {
    let model = model()
    await model.check()
    XCTAssertEqual(pings, 0)
    XCTAssertEqual(model.checkResults[.rewriting], "On this Mac")
  }
}
