import XCTest

@testable import LocalFlow

/// Feature 018 T023 (research R13, SC-004): existing settings survive as overrides.
@MainActor final class ServerSettingsMigrationTests: XCTestCase {
  /// Rewrite secrets are stored under the normalized origin.
  private static let rewriteOrigin = RewriteSettings.normalizedOrigin(
    "https://rewrite.example.com")!
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() {
    suite = "LocalFlow-server-migration-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() { defaults.removePersistentDomain(forName: suite) }

  func testARemoteSummariesServerBecomesACustomOverrideUntouched() throws {
    let preferences = AppPreferences(defaults: defaults)
    preferences.summaryServer = .remote
    preferences.summaryServerURL = "http://ai-vm:8000/v1"
    preferences.summaryServerModel = "qwen"
    let credentials = FakeRewriteCredentialStore()
    try credentials.write(origin: SummaryServer.credentialAccount, secret: "sk-test")
    ServerRouting.migrate(preferences, credentials: credentials)
    XCTAssertEqual(preferences.serverSummariesOverride, .custom)
    XCTAssertEqual(preferences.serverRewriteOverride, .server)
    XCTAssertEqual(preferences.summaryServer, .remote)
    XCTAssertEqual(preferences.summaryServerURL, "http://ai-vm:8000/v1")
    XCTAssertEqual(preferences.summaryServerModel, "qwen")
    XCTAssertEqual(try credentials.read(origin: SummaryServer.credentialAccount), "sk-test")
    XCTAssertEqual(
      preferences.serverMigrationNotice, [ServerRouting.migrationNotice(summariesHost: "ai-vm")])
    XCTAssertEqual(AppPreferences(defaults: defaults).serverSummariesOverride, .custom)
  }

  func testACustomRewriteAddressWithASecretBecomesACustomOverride() throws {
    let preferences = AppPreferences(defaults: defaults)
    preferences.rewriteEndpoint = "https://rewrite.example.com"
    let credentials = FakeRewriteCredentialStore()
    try credentials.write(origin: Self.rewriteOrigin, secret: "token")
    ServerRouting.migrate(preferences, credentials: credentials)
    XCTAssertEqual(preferences.serverRewriteOverride, .custom)
    XCTAssertEqual(preferences.rewriteEndpoint, "https://rewrite.example.com")
    XCTAssertEqual(try credentials.read(origin: Self.rewriteOrigin), "token")
    XCTAssertEqual(
      preferences.serverMigrationNotice,
      [ServerRouting.migrationNotice(rewriteHost: "rewrite.example.com")])
  }

  func testLocalDefaultsStayOnTheServer() throws {
    let preferences = AppPreferences(defaults: defaults)
    preferences.rewriteEndpoint = LocalAIInstaller.rewriteEndpoint
    // A Remote choice without a model and an off-Mac address without a secret are not kept.
    preferences.summaryServer = .remote
    preferences.summaryServerURL = "http://ai-vm:8000/v1"
    let credentials = FakeRewriteCredentialStore()
    try credentials.write(origin: "http://127.0.0.1:8091", secret: "local")
    ServerRouting.migrate(preferences, credentials: credentials)
    XCTAssertEqual(preferences.serverRewriteOverride, .server)
    XCTAssertEqual(preferences.serverSummariesOverride, .server)
    XCTAssertEqual(preferences.serverMeetingsOverride, .server)
    XCTAssertEqual(preferences.serverMigrationNotice, [])

    let unsecured = AppPreferences(defaults: UserDefaults(suiteName: suite + "-2")!)
    defer { UserDefaults().removePersistentDomain(forName: suite + "-2") }
    unsecured.rewriteEndpoint = "https://rewrite.example.com"
    ServerRouting.migrate(unsecured, credentials: FakeRewriteCredentialStore())
    XCTAssertEqual(unsecured.serverRewriteOverride, .server)
  }

  func testBothKeptOverridesAreListedAndTheMigrationRunsOnce() throws {
    let preferences = AppPreferences(defaults: defaults)
    preferences.summaryServer = .remote
    preferences.summaryServerURL = "http://ai-vm:8000/v1"
    preferences.summaryServerModel = "qwen"
    preferences.rewriteEndpoint = "https://rewrite.example.com"
    let credentials = FakeRewriteCredentialStore()
    try credentials.write(origin: Self.rewriteOrigin, secret: "token")
    ServerRouting.migrate(preferences, credentials: credentials)
    XCTAssertEqual(preferences.serverMigrationNotice.count, 2)
    XCTAssertEqual(preferences.serverMigrationVersion, 1)
    // The user moves a service back and clears the notice; a second launch changes nothing.
    preferences.serverSummariesOverride = .server
    preferences.serverMigrationNotice = []
    let relaunched = AppPreferences(defaults: defaults)
    ServerRouting.migrate(relaunched, credentials: credentials)
    XCTAssertEqual(relaunched.serverSummariesOverride, .server)
    XCTAssertEqual(relaunched.serverMigrationNotice, [])
    XCTAssertTrue(credentials.exists(origin: Self.rewriteOrigin))
  }
}
