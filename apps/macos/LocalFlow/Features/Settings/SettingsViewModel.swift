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
  }
  struct Snapshot {
    var modelInstalled = false
    var keepModelReady = false
    var meetingModelInstalled = false
    var meetingModelInstalling = false
    var meetingModelReadiness: String {
      if meetingModelInstalling { return "Installing Whisper Turbo…" }
      return meetingModelInstalled
        ? "Whisper Turbo · Installed and verified"
        : "Whisper Turbo · Download 1.63 GB or import the model folder to finalize meetings."
    }
    var speakerModelInstalled = false
    var speakerModelInstalling = false
    var speakerModelReadiness: String {
      if speakerModelInstalling { return "Installing…" }
      return speakerModelInstalled ? "Installed and verified" : "Not installed"
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
  private func credentialChanged() {
    hideRewriteCredential()
    credentialError = nil
    credentialRevision += 1
    invalidateConnectionTest()
    disableBlockedRewriting()
  }
  private func showCredentialError(_ error: Error) {
    switch error as? RewriteCredentialError {
    case .empty: credentialError = "Enter a credential first."
    case .tooLarge: credentialError = "The credential must be no more than 4,096 bytes."
    case .invalidCharacters: credentialError = "Remove surrounding whitespace and line breaks."
    default: credentialError = "Could not access the credential in Keychain."
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
        analysisStatus = await analysisHealthStatus(endpoint: endpoint)
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
  func refresh() async { snapshot = await observe() }
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
