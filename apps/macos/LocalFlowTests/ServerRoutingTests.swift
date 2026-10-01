import XCTest

@testable import LocalFlow

/// Feature 018 T021: the `servedByServer` truth table and the path per service.
final class ServerRoutingTests: XCTestCase {
  private static let everything = RemoteCapabilities(
    ops: ["dictation_start", "rewrite", "analysis", "live_window", "meeting_job"],
    meetingJobs: ["transcribe", "diarize", "embed"], models: nil)

  private func approved(_ state: RemoteDictationState = .approved) -> RemoteDictationSettings {
    RemoteDictationSettings(
      enabled: true, serverOrigin: URL(string: "https://mini.example.com"), state: state)
  }

  private func routing(
    state: RemoteDictationState = .approved, on: Bool = true,
    capabilities: RemoteCapabilities = ServerRoutingTests.everything, consent: Bool = true
  ) -> ServerRouting {
    ServerRouting(
      remote: approved(state), useForEverything: on, capabilities: capabilities,
      consentCurrent: consent)
  }

  func testEveryServiceIsServedWithTheSwitchOnAndEverythingOffered() {
    let routing = routing()
    for service in ServerService.allCases {
      XCTAssertTrue(routing.servedByServer(service), "\(service)")
      XCTAssertEqual(routing.path(for: service), .server, "\(service)")
    }
    XCTAssertTrue(routing.localRewriteModelUnneeded)
  }

  func testTheSwitchOffLeavesDictationAndRewritingOnFeature014Paths() {
    let routing = routing(on: false)
    XCTAssertTrue(routing.servedByServer(.dictation))
    for service in ServerService.allCases where service != .dictation {
      XCTAssertFalse(routing.servedByServer(service), "\(service)")
    }
    XCTAssertTrue(routing.rewritesOverChannel)
    XCTAssertEqual(routing.path(for: .rewrite), .server)
    XCTAssertEqual(routing.path(for: .summaries), .thisMac)
    XCTAssertEqual(routing.path(for: .finalTranscript), .thisMac)
    XCTAssertFalse(routing.localRewriteModelUnneeded)
  }

  func testAnyStateButApprovedServesNothing() {
    for state in [RemoteDictationState.off, .pinned, .pending, .rejected, .revoked, .pinMismatch] {
      let routing = routing(state: state)
      for service in ServerService.allCases {
        XCTAssertFalse(routing.servedByServer(service), "\(state) \(service)")
        XCTAssertNotEqual(routing.path(for: service), .server, "\(state) \(service)")
      }
      XCTAssertFalse(routing.rewritesOverChannel)
    }
  }

  func testAMissingCapabilityDropsOnlyThatService() {
    let cases: [(String?, String?, ServerService)] = [
      ("rewrite", nil, .rewrite), ("analysis", nil, .summaries), ("live_window", nil, .livePreview),
      (nil, "transcribe", .finalTranscript), (nil, "diarize", .diarization),
      (nil, "embed", .voiceRegions),
    ]
    for (op, kind, dropped) in cases {
      var capabilities = Self.everything
      capabilities.notOffered(op: op ?? "meeting_job", kind: kind)
      let routing = routing(capabilities: capabilities)
      for service in ServerService.allCases {
        XCTAssertEqual(routing.servedByServer(service), service != dropped, "\(dropped) \(service)")
      }
    }
    // A Feature 014 server: dictation and rewriting only.
    let old = routing(capabilities: .feature014)
    XCTAssertEqual(
      ServerService.allCases.filter(old.servedByServer), [.dictation, .rewrite])
  }

  func testOverridesMoveOneServiceAndItsPath() {
    var routing = routing()
    routing.rewrite = .custom
    routing.customRewrite = true
    XCTAssertFalse(routing.servedByServer(.rewrite))
    XCTAssertFalse(routing.rewritesOverChannel)
    XCTAssertEqual(routing.path(for: .rewrite), .custom)
    XCTAssertTrue(routing.servedByServer(.summaries))

    routing = self.routing()
    routing.rewrite = .thisMac
    XCTAssertEqual(routing.path(for: .rewrite), .thisMac)
    XCTAssertFalse(routing.localRewriteModelUnneeded)

    routing = self.routing()
    routing.summaries = .custom
    routing.customSummaries = true
    XCTAssertEqual(routing.path(for: .summaries), .custom)
    XCTAssertTrue(routing.servedByServer(.rewrite))
    XCTAssertFalse(routing.localRewriteModelUnneeded)

    routing = self.routing()
    routing.meetings = .thisMac
    for service in ServerService.allCases {
      XCTAssertEqual(routing.servedByServer(service), !service.isMeetingWork, "\(service)")
    }
  }

