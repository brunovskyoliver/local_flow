import AppKit
import Foundation
import Observation

@MainActor @Observable
final class SettingsViewModel {
  enum Permission: String {
    case unknown = "Not determined"
    case denied = "Not allowed"
    case granted = "Allowed"
  }
  enum Action {
    case download, importModel, cancelInstall, load, unload, showLocation, verifyModel
    case requestMicrophone, requestInputMonitoring, requestAccessibility
    case configureShortcut(ShortcutPreference)
    case setKeepModelReady(Bool)
    case importSpeakerModel, downloadSpeakerModel, verifySpeakerModel
    case importMeetingModel, downloadMeetingModel, verifyMeetingModel
    case testModel(ModelTest)
  }
  /// The three local models Settings can load and run once.
  enum ModelTest: Hashable {
    case speech, meeting, speaker
    var workload: ModelWorkload {
      switch self {
      case .speech: .speechRecognition
      case .meeting: .meetingTranscription
      case .speaker: .diarization
      }
    }
  }
  struct Snapshot: Equatable {
    var modelInstalled = false
    var keepModelReady = false
    var meetingModelInstalled = false
    var meetingModelInstalling = false
    var meetingModelReadiness: String {
      if meetingModelInstalling { return "Installing…" }
      return meetingModelInstalled ? "Ready" : "Not installed · 1.63 GB"
    }
    var speakerModelInstalled = false
    var speakerModelInstalling = false
    var speakerModelReadiness: String {
      if speakerModelInstalling { return "Installing…" }
      return speakerModelInstalled ? "Ready" : "Not installed"
    }
    var modelReadiness: String {
      guard modelInstalled else { return "Not installed" }
      switch runtime.state {
      case .preparing: return "Preparing…"
      case .releasing: return "Unloading…"
      default: return runtime.loaded ? "Ready" : "Unloaded"
      }
    }
    var modelIdentity: String?
    var modelVersion: String?
    var downloadBytes: Int64?
    var installedBytes: Int64?
    var location: URL?
    var modelDetails = "Model metadata unavailable."
    var runtime = ModelLifecycleCoordinator.Snapshot(
      state: .unloaded, loaded: false, leased: false, installing: false)
    var progress = ProvisioningProgress.Snapshot()
    var microphone: Permission = .unknown
    var inputMonitoring: Permission = .unknown
    var accessibility: Permission = .unknown
    var shortcut = ShortcutPreference()
    var shortcutReady = false
    var storageAvailable = false
    /// Why "Enable rewriting" cannot turn on right now, from a fresh snapshot
    /// that ignores `enabled`; nil when the toggle is available.
    var rewriteBlockedReason: String?
    var busy = false
    var installing = false
    var status = "Checking local prerequisites…"
    var hasMissingPermissions: Bool {
      microphone != .granted || inputMonitoring != .granted || accessibility != .granted
    }
    var readyForTest: Bool {
      storageAvailable && modelInstalled && microphone == .granted && inputMonitoring == .granted
        && shortcutReady
        && shortcut.enabled && !busy && !installing && !runtime.leased && runtime.controlsAvailable
    }
  }
  private(set) var snapshot = Snapshot()
  private(set) var performing = false
  private(set) var error: String?
  @ObservationIgnored private let observe: @MainActor () async -> Snapshot
  @ObservationIgnored private let perform: @MainActor (Action) async throws -> Void
  var readyForTest: Bool { snapshot.readyForTest && !performing }
  var modelControlsAvailable: Bool {
    !performing && !snapshot.busy && !snapshot.installing && snapshot.runtime.controlsAvailable
  }

  private let preferences: AppPreferences?
  @ObservationIgnored private let rewriteCredentials: (any RewriteCredentialStoring)?
  @ObservationIgnored private let rewriteTransport: (any RewriteTransporting)?
  @ObservationIgnored private let analysisTransport: (any AnalysisTransporting)?
  private var credentialRevision = 0
  private var connectionRevision = 0
  @ObservationIgnored private var connectionTask: Task<HealthResponse, Error>?
  private(set) var connectionTesting = false
  private(set) var connectionResult: RewriteConnectionTestResult?
  /// The meeting-analysis half of the connection test, run only after the
  /// rewrite health reports `connected`.
  private(set) var analysisStatus: String?
  private(set) var credentialError: String?
  private var summaryKeyRevision = 0
  private(set) var summaryKeyError: String?
  var credentialDraft = ""
  private(set) var credentialRevealed = false

