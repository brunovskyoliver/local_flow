import AppKit
import CoreImage
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

  private let listJSON = """
    {"schema_version":1,"users":[{"id":1,"provider":"token","display":"Oliver","state":"approved",\
    "created_at":"2026-11-03T09:12:44Z","changed_at":"2026-11-03T09:12:44Z","devices":[\
    {"id":3,"name":"Oliver's iPhone","kind":"iphone","state":"approved","enrolled_at":"2026-11-03T09:14:02Z",\
    "last_seen_at":"2026-11-03T10:01:00Z","changed_at":"2026-11-03T09:14:02Z","invited_by":null},\
    {"id":4,"name":"Old Mac","kind":null,"state":"pending","enrolled_at":"2026-11-03T09:20:00Z",\
    "last_seen_at":null,"changed_at":"2026-11-03T09:20:00Z","invited_by":null}]},\
    {"id":2,"provider":"apple","display":null,"state":"pending","created_at":"2026-11-03T11:00:00Z",\
    "changed_at":"2026-11-03T11:00:00Z","devices":[]}],"truncated":false}

    """

  func testListUsesJSONWithKinds() async {
    let calls = Calls()
    let json = listJSON
    let (result, users) = await Admin.listUsers { arguments in
      await calls.append(arguments)
      return ProcessResult(status: 0, output: json, error: "")
    }
    let made = await calls.all
    XCTAssertEqual(made, [["list", "--json"]])
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(users.map(\.id), [1, 2])
    XCTAssertEqual(users[1].display, "-")
    XCTAssertEqual(users[0].devices.map(\.kindLabel), ["iPhone", "Unknown"])
    XCTAssertEqual(users[0].devices[1].lastSeen, "never")
    XCTAssertEqual(
      Admin.localTime("2026-11-03T10:01:00Z", in: TimeZone(identifier: "UTC")!),
      "2026-11-03 10:01")
  }

  func testListFallsBackToTextWhenFlowdPredatesJSON() async {
    let calls = Calls()
    let (result, users) = await Admin.listUsers { arguments in
      await calls.append(arguments)
      if arguments.contains("--json") {
        return ProcessResult(status: 1, output: "", error: "usage: flowd admin --data-dir <dir>\n")
      }
      return ProcessResult(
        status: 0,
        output: "user 1  apple  -  approved  created 2026-10-02 18:04\n"
          + "  device 1  MacBook Pro  approved  enrolled 2026-10-02 18:04  last seen never\n",
        error: "")
    }
    let made = await calls.all
    XCTAssertEqual(made, [["list", "--json"], ["list"]])
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(users[0].devices.map(\.kindLabel), ["Unknown"])
  }

  func testListRefusesAnotherSchemaVersion() async {
    let (result, users) = await Admin.listUsers { _ in
      ProcessResult(status: 0, output: #"{"schema_version":2,"users":[]}"#, error: "")
    }
    XCTAssertFalse(result.succeeded)
    XCTAssertTrue(users.isEmpty)
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

  func testParsesATokenUserWithSpacesInItsLabel() {
    let users = Admin.parseList(
      "user 7   token   Grace's phone (work)  approved  created 2026-10-31 10:00\n"
        + "  device 3  Grace's phone  approved  enrolled 2026-10-31 10:01  last seen never\n")
    XCTAssertEqual(users.map(\.provider), ["token"])
    XCTAssertEqual(users[0].display, "Grace's phone (work)")
    XCTAssertEqual(users[0].devices.map(\.id), [3])
  }

  func testTokenArgumentsAndListHoldNoValue() {
    XCTAssertEqual(
      Admin.tokenCreateArguments(label: "Ada", user: nil, ttl: "24h", address: ""),
      ["token", "create", "--label", "Ada", "--ttl", "24h", "--json"])
    XCTAssertEqual(
      Admin.tokenCreateArguments(label: "Ada", user: 4, ttl: "7d", address: "http://10.0.0.2:8090"),
      [
        "token", "create", "--label", "Ada", "--ttl", "7d", "--json", "--user", "4", "--address",
        "http://10.0.0.2:8090",
      ])
    let tokens = Admin.parseTokens(
      #"[{"id":2,"label":"Mini","state":"redeemed","user_id":4,"device_id":9,"created_at":"2026-10-30T10:00:00Z","expires_at":"2026-10-31T10:00:00Z"}]"#
    )
    XCTAssertEqual(tokens.map(\.deviceID), [9])
    XCTAssertTrue(Admin.parseTokens("[]").isEmpty)
  }

  @MainActor
  func testPairingModelShowsTheValueOnceAndForgetsIt() async {
    let value = "lfp_NOT-A-REAL-TOKEN"
    let model = PairingModel { arguments in
      if arguments.contains("create") {
        return ProcessResult(
          status: 0,
          output:
            #"{"id":1,"label":"Ada","expires_at":"2026-11-01T10:00:00Z","token":"\#(value)","link":""}"#,
          error: "")
      }
      if arguments.contains("--json") {
        return ProcessResult(status: 0, output: "[]", error: "")
      }
      return ProcessResult(status: 0, output: "", error: "")
    }
    await model.create(label: "Ada", user: nil, ttl: "24h", address: "")
    XCTAssertEqual(model.created?.token, value)
    model.clearCreated()
    await model.reload()
    XCTAssertNil(model.created)
  }

  @MainActor
  func testPairingModelReportsAFlowdFromBeforePairing() async {
    let model = PairingModel { _ in
      ProcessResult(status: 1, output: "", error: "usage: flowd admin --data-dir <dir>\n")
    }
    await model.reload()
    XCTAssertEqual(model.message, "This flowd has no pairing tokens. Update the server first.")
  }

  func testQRCodeEncodesALink() throws {
    let link = "http://192.168.1.20:8090/#token=lfp_" + String(repeating: "q6ur", count: 28)
    let tiff = try XCTUnwrap(PairingView.qrCode(link)?.tiffRepresentation)
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
    let found = detector?.features(in: try XCTUnwrap(CIImage(data: tiff)))
    XCTAssertEqual((found?.first as? CIQRCodeFeature)?.messageString, link)
  }
}

private actor Calls {
  private(set) var all: [[String]] = []
  func append(_ arguments: [String]) { all.append(arguments) }
}
