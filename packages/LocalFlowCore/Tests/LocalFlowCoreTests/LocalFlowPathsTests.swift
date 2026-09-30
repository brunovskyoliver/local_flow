import XCTest

@testable import LocalFlowCore

final class LocalFlowPathsTests: XCTestCase {
  func testApplicationSupportLayout() {
    let paths = LocalFlowPaths(
      applicationSupport: URL(fileURLWithPath: "/c/Library/Application Support", isDirectory: true))
    let root = "file:///c/Library/Application%20Support/LocalFlow/"
    XCTAssertEqual(paths.database.absoluteString, root + "history.sqlite")
    XCTAssertEqual(paths.temporaryAudio.absoluteString, root + "TemporaryAudio/")
    XCTAssertEqual(paths.pendingAudio.absoluteString, root + "PendingAudio/")
    XCTAssertEqual(paths.models.absoluteString, root + "Models/")
  }
}