  var rewriteSettings: RewriteSettings? {
    _ = credentialRevision
    guard let preferences, let rewriteCredentials else { return nil }
    return RewriteSettings.capture(preferences: preferences, credentialStore: rewriteCredentials)
  }
  var rewriteBlockedReason: String? {
    rewriteSettings.map(Self.rewriteBlockedReason) ?? snapshot.rewriteBlockedReason
  }
  var credentialPresent: Bool { rewriteSettings?.credentialPresent == true }
  var showsInsecureOverride: Bool { rewriteSettings?.isUnencryptedRemote == true }
  var rewriteWarning: String? {
    guard let settings = rewriteSettings, settings.isUnencryptedRemote, settings.insecureOverride
    else { return nil }
    return
      "Transcripts and the credential travel unencrypted to \(settings.host). Authentication does not encrypt them. Use this only on a network you trust."
  }
  var rewriteEndpoint: String {
    get { preferences?.rewriteEndpoint ?? "" }
    set {
      guard let preferences else { return }
      let oldOrigin = RewriteSettings.normalizedOrigin(preferences.rewriteEndpoint)
      let newOrigin = RewriteSettings.normalizedOrigin(newValue)
      if oldOrigin != newOrigin {
        if let oldOrigin { preferences.setInsecureOverride(false, for: oldOrigin) }
        if let newOrigin { preferences.setInsecureOverride(false, for: newOrigin) }
        hideRewriteCredential()
        credentialError = nil
        credentialRevision += 1
      }
      preferences.rewriteEndpoint = newValue
      invalidateConnectionTest()
      disableBlockedRewriting()
    }
  }
  var rewriteEnabled: Bool {
    get { preferences?.rewriteEnabled == true }
    set { preferences?.rewriteEnabled = newValue && rewriteBlockedReason == nil }
  }
  var rewriteMode: RewriteMode {
    get { preferences?.rewriteDefaultMode ?? .clean }
    set { preferences?.rewriteDefaultMode = newValue }
  }
  var rewriteTimeout: Int {
    get { preferences?.rewriteTimeoutSeconds ?? RewriteSettings.defaultTimeoutSeconds }
    set { preferences?.rewriteTimeoutSeconds = newValue }
  }
  var rewriteInsecureOverride: Bool {
    get { rewriteSettings?.insecureOverride == true }
    set {
      guard let settings = rewriteSettings, settings.isUnencryptedRemote else { return }
      preferences?.setInsecureOverride(newValue, for: settings.endpointOrigin)
      invalidateConnectionTest()
      disableBlockedRewriting()
    }
  }
  var rewriteBypassNote: String {
    snapshot.shortcut.includesShift
      ? "Shift bypass is unavailable because Shift is in your shortcut."
      : "Hold Shift on release to skip rewriting once."
  }

