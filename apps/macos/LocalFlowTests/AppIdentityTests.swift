import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

final class AppIdentityTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

  private var production: AppIdentity {
    AppIdentity(
      infoDictionary: [
        "CFBundleIdentifier": "org.localflow.LocalFlow", "LocalFlowVariant": "production",
        "LocalFlowPortBase": "8000",
      ], home: home)
  }

  private var dev: AppIdentity {
    AppIdentity(
      infoDictionary: [
        "CFBundleIdentifier": "org.localflow.LocalFlow.dev", "LocalFlowVariant": "dev",
        "LocalFlowPortBase": "18000",
      ], home: home)
  }

  func testProductionValues() {
    let identity = production
    XCTAssertEqual(identity.variant, .production)
    XCTAssertEqual(identity.bundleIdentifier, "org.localflow.LocalFlow")
    XCTAssertEqual(
      identity.applicationSupportDirectory.path,
      "/Users/tester/Library/Application Support/LocalFlow")
    XCTAssertEqual(identity.logsDirectory.path, "/Users/tester/Library/Logs/LocalFlow")
    XCTAssertEqual(identity.keychainServicePrefix, "org.localflow.LocalFlow")
    XCTAssertEqual(identity.keychainService("rewrite"), "org.localflow.LocalFlow.rewrite")
    XCTAssertEqual(identity.flowdLabel, "org.localflow.LocalFlow.flowd")
    XCTAssertEqual(identity.mtplxLabel, "org.localflow.LocalFlow.mtplx")
    XCTAssertEqual(identity.flowdPort, 8080)
    XCTAssertEqual(identity.mtplxPort, 8000)
    XCTAssertEqual(identity.rewriteEndpoint, "http://127.0.0.1:8080")
  }

  func testDevValues() {
    let identity = dev
    XCTAssertEqual(identity.variant, .dev)
    XCTAssertEqual(identity.bundleIdentifier, "org.localflow.LocalFlow.dev")
    XCTAssertEqual(
      identity.applicationSupportDirectory.path,
      "/Users/tester/Library/Application Support/LocalFlow Dev")
    XCTAssertEqual(identity.logsDirectory.path, "/Users/tester/Library/Logs/LocalFlow Dev")
    XCTAssertEqual(identity.keychainServicePrefix, "org.localflow.LocalFlow.dev")
    XCTAssertEqual(identity.flowdLabel, "org.localflow.LocalFlow.dev.flowd")
    XCTAssertEqual(identity.mtplxLabel, "org.localflow.LocalFlow.dev.mtplx")
    XCTAssertEqual(identity.flowdPort, 18080)
    XCTAssertEqual(identity.mtplxPort, 18000)
    XCTAssertEqual(identity.rewriteEndpoint, "http://127.0.0.1:18080")
  }

  func testMissingKeysGiveProductionValues() {
    let identity = AppIdentity(infoDictionary: [:], home: home)
    XCTAssertEqual(identity, production)
    let partial = AppIdentity(
      infoDictionary: ["CFBundleIdentifier": "org.localflow.LocalFlow"], home: home)
    XCTAssertEqual(partial, production)
  }

  func testDevNeverSharesAProductionValue() {
    // A dev variant with production leftovers still gets its own identity.
    let leftovers = AppIdentity(
      infoDictionary: [
        "CFBundleIdentifier": "org.localflow.LocalFlow", "LocalFlowVariant": "dev",
        "LocalFlowPortBase": "8000",
      ], home: home)
    for identity in [dev, leftovers] {
      let prod = production
      XCTAssertNotEqual(identity.bundleIdentifier, prod.bundleIdentifier)
      XCTAssertNotEqual(identity.applicationSupportDirectory, prod.applicationSupportDirectory)
      XCTAssertNotEqual(identity.logsDirectory, prod.logsDirectory)
      XCTAssertNotEqual(identity.keychainServicePrefix, prod.keychainServicePrefix)
      XCTAssertFalse(
        identity.applicationSupportDirectory.path.hasPrefix(
          prod.applicationSupportDirectory.path + "/"))
      let devLabels: Set = [identity.flowdLabel, identity.mtplxLabel]
      XCTAssertTrue(devLabels.isDisjoint(with: [prod.flowdLabel, prod.mtplxLabel]))
      let devPorts: Set = [identity.flowdPort, identity.mtplxPort]
      XCTAssertTrue(devPorts.isDisjoint(with: [prod.flowdPort, prod.mtplxPort]))
    }
  }

  func testRunningTestHostIsProduction() {
    XCTAssertEqual(AppIdentity.current.variant, .production)
    XCTAssertEqual(AppIdentity.current.bundleIdentifier, "org.localflow.LocalFlow")
  }

  /// FR-034, User Story 5 scenario 2: everything the dev build stores sits under
  /// `LocalFlow Dev`, and its first launch creates its own database.
  func testDevStorageNeverReachesTheProductionDirectory() throws {
    let dev = dev
    let devRoot = dev.applicationSupportDirectory.path + "/"
    for location in [
      dev.databaseURL, dev.spoolDirectory, dev.pendingAudioDirectory, dev.modelsDirectory,
    ] {
      XCTAssertTrue(location.path.hasPrefix(devRoot), location.path)
    }
    XCTAssertTrue(dev.logsDirectory.path.hasSuffix("/Library/Logs/LocalFlow Dev"))
    let prod = production
    XCTAssertEqual(prod.databaseURL.path, prod.applicationSupportDirectory.path + "/history.sqlite")
    XCTAssertNotEqual(dev.databaseURL, prod.databaseURL)
  }

  func testFirstDevLaunchCreatesANewDatabase() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalFlowIdentity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let prodIdentity = AppIdentity(infoDictionary: [:], home: home)
    let devIdentity = AppIdentity(
      infoDictionary: ["LocalFlowVariant": "dev", "LocalFlowPortBase": "18000"], home: home)
    for identity in [prodIdentity, devIdentity] {
      try FileManager.default.createDirectory(
        at: identity.applicationSupportDirectory, withIntermediateDirectories: true)
    }
    let production = try TranscriptionStore(path: prodIdentity.databaseURL.path)
    let reservation = try await production.reserve()
    _ = try await production.commit(
      reservation: reservation,
      entry: try TranscriptionEntry(
        id: UUID(), text: "production text", createdAtMilliseconds: 1, quality: .complete,
        stopReason: .keyRelease, targetBundleID: nil))
    let before = try Data(contentsOf: prodIdentity.databaseURL)

    let devStore = try TranscriptionStore(path: devIdentity.databaseURL.path)
    let devEntries = try await devStore.recent(limit: 20)
    XCTAssertTrue(devEntries.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: devIdentity.databaseURL.path))
    XCTAssertEqual(try Data(contentsOf: prodIdentity.databaseURL), before)
  }
}
