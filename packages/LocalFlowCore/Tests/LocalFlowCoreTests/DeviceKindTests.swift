import XCTest

@testable import LocalFlowCore

/// Feature 028: `device_kind` goes into `pair` and `enroll` only when the identity lists it.
final class DeviceKindTests: XCTestCase {
  private func identity(_ extra: String) throws -> RemoteServerIdentity {
    let json = """
      {"schema_version":1,"server":"flowd/0.4.0","protocol_versions":[1],"suite":"x",\
      "server_key":"k","fingerprint":"f"\(extra)}
      """
    return try JSONDecoder().decode(RemoteServerIdentity.self, from: Data(json.utf8))
  }

  private func fields(_ message: RemoteClientMessage) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any])
  }

  func testIdentityWithUnknownKeysAndFeaturesDecodes() throws {
    let listed = try identity(#","features":["device_kind","later_thing"],"motd":{"a":1}"#)
    XCTAssertEqual(listed.deviceKind(.iphone), .iphone)
    XCTAssertNil(try identity("").deviceKind(.mac))
    XCTAssertNil(try identity(#","features":["device_invite"]"#).deviceKind(.mac))
  }

  func testPairAndEnrollCarryTheKindOnlyWhenGiven() throws {
    let key = Data(repeating: 1, count: 32)
    let pair = try fields(
      .pair(
        op: 1, token: "lfp_x", deviceName: "Mac", deviceKind: .mac, deviceKey: key,
        signature: key))
    XCTAssertEqual(pair["device_kind"] as? String, "mac")
    let enroll = try fields(
      .enroll(
        op: 1, provider: .apple, idToken: "t", deviceName: "Phone", deviceKind: .iphone,
        deviceKey: key, signature: key))
    XCTAssertEqual(enroll["device_kind"] as? String, "iphone")
    let older = try fields(
      .pair(op: 1, token: "lfp_x", deviceName: "Mac", deviceKey: key, signature: key))
    XCTAssertNil(older["device_kind"])
  }

}
