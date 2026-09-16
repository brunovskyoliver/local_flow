import Foundation
@testable import SottoServerKit
import XCTest

final class DataDirectoryLockTests: XCTestCase {
    func testSingleWriterLockRejectsSecondRunnerAndReleasesCleanly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("server")
        let first = try DataDirectoryLock(directory: directory)
        defer { first.release() }
        XCTAssertThrowsError(try DataDirectoryLock(directory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already using this data directory"))
        }
        let independent = try DataDirectoryLock(directory: root.appendingPathComponent("other-server"))
        independent.release()
        first.release()
        let next = try DataDirectoryLock(directory: directory)
        next.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".server.lock").path))
    }
}
