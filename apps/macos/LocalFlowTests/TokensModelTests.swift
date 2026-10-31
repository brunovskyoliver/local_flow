import AppKit
import CoreImage
import XCTest

@testable import LocalFlow

/// A scripted `flowd admin`: records every run and starts nothing.
final class FakeServerRunner: ServerProcessRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(path: String, arguments: [String])] = []
  private let answer: @Sendable (String, [String]) -> ServerProcessResult

  init(answer: @escaping @Sendable (String, [String]) -> ServerProcessResult) {
    self.answer = answer
  }

  var calls: [(path: String, arguments: [String])] { lock.withLock { recorded } }

  func run(_ path: String, _ arguments: [String]) async -> ServerProcessResult {
    lock.withLock { recorded.append((path, arguments)) }
    return answer(path, arguments)
  }
}

@MainActor
final class TokensModelTests: XCTestCase {
  nonisolated private static let value = "lfp_NOT-A-REAL-TOKEN"
  nonisolated private static let createdJSON = """
    {"id":3,"label":"Ada's iPhone","expires_at":"2026-11-01T10:00:00Z","token":"\(value)","link":"localflow://pair?address=x#token=\(value)"}
    """
  nonisolated private static let listJSON = """
    [{"id":3,"label":"Ada's iPhone","state":"live","user_id":0,"device_id":0,"created_at":"2026-10-31T10:00:00Z","expires_at":"2026-11-01T10:00:00Z"},
     {"id":2,"label":"Mini","state":"redeemed","user_id":4,"device_id":9,"created_at":"2026-10-30T10:00:00Z","expires_at":"2026-10-31T10:00:00Z"}]
    """
  nonisolated private static let people = """
    user 1   google  Ada Lovelace        approved  created 2026-10-01 14:37
      device 1  MacBook Pro     approved  enrolled 2026-10-01 14:37  last seen never
    user 4   token   Grace's phone       approved  created 2026-10-02 09:00
    user 5   apple   -                   pending   created 2026-10-02 09:00

    """

  private func fake(createStatus: Int32 = 0) -> FakeServerRunner {
    FakeServerRunner { _, arguments in
      if arguments.contains("create") {
        return createStatus == 0
          ? ServerProcessResult(status: 0, output: Self.createdJSON, error: "")
          : ServerProcessResult(status: createStatus, output: "", error: "too many live tokens\n")
      }
      if arguments.contains("--json") {
        return ServerProcessResult(status: 0, output: Self.listJSON, error: "")
      }
      if arguments.last == "list" {
        return ServerProcessResult(status: 0, output: Self.people, error: "")
      }
      return ServerProcessResult(status: 0, output: "done\n", error: "")
    }
  }

  private func admin(_ runner: FakeServerRunner, dev: Bool = true) -> ServerAdmin {
    let identity = AppIdentity(
      infoDictionary: ["LocalFlowVariant": dev ? "dev" : "production"],
      home: URL(fileURLWithPath: "/tmp/agents/home"))
    return ServerAdmin(paths: ServerModePaths(identity: identity), runner: runner)
  }

  func testAdminUsesTheDataDirectorysOwnFlowdAndDevFlag() async {
    let runner = fake()
    await admin(runner).run(["token", "list"]).assertSucceeded()
    let data = "/tmp/agents/home/Library/Application Support/LocalFlow Server Dev"
    XCTAssertEqual(runner.calls[0].path, data + "/bin/flowd")
    XCTAssertEqual(
      runner.calls[0].arguments, ["admin", "--data-dir", data, "--dev", "token", "list"])
  }

  func testCreateShowsTheValueOnceAndCloseForgetsIt() async {
    let runner = fake()
    let model = TokensModel(admin: admin(runner), addresses: [])
    await model.create(
      label: "Ada's iPhone", user: 4, lifetime: .week, address: "http://10.0.0.2:18090")
    XCTAssertEqual(model.created?.token, Self.value)
    let create = runner.calls.first { $0.arguments.contains("create") }!.arguments
    XCTAssertEqual(
      Array(create.suffix(11)),
      [
        "token", "create", "--label", "Ada's iPhone", "--ttl", "7d", "--json", "--user", "4",
        "--address", "http://10.0.0.2:18090",
      ])
    XCTAssertFalse(runner.calls.contains { $0.arguments.contains(Self.value) })
    model.clearCreated()
    XCTAssertNil(model.created)
    // The list holds no value, so nothing can bring it back.
    await model.reload()
    XCTAssertNil(model.created)
    XCTAssertEqual(model.tokens.map(\.state), ["live", "redeemed"])
    XCTAssertEqual(model.tokens[1].deviceID, 9)
  }

  func testCreateFailureShowsTheReasonAndNoValue() async {
    let model = TokensModel(admin: admin(fake(createStatus: 1)), addresses: [])
    await model.create(label: "x", user: nil, lifetime: .day, address: nil)
    XCTAssertNil(model.created)
    XCTAssertEqual(model.message, "flowd admin create failed: too many live tokens")
  }

  func testAFlowdFromBeforePairingAsksForAnUpdate() async {
    let runner = FakeServerRunner { _, _ in
      ServerProcessResult(status: 1, output: "", error: "usage: flowd admin --data-dir <dir>\n")
    }
    let model = TokensModel(admin: admin(runner), addresses: [])
    await model.reload()
    XCTAssertEqual(
      model.message, "This server's flowd has no pairing tokens. Update the server first.")
  }

  func testRevokeRunsTheExistingCommands() async {
    let runner = fake()
    let model = TokensModel(admin: admin(runner), addresses: [])
    await model.revokeToken(3)
    await model.revokeDevice(9)
    let runs = runner.calls.map { Array($0.arguments.dropFirst(4)) }
    XCTAssertTrue(runs.contains(["token", "revoke", "3"]))
    XCTAssertTrue(runs.contains(["revoke", "device", "9"]))
    XCTAssertEqual(model.message, "done")
  }

  func testOffersOnlyApprovedUsers() {
    XCTAssertEqual(
      TokensModel.approvedUsers(Self.people),
      [.init(id: 1, display: "Ada Lovelace"), .init(id: 4, display: "Grace's phone")])
  }

  func testQRCodeEncodesALink() throws {
    let link = "http://192.168.1.20:8090/#token=lfp_" + String(repeating: "q6ur", count: 28)
    let tiff = try XCTUnwrap(PairingQRCode.image(for: link, side: 180)?.tiffRepresentation)
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
    let found = detector?.features(in: try XCTUnwrap(CIImage(data: tiff)))
    XCTAssertEqual((found?.first as? CIQRCodeFeature)?.messageString, link)
  }
}

extension ServerProcessResult {
  fileprivate func assertSucceeded() { XCTAssertTrue(succeeded) }
}
