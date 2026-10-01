import Darwin
import XCTest

final class ProcessStatsTests: XCTestCase {
  func testParsesProcArgs() {
    var buffer: [UInt8] = []
    withUnsafeBytes(of: Int32(3)) { buffer += $0 }
    buffer += Array("/bin/flowd-speech".utf8) + [0, 0, 0, 0]
    for argument in ["flowd-speech", "meeting", "--models"] { buffer += Array(argument.utf8) + [0] }
    buffer += Array("HOME=/Users/test".utf8) + [0]
    XCTAssertEqual(ProcessStats.parseProcArgs(buffer), ["flowd-speech", "meeting", "--models"])
    XCTAssertEqual(ProcessStats.parseProcArgs([1, 0]), [])
  }

  func testReadsItsOwnProcess() throws {
    let pid = getpid()
    let row = try XCTUnwrap(ProcessStats.row("tests", pid: pid))
    XCTAssertGreaterThan(row.footprint, 1 << 20)
    XCTAssertLessThan(try XCTUnwrap(row.started).timeIntervalSinceNow, 0)
    XCTAssertFalse(ProcessStats.arguments(pid).isEmpty)
    XCTAssertNotNil(ProcessStats.swap())
  }
}
