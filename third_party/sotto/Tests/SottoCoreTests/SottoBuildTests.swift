import Foundation
import XCTest
@testable import SottoCore

final class SottoBuildTests: XCTestCase {
    func testReleasePreservesInstalledIdentityAndSeparatesDevelopmentState() {
        let release = SottoBuild.release
        let development = SottoBuild.development
        XCTAssertEqual(release.bundleIdentifier, "dev.davis.murmur")
        XCTAssertEqual(release.displayName, "Sotto")
        XCTAssertEqual(development.displayName, "Sotto Dev")
        XCTAssertNotEqual(release.bundleIdentifier, development.bundleIdentifier)
        XCTAssertNotEqual(release.dataDirectory, development.dataDirectory)
        XCTAssertNotEqual(release.credentialService, development.credentialService)
        XCTAssertNotEqual(release.windowAutosaveName, development.windowAutosaveName)
        XCTAssertEqual(development.credentialService, "dev.davis.sotto.dev.server")
        XCTAssertFalse(release.isDevelopment)
        XCTAssertTrue(development.isDevelopment)
    }
}