  func setRewriteCredential() {
    guard let settings = rewriteSettings, settings.isEndpointValid, let rewriteCredentials else {
      credentialError = "Enter a valid endpoint before setting a credential."
      return
    }
    do {
      try rewriteCredentials.write(origin: settings.endpointOrigin, secret: credentialDraft)
      credentialChanged()
    } catch { showCredentialError(error) }
  }
  func revealRewriteCredential() {
    guard let settings = rewriteSettings, let rewriteCredentials else { return }
    do {
      credentialDraft = try rewriteCredentials.read(origin: settings.endpointOrigin) ?? ""
      credentialRevealed = true
      credentialError = nil
    } catch { showCredentialError(error) }
  }
  func hideRewriteCredential() {
    credentialDraft = ""
    credentialRevealed = false
  }
  func removeRewriteCredential() {
    guard let settings = rewriteSettings, let rewriteCredentials else { return }
    do {
      try rewriteCredentials.remove(origin: settings.endpointOrigin)
      credentialChanged()
    } catch { showCredentialError(error) }
  }
  var summaryKeySaved: Bool {
    _ = summaryKeyRevision
    return rewriteCredentials?.exists(origin: SummaryServer.credentialAccount) == true
  }
  /// Saves the Remote summary server's API key; false leaves `summaryKeyError` set.
  func saveSummaryKey(_ key: String) -> Bool {
    guard let rewriteCredentials else { return false }
    do {
      try rewriteCredentials.write(origin: SummaryServer.credentialAccount, secret: key)
      summaryKeyError = nil
      summaryKeyRevision += 1
      return true
    } catch {
      summaryKeyError = Self.credentialMessage(error)
      return false
    }
  }
  private func credentialChanged() {
    hideRewriteCredential()
    credentialError = nil
    credentialRevision += 1
    invalidateConnectionTest()
    disableBlockedRewriting()
  }
  private func showCredentialError(_ error: Error) {
    credentialError = Self.credentialMessage(error)
  }
  private static func credentialMessage(_ error: Error) -> String {
    switch error as? RewriteCredentialError {
    case .empty: "Enter a credential first."
    case .tooLarge: "The credential must be no more than 4,096 bytes."
    case .invalidCharacters: "Remove surrounding whitespace and line breaks."
    default: "Could not access the credential in Keychain."
    }
  }
  private func disableBlockedRewriting() {
    if rewriteBlockedReason != nil { preferences?.rewriteEnabled = false }
  }
  private func invalidateConnectionTest() {
    connectionRevision += 1
    connectionTask?.cancel()
    connectionResult = nil
    analysisStatus = nil
  }
  func closeRewriteSettings() {
    hideRewriteCredential()
    invalidateConnectionTest()
  }

  func testConnection() async {
    guard !connectionTesting, let settings = rewriteSettings else { return }
    analysisStatus = nil
    if let category = RewriteConnectionCategory.preflight(settings) {
      connectionResult = .init(category: category, diagnostic: "preflight")
      return
    }
    guard let endpoint = RewriteEndpoint(settings: settings), let rewriteTransport else { return }
    connectionTesting = true
    connectionResult = nil
    let revision = connectionRevision
    let task = Task { try await rewriteTransport.health(endpoint: endpoint) }
    connectionTask = task
    defer {
      connectionTask = nil
      rewriteTransport.invalidate()
      connectionTesting = false
    }
    do {
      let health = try await task.value
      guard revision == connectionRevision, !Task.isCancelled else { return }
      let category = RewriteConnectionCategory.evaluate(health)
      connectionResult = .init(
        category: category, health: health, diagnostic: "health_response")
      if category == .connected {
        let status = await analysisHealthStatus(endpoint: endpoint)
        guard revision == connectionRevision, !Task.isCancelled else { return }
        analysisStatus = status
      }
    } catch {
      guard revision == connectionRevision, !Task.isCancelled else { return }
      let failure = error as? RewriteConnectionFailure
      connectionResult = .init(
        category: failure?.category ?? .serverUnreachable,
        diagnostic: failure?.diagnostic ?? "transport_error")
    }
  }

  /// `GET /v1/analysis/health` on the same endpoint and credential. A 404 or
  /// a wrong service value means the server predates meeting analysis.
  private func analysisHealthStatus(endpoint: RewriteEndpoint) async -> String {
    guard let analysisTransport else { return "Meeting analysis could not be checked." }
    do {
      let health = try await analysisTransport.health(endpoint: endpoint)
      if let model = health.backend?.model, !model.isEmpty {
        return "Meeting analysis: available (model \(model))."
      }
      return "Meeting analysis: available."
    } catch let failure as AnalysisFailure where failure.category == .serverUnavailable {
      return "This server does not offer meeting analysis."
    } catch {
      return "Meeting analysis could not be checked."
    }
  }

  /// Developer-only export: no endpoint, credential, body, or server-supplied identity.
  var rewriteDiagnostics: String {
    guard let result = connectionResult else { return "connection_test=not_run" }
    return "connection_test=\(result.category.rawValue) code=\(result.diagnostic)"
  }

  /// Inline reason the Enable toggle is unavailable, in refusal precedence.
  // MARK: App context (Feature 012)

  static let contextDisclosure =
    "Reads the app name, window title and text around the cursor to spell names as they appear on screen. Never reads passwords, the clipboard or excluded apps."
  static let contextRewriteTitle = "Send context to rewrite server"