  /// FR-033: a device enrolled under the first consent text keeps dictation and
  /// rewriting on the server, but not summaries or meetings.
  func testAnOldConsentKeepsSummariesAndMeetingsOnThisMac() {
    let routing = routing(consent: false)
    for service in ServerService.allCases {
      XCTAssertEqual(
        routing.servedByServer(service), service == .dictation || service == .rewrite,
        "\(service)")
    }
  }

  /// T036: with the switch on, rewrites use the channel whenever the server serves them,
  /// whatever `rewriteEndpoint` says; with it off, Feature 014 is unchanged. The origin
  /// is what the rewrite attempt records (FR-007).
  func testRewritesFollowTheSwitch() {
    let origin = URL(string: "https://mini.example.com")
    var routing = routing()
    routing.customRewrite = true
    XCTAssertEqual(routing.rewriteChannelOrigin, origin)
    routing.rewrite = .custom
    XCTAssertNil(routing.rewriteChannelOrigin)
    XCTAssertEqual(routing.path(for: .rewrite), .custom)
    routing.rewrite = .thisMac
    routing.customRewrite = false
    XCTAssertNil(routing.rewriteChannelOrigin)
    XCTAssertEqual(routing.path(for: .rewrite), .thisMac)
    routing.useForEverything = false
    XCTAssertEqual(routing.rewriteChannelOrigin, origin, "Feature 014")
    XCTAssertNil(self.routing(state: .pending).rewriteChannelOrigin)
  }

  /// T054 (US4): with the switch on, This Mac means loopback flowd and its model and
  /// Custom the stored rewrite address; with the switch off the stored address stays.
  func testRewriteOverridesPickTheirEndpoint() {
    let stored = "https://rewrite.example.com"
    var routing = routing()
    XCTAssertEqual(routing.rewriteEndpoint(stored), stored, "served over the channel")
    routing.rewrite = .thisMac
    XCTAssertEqual(routing.rewriteEndpoint(stored), LocalAIInstaller.rewriteEndpoint)
    XCTAssertTrue(routing.localRewriteModelWanted(rewriteEndpoint: stored))
    XCTAssertTrue(routing.servedByServer(.summaries), "other services stay on the server")
    routing.rewrite = .custom
    routing.customRewrite = true
    XCTAssertEqual(routing.rewriteEndpoint(stored), stored)
    XCTAssertFalse(routing.localRewriteModelWanted(rewriteEndpoint: stored))
    routing.useForEverything = false
    routing.rewrite = .thisMac
    XCTAssertEqual(routing.rewriteEndpoint(stored), stored, "switch off: Feature 014")
  }

  /// T052 (US4, R9): This Mac and Custom summaries and what each needs locally.
  func testSummaryOverridesAndTheLocalModel() {
    let loopback = LocalAIInstaller.rewriteEndpoint
    var routing = routing()
    XCTAssertFalse(routing.localRewriteModelWanted(rewriteEndpoint: loopback))
    routing.summaries = .thisMac
    XCTAssertEqual(routing.path(for: .summaries), .thisMac)
    XCTAssertTrue(
      routing.localRewriteModelWanted(rewriteEndpoint: "https://x.example.com"),
      "summaries on this Mac need the local model")
    routing.summaries = .custom
    XCTAssertEqual(routing.path(for: .summaries), .thisMac, "an incomplete custom server")
    routing.customSummaries = true
    XCTAssertEqual(routing.path(for: .summaries), .custom)
    XCTAssertTrue(routing.summariesFallBackToServer)
    XCTAssertFalse(
      routing.localRewriteModelWanted(rewriteEndpoint: loopback),
      "a custom server is primary-only, then the channel")
    routing.consentCurrent = false
    XCTAssertFalse(routing.summariesFallBackToServer)
    routing.consentCurrent = true
    routing.useForEverything = false
    XCTAssertFalse(routing.summariesFallBackToServer, "switch off: this Mac, as before")
    XCTAssertTrue(routing.localRewriteModelWanted(rewriteEndpoint: loopback))
    XCTAssertFalse(routing.localRewriteModelWanted(rewriteEndpoint: "https://x.example.com"))
  }

  @MainActor func testPreferencesFeedTheSnapshot() {
    let suite = "LocalFlow-routing-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertFalse(preferences.serverRouting.servedByServer(.dictation))
    preferences.setRemoteServerURL("https://mini.example.com")
    preferences.confirmRemoteConsent()
    preferences.remoteEnabled = true
    preferences.remoteState = .approved
    preferences.serverCapabilities = Self.everything
    XCTAssertTrue(preferences.serverRouting.servedByServer(.summaries))
    preferences.useServerForEverything = false
    XCTAssertFalse(preferences.serverRouting.servedByServer(.summaries))
    XCTAssertTrue(preferences.serverRouting.rewritesOverChannel)
  }
}
