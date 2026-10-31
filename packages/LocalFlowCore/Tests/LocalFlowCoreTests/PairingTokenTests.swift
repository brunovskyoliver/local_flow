import XCTest

@testable import LocalFlowCore

final class PairingTokenTests: XCTestCase {
  private let key = Data(repeating: 0x11, count: 32)
  private var token: String { "lfp_" + (key + Data(repeating: 0x22, count: 32)).base64URL }

  func testParsesTheServerKeyAndTrimsPastedSpace() throws {
    let parsed = try XCTUnwrap(PairingToken(" \(token)\n"))
    XCTAssertEqual(parsed.value, token)
    XCTAssertEqual(parsed.serverKey, key)
  }

  func testRefusesAnythingElse() {
    let last = token.index(before: token.endIndex)
    let bad = [
      "", "lfp_", String(token.dropFirst(4)), String(token.dropLast()), token + "A",
      "lfr_" + token.dropFirst(4), String(token[..<last]) + "!",
      // Non-canonical base64url: flowd's strict decoder refuses it too.
      String(token[..<last]) + "h", "lfp_" + key.base64URL,
    ]
    for text in bad { XCTAssertNil(PairingToken(text), text) }
  }

  func testDescriptionsLeaveTheValueOut() throws {
    let parsed = try XCTUnwrap(PairingToken(token))
    XCTAssertFalse("\(parsed)".contains("lfp_"))
    XCTAssertFalse(String(reflecting: parsed).contains("lfp_"))
  }

  func testLink() throws {
    let address = "https%3A%2F%2Fmini.example.com%3A8443"
    for scheme in ["localflow", "localflow-dev"] {
      let url = try XCTUnwrap(URL(string: "\(scheme)://pair?address=\(address)#token=\(token)"))
      let link = try XCTUnwrap(PairingLink(url))
      XCTAssertEqual(link.address, "https://mini.example.com:8443")
      XCTAssertEqual(link.token.value, token)
    }
    let bare = try XCTUnwrap(URL(string: "localflow://pair#token=\(token)"))
    XCTAssertNil(try XCTUnwrap(PairingLink(bare)).address)
  }

  func testOtherURLsAreNotPairingLinks() throws {
    for text in [
      "localflow://settings", "localflow://pair", "localflow://pair?token=\(token)",
      "localflow://pair#token=nope", "localflow://session/start#token=\(token)",
      "https://pair#token=\(token)", "localflow://pair/x#token=\(token)",
    ] {
      XCTAssertNil(PairingLink(try XCTUnwrap(URL(string: text))), text)
    }
  }

  func testTheFixedRefusalMessage() {
    XCTAssertEqual(
      pairingFailureMessage(RemoteChannelError.server(.pairingTokenInvalid)),
      "This token has expired, been used or been revoked. Ask for a new one.")
    XCTAssertEqual(RemoteErrorCode(rawValue: "pairing_token_invalid"), .pairingTokenInvalid)
  }
}
