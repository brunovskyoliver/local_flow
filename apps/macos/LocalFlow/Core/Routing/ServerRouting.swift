import Foundation
import Observation

/// The inference services one switch can send to the user's server (Feature 018).
enum ServerService: String, CaseIterable, Sendable {
  case dictation, rewrite, summaries, livePreview, finalTranscript, diarization, voiceRegions

  var isMeetingWork: Bool {
    switch self {
    case .livePreview, .finalTranscript, .diarization, .voiceRegions: true
    case .dictation, .rewrite, .summaries: false
    }
  }
}

/// Where a service's requests go.
enum ServerPath: String, Sendable, Equatable {
  case server, thisMac, custom
}

/// Feature 018 derived routing (data-model.md): a snapshot of the switch, the device's
/// enrollment, the server's capabilities and the per-service overrides. Pure, so the
/// whole truth table is testable without a server.
struct ServerRouting: Sendable, Equatable {
  var remote: RemoteDictationSettings
  var useForEverything: Bool
  var rewrite: AppPreferences.ServerOverride = .server
  var summaries: AppPreferences.ServerOverride = .server
  var meetings: AppPreferences.ServerOverride = .server
  var capabilities: RemoteCapabilities = .feature014
  /// FR-033: the consent text that names meeting audio and summaries was confirmed.
  var consentCurrent: Bool
  /// `rewriteEndpoint` points off this Mac.
  var customRewrite = false
  /// Settings › Summaries names a complete Remote server.
  var customSummaries = false

  /// `useForEverything` ∧ `routesToServer` ∧ capability ∧ override == `server`;
  /// dictation depends on `routesToServer` alone, as in Feature 014.
  func servedByServer(_ service: ServerService) -> Bool {
    guard remote.routesToServer else { return false }
    if service == .dictation { return true }
    guard useForEverything, offered(service) else { return false }
    switch service {
    case .dictation: return true
    case .rewrite: return rewrite == .server
    case .summaries: return summaries == .server && consentCurrent
    case .livePreview, .finalTranscript, .diarization, .voiceRegions:
      return meetings == .server && consentCurrent
    }
  }

  func offered(_ service: ServerService) -> Bool {
    switch service {
    case .dictation: capabilities.offers(op: "dictation_start")
    case .rewrite: capabilities.offers(op: "rewrite")
    case .summaries: capabilities.offers(op: "analysis")
    case .livePreview: capabilities.offers(op: "live_window")
    case .finalTranscript: capabilities.offers(meetingJob: "transcribe")
    case .diarization: capabilities.offers(meetingJob: "diarize")
    case .voiceRegions: capabilities.offers(meetingJob: "embed")
    }
  }

  /// The device is approved and the switch is on: the overrides decide every path.
  var switchApplies: Bool { remote.routesToServer && useForEverything }

  /// Rewrites use the channel: always under Feature 014 with the switch off, and with
  /// the switch on whenever the server serves them.
  var rewritesOverChannel: Bool {
    remote.routesToServer && (!useForEverything || servedByServer(.rewrite))
  }

  /// Where rewrites go over the channel; the attempt records it as its origin (FR-007).
  /// Nil keeps the HTTP route.
  var rewriteChannelOrigin: URL? { rewritesOverChannel ? remote.serverOrigin : nil }

  /// The path a request for `service` takes now.
  func path(for service: ServerService) -> ServerPath {
    if servedByServer(service) { return .server }
    switch service {
    case .rewrite:
      if rewritesOverChannel { return .server }
      if switchApplies, rewrite != .server { return rewrite == .custom ? .custom : .thisMac }
      return customRewrite ? .custom : .thisMac
    case .summaries:
      // With the switch on, only Server › Advanced names a custom server; off, the
      // Summaries section does, as before Feature 018.
      if switchApplies, summaries != .custom { return .thisMac }
      return customSummaries ? .custom : .thisMac
    case .dictation, .livePreview, .finalTranscript, .diarization, .voiceRegions:
      return .thisMac
    }
  }

  /// The address rewrites use over HTTP: loopback flowd for a This Mac override, the
  /// stored `rewriteEndpoint` otherwise (US4).
  func rewriteEndpoint(_ stored: String) -> String {
    switchApplies && rewrite == .thisMac ? LocalAIInstaller.rewriteEndpoint : stored
  }

