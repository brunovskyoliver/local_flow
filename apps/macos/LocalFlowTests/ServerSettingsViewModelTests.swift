import XCTest

@testable import LocalFlow

/// Feature 018 T040/T041: Settings › Server, where services run and the connection check.
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
    XCTAssertEqual(
      model.placement,
      "On your server: Dictation, Rewriting, Summaries · Not offered by this server: Meetings")
    XCTAssertTrue(model.hidesRewriteServerFields)
    XCTAssertTrue(model.hidesSummaryServerFields)
    model.useForEverything = false
    // Feature 014 unchanged: dictation and rewriting still use the server.
    XCTAssertEqual(
      places(model), ["On your server", "On your server", "On this Mac", "On this Mac"])
    XCTAssertEqual(
      model.placement, "On your server: Dictation, Rewriting · On this Mac: Summaries, Meetings")
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

  func testACustomSummariesServerShowsAsCustom() {
    approve()
    preferences.summaryServer = .remote
    preferences.summaryServerURL = "http://ai-vm:8000/v1"
    preferences.summaryServerModel = "qwen"
    preferences.serverSummariesOverride = .custom
    let model = model()
    XCTAssertEqual(model.place(.summaries), "On your custom server")
    // The fields move to Server › Advanced while the switch is on (contracts/settings-ui.md).
    XCTAssertTrue(model.hidesSummaryServerFields)
    XCTAssertTrue(model.showsSummaryCustomFields)
  }

  /// T056: Server › Advanced moves one service at a time; Custom shows its fields there.
  func testAdvancedOverrides() {
    approve()
    let model = model()
    XCTAssertEqual(model.rewriteOverride, .server)
    XCTAssertFalse(model.showsRewriteCustomFields)
    model.rewriteOverride = .thisMac
    XCTAssertEqual(preferences.serverRewriteOverride, .thisMac)
    XCTAssertEqual(model.place(.rewriting), "On this Mac")
    XCTAssertEqual(model.place(.summaries), "On your server")
    XCTAssertFalse(model.localRewriteModelStopped)
    model.rewriteOverride = .custom
    XCTAssertTrue(model.showsRewriteCustomFields)
    XCTAssertEqual(model.place(.rewriting), "On your custom server")
    XCTAssertTrue(model.hidesRewriteServerFields, "the fields live in Advanced")
    model.summariesOverride = .custom
    XCTAssertEqual(preferences.summaryServer, .remote, "Custom names the summaries server")
    XCTAssertTrue(model.showsSummaryCustomFields)
    XCTAssertEqual(model.place(.summaries), "On this Mac", "no address yet")
    preferences.serverCapabilities = RemoteCapabilities(
      ops: ["dictation_start", "rewrite", "analysis", "meeting_job"],
      meetingJobs: ["transcribe", "diarize", "embed"], models: nil)
    XCTAssertEqual(model.place(.meetings), "On your server")
    model.meetingsOverride = .thisMac
    XCTAssertEqual(preferences.serverMeetingsOverride, .thisMac)
    XCTAssertEqual(model.place(.meetings), "On this Mac")
    XCTAssertFalse(preferences.serverRouting.servedByServer(.diarization))
    model.fallbackThresholdMs = 2_000
    XCTAssertEqual(preferences.remoteFallbackThresholdMs, 2_000)
    model.useForEverything = false
    XCTAssertFalse(model.showsRewriteCustomFields)
    XCTAssertFalse(model.showsSummaryCustomFields)
    XCTAssertFalse(model.hidesRewriteServerFields, "switch off: the sections are as before")
  }

  func testEverythingInOnePlaceReadsAsOnePhrase() {
    XCTAssertEqual(model().placement, "Everything on this Mac")
    approve(
      ops: ["dictation_start", "rewrite", "analysis", "live_window", "meeting_job"])
    preferences.serverCapabilities = RemoteCapabilities(
      ops: ["dictation_start", "rewrite", "analysis", "live_window", "meeting_job"],
      meetingJobs: ["transcribe", "diarize", "embed"], models: nil)
    XCTAssertEqual(model().placement, "Everything on your server")
  }

  func testTheCheckTimesOneRoundTripForServedServices() async {
    approve()
    let model = model()
    await model.check()
    XCTAssertEqual(pings, 1)
    XCTAssertEqual(model.checkResult, "Answered in 42 ms")
    model.useForEverything = false
    XCTAssertNil(model.checkResult, "a routing change clears the old answer")
  }

  func testAServerThatIsDownReportsTheFallback() async {
    approve()
    answer = nil
    let model = model()
    await model.check()
    XCTAssertEqual(model.checkResult, "Server unreachable")
  }

  func testNothingServedSendsNothing() async {
    let model = model()
    await model.check()
    XCTAssertEqual(pings, 0)
    XCTAssertEqual(model.checkResult, "Nothing runs on your server")
  }
}
