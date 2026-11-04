import XCTest

@testable import LocalFlowCore

/// Feature 028 (ADR 0039): the comparison code and the invite messages the phone reads,
/// against the vectors and examples flowd and Rust check too.
final class DeviceCodeTests: XCTestCase {
  private let remote = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fixtures/remote")

  private func json(_ path: String) throws -> Data {
    try Data(contentsOf: remote.appendingPathComponent(path))
  }

  private func hex(_ text: Any?) throws -> Data {
    let text = try XCTUnwrap(text as? String)
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      data.append(try XCTUnwrap(UInt8(text[index..<next], radix: 16)))
      index = next
    }
    return data
  }

  func testCodesMatchTheSharedVectors() throws {
    let file = try XCTUnwrap(
      JSONSerialization.jsonObject(with: json("device-code.json")) as? [String: Any])
    let vectors = try XCTUnwrap(file["vectors"] as? [[String: Any]])
    XCTAssertFalse(vectors.isEmpty)
    for vector in vectors {
      let code = DeviceCode.code(
        inviterKey: try hex(vector["inviter_key"]), newKey: try hex(vector["new_key"]),
        pairBinding: try hex(vector["pair_binding"]))
      XCTAssertEqual(code, vector["code"] as? String, "\(vector["note"] ?? "")")
    }
    XCTAssertEqual(DeviceCode.grouped("017360"), "017 360")
  }

  func testAnInviteRedemptionCarriesTheInvitingKey() throws {
    guard
      case .enrolled(1, .pending, "lfr_8tTJETmvNF-Rv6bF_-49sopr4IkwyVGA9Gv3f_XXjMc", let invite?) =
        try RemoteServerMessage.decode(json("messages/valid/enrolled-invite.json"))
    else { return XCTFail("no invite") }
    XCTAssertEqual(invite.inviterDeviceKey.count, 65)
    XCTAssertEqual(invite.confirmBy, ISO8601DateFormatter().date(from: "2026-11-03T10:24:30Z"))
    let plain = try RemoteServerMessage.decode(json("messages/valid/enrolled.json"))
    guard case .enrolled(_, .pending, _, nil) = plain else {
      return XCTFail("invite on a plain reply")
    }
    for name in ["enrolled-invite-approved", "enrolled-invite-key-only"] {
      XCTAssertThrowsError(try RemoteServerMessage.decode(json("messages/invalid/\(name).json")))
    }
  }

  func testAccountDevices() throws {
    guard
      case .accountDevicesReply(8, let devices) = try RemoteServerMessage.decode(
        json("messages/valid/account_devices_reply.json"))
    else { return XCTFail("no reply") }
    XCTAssertEqual(devices.map(\.id), [3, 9])
    XCTAssertEqual(devices[0].kind, .mac)
    XCTAssertTrue(devices[0].thisDevice)
    XCTAssertNil(devices[1].kind)
    XCTAssertEqual(devices[1].state, .pending)
    XCTAssertNil(devices[1].lastSeenAt)
    guard
      case .accountDevicesReply(9, []) = try RemoteServerMessage.decode(
        json("messages/valid/account_devices_reply-empty.json"))
    else { return XCTFail("no empty reply") }
    for name in [
      "empty-kind", "invite-on-approved", "missing-devices", "revoked-device",
    ] {
      XCTAssertThrowsError(
        try RemoteServerMessage.decode(json("messages/invalid/account_devices_reply-\(name).json")),
        name)
    }

    for (message, name) in [
      (RemoteClientMessage.accountDevices(op: 8), "account_devices"),
      (.accountDevices(op: 9, revokeDeviceID: 9), "account_devices-revoke"),
    ] {
      let encoded = try JSONSerialization.jsonObject(with: message.encoded()) as? NSDictionary
      let fixture = try JSONSerialization.jsonObject(with: json("messages/valid/\(name).json"))
      XCTAssertEqual(encoded, fixture as? NSDictionary, name)
    }
  }
}
