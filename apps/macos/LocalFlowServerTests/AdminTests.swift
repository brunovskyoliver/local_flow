import XCTest

final class AdminTests: XCTestCase {
  func testParsesListWithPaddedColumnsAndSpacesInNames() {
    let text = """
      user 1   google  Ada Lovelace        approved  created 2026-10-01 14:37
        device 1  MacBook Pro     approved  enrolled 2026-10-01 14:37  last seen 2026-10-01 22:15
        device 2  iPhone          pending   enrolled 2026-10-01 15:00  last seen never
      user 12  apple   -                   pending   created 2026-10-02 09:00

      """
    let users = Admin.parseList(text)
    XCTAssertEqual(users.count, 2)
    XCTAssertEqual(users[0].display, "Ada Lovelace")
    XCTAssertEqual(users[0].devices.map(\.name), ["MacBook Pro", "iPhone"])
    XCTAssertEqual(users[0].devices[0].lastSeen, "2026-10-01 22:15")
    XCTAssertEqual(users[0].devices[1].lastSeen, "never")
    XCTAssertEqual(users[0].devices[1].state, "pending")
    XCTAssertEqual(users[1].id, 12)
    XCTAssertEqual(users[1].provider, "apple")
    XCTAssertEqual(users[1].state, "pending")
    XCTAssertTrue(users[1].devices.isEmpty)
  }

  func testParsesAudit() {
    let entries = Admin.parseAudit(
      "2026-10-01 14:39  admin:test  approve  device:1  ok\n2026-10-01 14:37  user:1  sign_in  -  ok\nbad line\n"
    )
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].actor, "admin:test")
    XCTAssertEqual(entries[0].target, "device:1")
    XCTAssertEqual(entries[1].action, "sign_in")
  }

  func testActionsFollowFlowdTransitions() {
    XCTAssertEqual(Admin.actions(kind: "user", state: "pending"), ["approve", "reject"])
    XCTAssertEqual(Admin.actions(kind: "user", state: "approved"), ["revoke"])
    XCTAssertEqual(Admin.actions(kind: "user", state: "rejected"), ["approve"])
    XCTAssertEqual(Admin.actions(kind: "device", state: "pending"), ["approve", "revoke"])
    XCTAssertEqual(Admin.actions(kind: "device", state: "revoked"), ["approve"])
    XCTAssertEqual(Admin.actions(kind: "device", state: "rejected"), [])
  }

  func testDecodesAdminStatus() throws {
    let json = """
      {"analysis":{"backend":"http://127.0.0.1:8443/v1","model":"smart"},"counters":{"dictation":{"requests":3,"failures":1},"rewrite":{"requests":2,"failures":0}},"started_at":"2026-10-01T21:00:00Z","version":"0.3.0"}
      """
    let status = try JSONDecoder().decode(AdminStatus.self, from: Data(json.utf8))
    XCTAssertEqual(status.counters["dictation"], AdminStatus.Count(requests: 3, failures: 1))
    XCTAssertEqual(status.analysis.model, "smart")
    XCTAssertEqual(status.startedAt, "2026-10-01T21:00:00Z")
  }
}
