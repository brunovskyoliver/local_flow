import XCTest

/// Launch evidence only. Permission, keyboard and insertion probes require the
/// signed interactive procedure recorded in the feature's acceptance documents.
final class PlatformProbeTests: XCTestCase {
  @MainActor
  func testSignedMenuBarApplicationLaunches() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.terminate()
  }
}
