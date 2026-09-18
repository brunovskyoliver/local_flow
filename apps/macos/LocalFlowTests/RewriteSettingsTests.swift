import XCTest

@testable import LocalFlow

/// The `RewriteSettings` snapshot rules from `data-model.md`, "Rewrite settings".
@MainActor
final class RewriteSettingsTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() {
    for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    suites.removeAll()
  }

  private func makePreferences() -> AppPreferences {
    let suite = "LocalFlow-rewrite-settings-\(UUID())"
    suites.append(suite)
    return AppPreferences(defaults: UserDefaults(suiteName: suite)!)
  }

  private func snapshot(
    endpoint: String, enabled: Bool = true, credential: String? = nil, override: Bool = false,
    mode: RewriteMode = .clean, timeout: Int = 20
  ) -> RewriteSettings {
    let preferences = makePreferences()
    preferences.rewriteEnabled = enabled
    preferences.rewriteEndpoint = endpoint
    preferences.rewriteDefaultMode = mode
    preferences.rewriteTimeoutSeconds = timeout
    let store = FakeRewriteCredentialStore()
    if let origin = RewriteSettings.normalizedOrigin(endpoint) {
      if let credential { try? store.write(origin: origin, secret: credential) }
      preferences.setInsecureOverride(override, for: origin)
    }
    return RewriteSettings.capture(preferences: preferences, credentialStore: store)
  }

  func testSnapshotCarriesPresenceOnlyAndNeverTheSecret() {
    let secret = "s3cr3t-token-value-\(UUID().uuidString)"
    let settings = snapshot(endpoint: "https://rewrite.example.net", credential: secret)
    XCTAssertTrue(settings.enabled)
    XCTAssertEqual(settings.mode, .clean)
    XCTAssertEqual(settings.endpointOrigin, "https://rewrite.example.net:443")
    XCTAssertEqual(settings.timeoutSeconds, 20)
    XCTAssertFalse(settings.insecureOverride)
    XCTAssertTrue(settings.credentialPresent)
    for child in Mirror(reflecting: settings).children {
      XCTAssertFalse(String(describing: child.value).contains(secret), child.label ?? "?")
      XCTAssertFalse(String(reflecting: child.value).contains("s3cr3t"), child.label ?? "?")
    }
    XCTAssertFalse(String(describing: settings).contains(secret))
  }

  func testLoopbackDetection() {
    for endpoint in [
      "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:8080",
      "http://127.255.255.255",
      "http://127.0.0.1", "http://[::1]:8080", "https://localhost:8443",
    ] {
      let settings = snapshot(endpoint: endpoint)
      XCTAssertTrue(settings.isLoopback, endpoint)
      XCTAssertFalse(settings.requiresCredential, endpoint)
      XCTAssertFalse(settings.isUnencryptedRemote, endpoint)
      XCTAssertTrue(settings.canSend, endpoint)
      XCTAssertNil(settings.refusalCategory, endpoint)
    }
    for endpoint in [
      "http://192.168.1.20:8080", "http://100.64.0.7:8080", "http://10.0.0.3", "http://128.0.0.1",
      "https://rewrite.example.net", "http://localhost.example.net",
    ] {
      let settings = snapshot(endpoint: endpoint)
      XCTAssertFalse(settings.isLoopback, endpoint)
      XCTAssertTrue(settings.requiresCredential, endpoint)
    }
  }

  func testUnencryptedRemoteNeedsOverrideThenCredential() {
    let blocked = snapshot(endpoint: "http://192.168.1.20:8080", credential: "abc")
    XCTAssertTrue(blocked.isUnencryptedRemote)
    XCTAssertFalse(blocked.canSend)
    XCTAssertEqual(blocked.refusalCategory, .insecureEndpointBlocked)
    let missing = snapshot(endpoint: "http://192.168.1.20:8080", override: true)
    XCTAssertFalse(missing.canSend)
    XCTAssertEqual(missing.refusalCategory, .missingCredential)
    let allowed = snapshot(endpoint: "http://192.168.1.20:8080", credential: "abc", override: true)
    XCTAssertTrue(allowed.canSend)
    XCTAssertNil(allowed.refusalCategory)
    XCTAssertTrue(allowed.insecureOverride)
    let https = snapshot(endpoint: "https://192.168.1.20:8443")
    XCTAssertFalse(https.isUnencryptedRemote)
    XCTAssertEqual(https.refusalCategory, .missingCredential)
  }

  func testInsecureOverrideIsReadOnlyForTheExactOrigin() {
    let preferences = makePreferences()
    preferences.setInsecureOverride(true, for: "http://a:8080")
    XCTAssertTrue(preferences.insecureOverride(for: "http://a:8080"))
    XCTAssertFalse(preferences.insecureOverride(for: "http://b:8080"))
    XCTAssertFalse(preferences.insecureOverride(for: "http://a:8081"))
    XCTAssertFalse(preferences.insecureOverride(for: "https://a:8080"))
    // Writes for origins that never need an override are ignored.
    preferences.setInsecureOverride(true, for: "https://a:8080")
    preferences.setInsecureOverride(true, for: "http://localhost:8080")
    preferences.setInsecureOverride(true, for: "http://127.0.0.1:8080")
    XCTAssertEqual(preferences.rewriteInsecureOverrides, ["http://a:8080": true])
    preferences.setInsecureOverride(false, for: "http://a:8080")
    XCTAssertEqual(preferences.rewriteInsecureOverrides, [:])
    // The store is per origin: a second http origin is still blocked.
    preferences.rewriteEndpoint = "http://a:8080"
    preferences.rewriteEnabled = true
    preferences.setInsecureOverride(true, for: "http://a:8080")
    let store = FakeRewriteCredentialStore()
    try? store.write(origin: "http://a:8080", secret: "x")
    try? store.write(origin: "http://b:8080", secret: "x")
    XCTAssertTrue(RewriteSettings.capture(preferences: preferences, credentialStore: store).canSend)
    preferences.rewriteEndpoint = "http://b:8080"
    let other = RewriteSettings.capture(preferences: preferences, credentialStore: store)
    XCTAssertFalse(other.canSend)
    XCTAssertEqual(other.refusalCategory, .insecureEndpointBlocked)
  }

  func testCanSendTruthTable() {
    XCTAssertFalse(snapshot(endpoint: "http://localhost:8080", enabled: false).canSend)
    XCTAssertNil(snapshot(endpoint: "http://localhost:8080", enabled: false).refusalCategory)
    XCTAssertTrue(snapshot(endpoint: "http://localhost:8080").canSend)
    XCTAssertTrue(snapshot(endpoint: "https://h.example", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "https://h.example").canSend)
    XCTAssertFalse(snapshot(endpoint: "http://h.example", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "http://h.example", override: true).canSend)
    XCTAssertTrue(snapshot(endpoint: "http://h.example", credential: "c", override: true).canSend)
    XCTAssertFalse(snapshot(endpoint: "", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "ftp://h.example", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "not a url", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "/relative/path", credential: "c").canSend)
    XCTAssertFalse(snapshot(endpoint: "https://", credential: "c").canSend)
  }

  func testRefusalPrecedence() {
    XCTAssertEqual(snapshot(endpoint: "http://h.example").refusalCategory, .insecureEndpointBlocked)
    XCTAssertEqual(
      snapshot(endpoint: "http://h.example", override: true).refusalCategory, .missingCredential)
    XCTAssertEqual(snapshot(endpoint: "https://h.example").refusalCategory, .missingCredential)
    XCTAssertEqual(snapshot(endpoint: "").refusalCategory, .invalidSettings)
    XCTAssertEqual(snapshot(endpoint: "nope").refusalCategory, .invalidSettings)
    XCTAssertNil(snapshot(endpoint: "https://h.example", credential: "c").refusalCategory)
    XCTAssertFalse(snapshot(endpoint: "", enabled: false).canSend)
  }

  func testSnapshotIsImmutableAfterCapture() {
    let preferences = makePreferences()
    preferences.rewriteEnabled = true
    preferences.rewriteEndpoint = "http://192.168.1.20:8080"
    preferences.setInsecureOverride(true, for: "http://192.168.1.20:8080")
    let store = FakeRewriteCredentialStore()
    try? store.write(origin: "http://192.168.1.20:8080", secret: "abc")
    let admitted = RewriteSettings.capture(preferences: preferences, credentialStore: store)
    XCTAssertTrue(admitted.canSend)
    preferences.setInsecureOverride(false, for: "http://192.168.1.20:8080")
    preferences.rewriteEnabled = false
    preferences.rewriteTimeoutSeconds = 5
    XCTAssertTrue(admitted.canSend)
    XCTAssertEqual(admitted.timeoutSeconds, 20)
    let fresh = RewriteSettings.capture(preferences: preferences, credentialStore: store)
    XCTAssertFalse(fresh.canSend)
    XCTAssertEqual(fresh.timeoutSeconds, 5)
  }

  func testTimeoutClampsOnRead() {
    let preferences = makePreferences()
    XCTAssertEqual(preferences.rewriteTimeoutSeconds, 20)
    preferences.rewriteTimeoutSeconds = 2
    XCTAssertEqual(preferences.rewriteTimeoutSeconds, 5)
    preferences.rewriteTimeoutSeconds = 600
    XCTAssertEqual(preferences.rewriteTimeoutSeconds, 60)
    preferences.rewriteTimeoutSeconds = 33
    XCTAssertEqual(preferences.rewriteTimeoutSeconds, 33)
    XCTAssertEqual(snapshot(endpoint: "http://localhost", timeout: 0).timeoutSeconds, 5)
    XCTAssertEqual(snapshot(endpoint: "http://localhost", timeout: 61).timeoutSeconds, 60)
  }

  func testDefaultsAndPersistence() {
    let suite = "LocalFlow-rewrite-settings-\(UUID())"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertFalse(preferences.rewriteEnabled)
    XCTAssertEqual(preferences.rewriteEndpoint, "")
    XCTAssertEqual(preferences.rewriteDefaultMode, .clean)
    XCTAssertEqual(preferences.rewriteTimeoutSeconds, 20)
    XCTAssertEqual(preferences.rewriteInsecureOverrides, [:])
    preferences.rewriteEnabled = true
    preferences.rewriteEndpoint = "https://h.example"
    preferences.rewriteDefaultMode = .polished
    preferences.rewriteTimeoutSeconds = 45
    let reloaded = AppPreferences(defaults: defaults)
    XCTAssertTrue(reloaded.rewriteEnabled)
    XCTAssertEqual(reloaded.rewriteEndpoint, "https://h.example")
    XCTAssertEqual(reloaded.rewriteDefaultMode, .polished)
    XCTAssertEqual(reloaded.rewriteTimeoutSeconds, 45)
    defaults.set("shout", forKey: "rewriteDefaultMode")
    XCTAssertEqual(AppPreferences(defaults: defaults).rewriteDefaultMode, .clean)
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rewrite") {
      XCTAssertFalse(String(describing: defaults.object(forKey: key)).contains("secret"))
    }
  }

  func testEndpointValidationAndOriginNormalization() {
    XCTAssertEqual(
      RewriteSettings.normalizedOrigin("https://Rewrite.Example.NET"),
      "https://rewrite.example.net:443")
    XCTAssertEqual(
      RewriteSettings.normalizedOrigin("http://host.example/v1/"), "http://host.example:80")
    XCTAssertEqual(
      RewriteSettings.normalizedOrigin("http://HOST:8080/path?q=1"), "http://host:8080")
    XCTAssertEqual(RewriteSettings.normalizedOrigin("http://[::1]:8080"), "http://[::1]:8080")
    XCTAssertEqual(RewriteSettings.normalizedOrigin("http://[::1]"), "http://[::1]:80")
    XCTAssertEqual(RewriteSettings.normalizedOrigin(" https://h.example "), "https://h.example:443")
    for invalid in [
      "", "h.example", "ftp://h.example", "https://", "https:///path", "http://user:pw@h.example",
      "http://" + String(repeating: "a", count: 250) + ".example", "http://h.example:99999",
      "http://h ex.example",
    ] {
      XCTAssertNil(RewriteSettings.normalizedOrigin(invalid), invalid)
    }
    let settings = snapshot(endpoint: "https://Rewrite.Example.NET/v1/", credential: "c")
    XCTAssertEqual(settings.endpoint?.absoluteString, "https://Rewrite.Example.NET/v1/")
    XCTAssertEqual(settings.endpointOrigin, "https://rewrite.example.net:443")
  }

  func testCredentialBounds() throws {
    let store = FakeRewriteCredentialStore()
    XCTAssertThrowsError(try store.write(origin: "https://h:443", secret: ""))
    XCTAssertThrowsError(
      try store.write(origin: "https://h:443", secret: String(repeating: "x", count: 4_097)))
    XCTAssertNoThrow(
      try store.write(origin: "https://h:443", secret: String(repeating: "x", count: 4_096)))
    XCTAssertTrue(store.exists(origin: "https://h:443"))
    XCTAssertEqual(try store.read(origin: "https://h:443")?.count, 4_096)
    XCTAssertFalse(store.exists(origin: "https://other:443"))
    XCTAssertNil(try store.read(origin: "https://other:443"))
    try store.remove(origin: "https://h:443")
    XCTAssertFalse(store.exists(origin: "https://h:443"))
    XCTAssertThrowsError(try RewriteCredentialValidation.validate(secret: "a\nb"))
    XCTAssertThrowsError(try RewriteCredentialValidation.validate(secret: " a"))
    XCTAssertNoThrow(try RewriteCredentialValidation.validate(secret: "token-1234"))
    // Error codes are bounded and never carry the secret.
    do {
      try store.write(origin: "https://h:443", secret: String(repeating: "q", count: 5_000))
    } catch {
      XCTAssertFalse(String(describing: error).contains("qqq"))
      XCTAssertEqual(error as? RewriteCredentialError, .tooLarge)
    }
  }
}

