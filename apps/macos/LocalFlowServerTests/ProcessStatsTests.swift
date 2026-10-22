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

  /// The Whisper helper is a grandchild of flowd, and Python a child of the MTPLX shell
  /// wrapper: both must be found, with their depth, and the walk must stay bounded.
  func testDescendantsIncludeGrandchildrenAndStayBounded() {
    let tree: [Int32: [Int32]] = [1: [2, 3], 2: [4], 4: [5], 5: [6], 6: [7], 3: [2]]
    let found = ProcessStats.descendants(of: 1) { tree[$0] ?? [] }
    XCTAssertEqual(found.map(\.pid), [2, 3, 4, 5, 6])
    XCTAssertEqual(found.map(\.depth), [1, 1, 2, 3, 4], "PID 7 is past the depth bound")
    let limited = ProcessStats.descendants(of: 1, limit: 2) { tree[$0] ?? [] }
    XCTAssertEqual(limited.map(\.pid), [2, 3])
    let cycle = ProcessStats.descendants(of: 1) { $0 == 1 ? [2] : [1, 2] }
    XCTAssertEqual(cycle.map(\.pid), [2], "a PID is visited once")
  }

  func testRolesComeFromTheExecutableAndArguments() {
    XCTAssertEqual(
      ProcessStats.role(
        executable: "/opt/bin/flowd-speech", arguments: ["flowd-speech", "meeting", "--models"]),
      "Meeting worker")
    XCTAssertEqual(
      ProcessStats.role(executable: "/opt/bin/flowd-speech", arguments: ["flowd-speech", "serve"]),
      "Speech worker")
    XCTAssertEqual(
      ProcessStats.role(executable: "/opt/bin/flowd-meeting", arguments: ["flowd-meeting", "run"]),
      "Meeting processor", "the handoff processor is not the meeting worker")
    XCTAssertEqual(
      ProcessStats.role(executable: "/opt/bin/localflow-whisper-engine", arguments: []),
      "Whisper helper")
    XCTAssertEqual(
      ProcessStats.role(executable: "/usr/local/bin/python3.12", arguments: ["python3.12"]),
      "Model service (Python)")
    XCTAssertEqual(ProcessStats.role(executable: "/bin/bash", arguments: []), "Shell (bash)")
    XCTAssertEqual(ProcessStats.role(executable: "", arguments: []), "Process")
  }

  func testReadsItsOwnProcess() throws {
    let pid = getpid()
    let row = try XCTUnwrap(ProcessStats.row("tests", pid: pid))
    XCTAssertGreaterThan(row.footprint, 1 << 20)
    XCTAssertGreaterThan(row.resident, 1 << 20)
    XCTAssertFalse(ProcessStats.executable(pid).isEmpty)
    XCTAssertLessThan(try XCTUnwrap(row.started).timeIntervalSinceNow, 0)
    XCTAssertFalse(ProcessStats.arguments(pid).isEmpty)
    XCTAssertNotNil(ProcessStats.swap())
  }
}