  /// A custom summaries server that fails before any result retries over the channel
  /// (R9); with the switch off, flowd falls back to this Mac as before.
  var summariesFallBackToServer: Bool {
    switchApplies && consentCurrent && offered(.summaries)
  }

  /// Whether the local rewrite model (MTPLX) should run (R10): with the switch on, when
  /// rewriting or summaries run on this Mac's flowd; off, when rewriting points at it.
  func localRewriteModelWanted(rewriteEndpoint stored: String) -> Bool {
    guard switchApplies else { return stored == LocalAIInstaller.rewriteEndpoint }
    return
      (path(for: .rewrite) == .thisMac
      && rewriteEndpoint(stored) == LocalAIInstaller.rewriteEndpoint)
      || path(for: .summaries) == .thisMac
  }

  /// Rewriting and summaries both run on the server: the local rewrite model can stop (R10).
  var localRewriteModelUnneeded: Bool {
    servedByServer(.rewrite) && servedByServer(.summaries)
  }

  // MARK: Migration (research R13)

  static func migrationNotice(summariesHost host: String) -> String {
    "Kept your summaries server \(host) as a custom server for Summaries."
  }

  static func migrationNotice(rewriteHost host: String) -> String {
    "Kept your rewrite server \(host) as a custom server for Rewriting."
  }

  /// Runs once: a Remote summaries server and an off-Mac rewrite address with a stored
  /// secret become custom overrides. Nothing is deleted, from defaults or Keychain.
  @MainActor
  static func migrate(_ preferences: AppPreferences, credentials: any RewriteCredentialStoring) {
    guard preferences.serverMigrationVersion < AppPreferences.serverMigrationVersion else {
      return
    }
    var notice: [String] = []
    if let host = preferences.customSummariesHost {
      preferences.serverSummariesOverride = .custom
      notice.append(migrationNotice(summariesHost: host))
    }
    if let origin = RewriteSettings.normalizedOrigin(preferences.rewriteEndpoint),
      !RewriteSettings.isLoopbackHost(RewriteSettings.host(of: origin)),
      credentials.exists(origin: origin)
    {
      preferences.serverRewriteOverride = .custom
      notice.append(migrationNotice(rewriteHost: RewriteSettings.host(of: origin)))
    }
    preferences.serverMigrationNotice = notice
    preferences.markServerMigrated()
  }
}

extension AppPreferences {
  /// The routing snapshot. Reading it inside `withObservationTracking` tracks every input.
  var serverRouting: ServerRouting {
    let customRewrite = RewriteSettings.normalizedOrigin(rewriteEndpoint).map {
      !RewriteSettings.isLoopbackHost(RewriteSettings.host(of: $0))
    }
    return ServerRouting(
      remote: remoteSettings(), useForEverything: useServerForEverything,
      rewrite: serverRewriteOverride, summaries: serverSummariesOverride,
      meetings: serverMeetingsOverride, capabilities: serverCapabilities ?? .feature014,
      consentCurrent: remoteConsentCurrent, customRewrite: customRewrite ?? false,
      customSummaries: customSummariesHost != nil)
  }

  /// Records a `ready`'s capabilities; an unchanged offer does not notify observers.
  func noteServerCapabilities(_ offered: RemoteCapabilities) {
    if serverCapabilities != offered { serverCapabilities = offered }
  }

  /// A `not_offered` answer: the capability is gone until the next `ready`.
  func noteNotOffered(op: String, kind: String? = nil) {
    var capabilities = serverCapabilities ?? .feature014
    capabilities.notOffered(op: op, kind: kind)
    noteServerCapabilities(capabilities)
  }

  /// The host of a complete Remote summaries server, or nil.
  var customSummariesHost: String? {
    let url = summaryServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = summaryServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard summaryServer == .remote, !url.isEmpty, !model.isEmpty else { return nil }
    return URL(string: url)?.host() ?? url
  }

  /// Calls `changed` after every change to the routing inputs, until `self` goes away.
  func observeServerRouting(_ changed: @escaping @MainActor () -> Void) {
    withObservationTracking {
      _ = serverRouting
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        changed()
        self.observeServerRouting(changed)
      }
    }
  }
}