extension RewriteSettingsTests {
  func testSettingsControlsEnforcePolicyAndUpdateNextSnapshot() throws {
    let preferences = makePreferences()
    let credentials = FakeRewriteCredentialStore()
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: preferences,
      rewriteCredentials: credentials, rewriteTransport: FakeRewriteTransport())
    model.rewriteEnabled = true
    XCTAssertFalse(model.rewriteEnabled)
    XCTAssertEqual(model.rewriteBlockedReason, "Enter a valid http:// or https:// endpoint first.")
    model.rewriteEndpoint = "https://server.test"
    XCTAssertFalse(model.showsInsecureOverride)
    XCTAssertNotNil(model.rewriteBlockedReason)
    model.credentialDraft = "private-token"
    model.setRewriteCredential()
    XCTAssertTrue(model.credentialPresent)
    XCTAssertEqual(model.credentialDraft, "")
    model.revealRewriteCredential()
    XCTAssertEqual(model.credentialDraft, "private-token")
    model.hideRewriteCredential()
    XCTAssertEqual(model.credentialDraft, "")
    model.rewriteEnabled = true
    model.rewriteMode = .concise
    model.rewriteTimeout = 500
    var captured = RewriteSettings.capture(preferences: preferences, credentialStore: credentials)
    XCTAssertTrue(captured.canSend)
    XCTAssertEqual(captured.mode, .concise)
    XCTAssertEqual(captured.timeoutSeconds, 60)
    model.rewriteTimeout = 0
    XCTAssertEqual(model.rewriteTimeout, 5)
    model.removeRewriteCredential()
    XCTAssertFalse(model.credentialPresent)
    XCTAssertFalse(model.rewriteEnabled)
    model.rewriteEndpoint = "http://localhost:8080"
    model.rewriteEnabled = true
    captured = RewriteSettings.capture(preferences: preferences, credentialStore: credentials)
    XCTAssertTrue(captured.canSend)
    XCTAssertFalse(model.showsInsecureOverride)
  }

  func testOriginChangeClearsOverrideAndSecretAndRevocationDisablesImmediately() throws {
    let preferences = makePreferences()
    let credentials = FakeRewriteCredentialStore()
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: preferences,
      rewriteCredentials: credentials, rewriteTransport: FakeRewriteTransport())
    model.rewriteEndpoint = "http://one.test:8080"
    XCTAssertTrue(model.showsInsecureOverride)
    model.rewriteEnabled = true
    XCTAssertFalse(model.rewriteEnabled)
    model.rewriteInsecureOverride = true
    XCTAssertTrue(model.rewriteWarning?.contains("one.test") == true)
    XCTAssertTrue(model.rewriteWarning?.contains("Authentication does not encrypt them.") == true)
    model.rewriteEnabled = true
    XCTAssertFalse(model.rewriteEnabled)
    model.credentialDraft = "first-secret"
    model.setRewriteCredential()
    model.rewriteEnabled = true
    XCTAssertTrue(model.rewriteEnabled)
    model.rewriteInsecureOverride = false
    XCTAssertFalse(preferences.rewriteEnabled)
    XCTAssertNotNil(model.rewriteBlockedReason)
    XCTAssertNil(model.rewriteWarning)
    model.rewriteInsecureOverride = true
    model.revealRewriteCredential()
    try credentials.write(origin: "http://two.test:8080", secret: "second-secret")
    model.rewriteEndpoint = "http://two.test:8080"
    XCTAssertTrue(model.credentialPresent)
    XCTAssertEqual(model.credentialDraft, "")
    XCTAssertFalse(model.credentialRevealed)
    XCTAssertFalse(model.rewriteInsecureOverride)
    XCTAssertFalse(preferences.insecureOverride(for: "http://one.test:8080"))
    model.rewriteEndpoint = "http://one.test:8080"
    XCTAssertFalse(model.rewriteInsecureOverride)
    model.rewriteEndpoint = "http://one.test:8081"
    XCTAssertFalse(model.credentialPresent)
  }

  func testCredentialNeverEntersPreferencesSnapshotOrDiagnostics() async {
    let suite = "LocalFlow-phase9-\(UUID())"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = AppPreferences(defaults: defaults)
    let credentials = FakeRewriteCredentialStore()
    let transport = FakeRewriteTransport()
    let secret = "private-credential-sentinel"
    transport.healthResult = .failure(.init(category: .authenticationFailed, diagnostic: secret))
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: preferences,
      rewriteCredentials: credentials, rewriteTransport: transport)
    model.rewriteEndpoint = "https://server.test"
    model.credentialDraft = secret
    model.setRewriteCredential()
    await model.testConnection()
    XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(secret))
    XCTAssertFalse(String(describing: model.rewriteSettings).contains(secret))
    XCTAssertFalse(model.rewriteDiagnostics.contains(secret))
    XCTAssertEqual(model.connectionResult?.diagnostic, "transport_error")
    XCTAssertFalse(model.connectionResult?.statusText.contains(secret) == true)
  }
}
