import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 016 FR-002: the Mac's schema and file locations are frozen while the portable
/// code moves into `packages/LocalFlowCore`. These pass before the move and after it.
final class MacCompatibilityTests: XCTestCase {
  func testMigrationIdentifiersAreFrozen() {
    XCTAssertEqual(
      HistoryMigrations.migrator().migrations,
      [
        "history-v1", "quality-v2", "vocabulary-v3", "rewrite-v4", "meetings-v5",
        "transcripts-v6", "speakers-v7", "identities-v8", "intelligence-v9",
        "meeting-language-v10", "app-context-v11", "meeting-language-en-sk-v12",
        "foreign-key-indexes-v13", "term-suggestions-v14", "remote-dictation-v15",
        "dictionary-usage-v16",
      ])
  }

  func testEverydayPathsAreFrozen() {
    let identity = AppIdentity(
      infoDictionary: ["CFBundleIdentifier": "org.localflow.LocalFlow"],
      home: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
    let root = "file:///Users/tester/Library/Application%20Support/LocalFlow/"
    XCTAssertEqual(identity.databaseURL.absoluteString, root + "history.sqlite")
    XCTAssertEqual(identity.spoolDirectory.absoluteString, root + "TemporaryAudio/")
    XCTAssertEqual(identity.pendingAudioDirectory.absoluteString, root + "PendingAudio/")
    XCTAssertEqual(identity.modelsDirectory.absoluteString, root + "Models/")
  }

  func testDevPathsAreFrozen() {
    let identity = AppIdentity(
      infoDictionary: [
        "CFBundleIdentifier": "org.localflow.LocalFlow.dev", "LocalFlowVariant": "dev",
      ], home: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
    let root = "file:///Users/tester/Library/Application%20Support/LocalFlow%20Dev/"
    XCTAssertEqual(identity.databaseURL.absoluteString, root + "history.sqlite")
    XCTAssertEqual(identity.spoolDirectory.absoluteString, root + "TemporaryAudio/")
    XCTAssertEqual(identity.pendingAudioDirectory.absoluteString, root + "PendingAudio/")
    XCTAssertEqual(identity.modelsDirectory.absoluteString, root + "Models/")
  }
}