  /// Why the context rewrite toggle is unavailable, or nil when it can be turned on (FR-020).
  static func contextRewriteBlockedReason(contextEnabled: Bool, rewriteEnabled: Bool) -> String? {
    if !contextEnabled { return "Turn on Use app context first." }
    if !rewriteEnabled { return "Turn on rewriting first." }
    return nil
  }
  private(set) var contextExclusionError: String?

  func addContextExclusion(_ bundleID: String) {
    guard let preferences else { return }
    contextExclusionError =
      preferences.addContextExclusion(bundleID)
      ? nil
      : "Enter a bundle ID such as com.example.App. At most \(AppPreferences.maximumContextRules) apps can be excluded."
  }

  static let contextStyleTitle = "Match style to the app"

  static func appCount(_ count: Int) -> String { count == 1 ? "1 app" : "\(count) apps" }
  private(set) var contextOverrideError: String?

  func setContextCategory(_ category: AppCategory, for bundleID: String) {
    guard let preferences else { return }
    let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    contextOverrideError =
      preferences.setContextCategory(category, for: id)
      ? nil
      : "Enter a bundle ID such as com.example.App. At most \(AppPreferences.maximumContextRules) apps can have a kind."
  }

  /// Regular running apps, by name.
  var runningApps: [(id: String, name: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Regular running apps that are not excluded yet, by name.
  var contextExclusionCandidates: [(id: String, name: String)] {
    let excluded = Set(preferences?.contextExcludedBundleIDs ?? [])
    return NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app in
        app.bundleIdentifier.flatMap {
          excluded.contains($0) ? nil : ($0, app.localizedName ?? $0)
        }
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func rewriteBlockedReason(for settings: RewriteSettings) -> String? {
    switch settings.refusalCategory {
    case .invalidSettings: return "Enter a valid http:// or https:// endpoint first."
    case .insecureEndpointBlocked:
      return "Allow the unencrypted connection to this server first, or use https://."
    case .missingCredential: return "Set a credential for this server first."
    default: return nil
    }
  }

  static func rewriteModeDefinition(_ mode: RewriteMode) -> String {
    switch mode {
    case .exact: return "Insert the saved transcript unchanged. No request is sent."
    case .clean:
      return
        "Keep wording and meaning; fix punctuation, grammar and capitalization, and remove obvious fillers."
    case .polished:
      return
        "Restructure sentences into natural professional writing while keeping every fact and action."
    case .concise: return "Remove repetition and clutter while keeping every fact and action."
    }
  }

  init(
    observe: @escaping @MainActor () async -> Snapshot,
    perform: @escaping @MainActor (Action) async throws -> Void,
    preferences: AppPreferences? = nil,
    rewriteCredentials: (any RewriteCredentialStoring)? = nil,
    rewriteTransport: (any RewriteTransporting)? = nil,
    analysisTransport: (any AnalysisTransporting)? = nil
  ) {
    self.observe = observe
    self.perform = perform
    self.preferences = preferences
    self.rewriteCredentials = rewriteCredentials
    self.rewriteTransport = rewriteTransport
    self.analysisTransport = analysisTransport
  }
  /// Assigns only on change so an unchanged poll does not invalidate observers.
  func refresh() async {
    let next = await observe()
    if next != snapshot { snapshot = next }
  }
  private(set) var testing: ModelTest?
  /// "Working · 420 ms" or the failure, per model, until the next test.
  private(set) var testResults: [ModelTest: String] = [:]

  func test(_ model: ModelTest) async {
    guard !performing else { return }
    performing = true
    testing = model
    testResults[model] = nil
    error = nil
    let started = ContinuousClock.now
    do {
      try await perform(.testModel(model))
      let elapsed = started.duration(to: .now).components
      let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
      testResults[model] = "Working · \(ms) ms"
    } catch {
      testResults[model] = DictationErrorMessage.describe(error)
    }
    testing = nil
    performing = false
    await refresh()
  }

  func run(_ action: Action) async {
    guard !performing else { return }
    performing = true
    error = nil
    defer { performing = false }
    do { try await perform(action) } catch {
      self.error =
        DictationErrorMessage.describe(error)
    }
    await refresh()
  }
}
