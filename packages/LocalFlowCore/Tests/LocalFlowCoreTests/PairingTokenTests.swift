import CryptoKit
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

  func testAPastedLink() throws {
    let link = try XCTUnwrap(
      PairingLink(pasted: " localflow://pair?address=http%3A%2F%2Fmini.local#token=\(token)\n"))
    XCTAssertEqual(link.address, "http://mini.local")
    XCTAssertEqual(link.token.value, token)
    XCTAssertNil(PairingLink(pasted: token))
    XCTAssertNil(PairingLink(pasted: "not a link"))
  }

  /// FR-012a. Each row must also round-trip through what the app saves.
  @MainActor func testHTTPOriginRule() throws {
    let allowed = [
      "http://127.0.0.1:8090", "http://127.255.0.1", "http://10.0.0.1", "http://172.16.0.1",
      "http://172.31.255.255", "http://192.168.1.20:8090", "http://169.254.1.1",
      "http://100.64.0.1", "http://100.127.255.255", "http://[::1]:8090", "http://[fe80::1]",
      "http://[febf::1]", "http://[fc00::1]", "http://[fd12:3456::1]",
      "http://[fd7a:115c:a1e0::1]:8090", "http://[::ffff:127.0.0.1]", "http://[::ffff:10.0.0.1]",
      "http://[::ffff:c0a8:114]", "http://[::ffff:100.64.0.1]", "http://localhost:8090",
      "http://mini", "http://mini-2", "http://mini.local", "http://a.b.local:8090",
      "http://mini.tail1234.ts.net", "http://mini.ts.net",
      "https://example.com", "https://8.8.8.8", "https://[2606:4700::1111]", "https://mini.local",
    ]
    for text in allowed {
      let origin = try XCTUnwrap(RemoteDictationSettings.origin(text), text)
      XCTAssertEqual(RemoteDictationSettings.origin(origin.absoluteString), origin, text)
      XCTAssertNotNil(RemoteEnrollment.channelURL(origin: origin), text)
    }
    for text in [
      "http://MINI.LOCAL", "http://Mini", "http://MINI.TailNet.TS.Net", "http://[FE80::1]",
    ] {
      XCTAssertNotNil(RemoteDictationSettings.origin(text), text)
    }
    let refused = [
      "http://8.8.8.8", "http://1.1.1.1:8090", "http://172.15.0.1", "http://172.32.0.1",
      "http://192.169.0.1", "http://169.253.0.1", "http://100.63.255.255", "http://100.128.0.1",
      "http://0.0.0.0", "http://224.0.0.1", "http://255.255.255.255", "http://example.com",
      "http://evil.ts.net.example.com", "http://10.0.0.1.example.com", "http://mini.local.evil.com",
      "http://ts.net", "http://.ts.net", "http://.local", "http://local.", "http://mini.",
      "http://mini.local.", "http://xts.net", "http://evilts.net",
      "http://[::]", "http://[2606:4700::1111]", "http://[::ffff:8.8.8.8]",
      "http://[::ffff:808:808]", "http://[::8.8.8.8]", "http://[64:ff9b::808:808]",
      "http://[fe00::1]", "http://[fec0::1]", "http://[nonsense]", "http://[10.0.0.1]",
      // Other spellings of an address, which the single-label rule must not let through.
      "http://134744072", "http://2130706433", "http://0x08080808", "http://0x8.8.8.8",
      "http://8.8.8", "http://8.8", "http://010.0.0.1.", "http://127.1",
      // Percent-encoding and IDNA reach the rule decoded and mapped.
      "http://10.0.0.1%2eexample.com", "http://mini\u{3002}evil.com", "http://b\u{00fc}cher",
      "http://u:p@10.0.0.1", "http://10.0.0.1/path", "http://10.0.0.1?x=1", "http://10.0.0.1#f",
      "ftp://10.0.0.1", "ws://10.0.0.1", "10.0.0.1", "",
    ]
    for text in refused {
      XCTAssertNil(RemoteDictationSettings.origin(text), text)
    }
  }

  func testIPv6ZoneIsKeptAndChecked() throws {
    let origin = try XCTUnwrap(RemoteDictationSettings.origin("http://[fe80::1%25en0]:8090"))
    XCTAssertEqual(RemoteDictationSettings.origin(origin.absoluteString), origin)
    XCTAssertNil(RemoteDictationSettings.origin("http://[2606:4700::1111%25en0]"))
  }

  func testAddressNotice() {
    XCTAssertEqual(
      RemoteDictationSettings.addressNotice(" http://10.0.0.1:8090 "),
      "This connection is not TLS. Content stays encrypted between this device and the server.")
    XCTAssertEqual(
      RemoteDictationSettings.addressNotice("http://example.com"),
      "http:// works only for private and Tailscale addresses. Use https:// for this one.")
    XCTAssertNil(RemoteDictationSettings.addressNotice("https://example.com"))
    XCTAssertNil(RemoteDictationSettings.addressNotice(""))
  }

  /// `fixtures/remote/pairing-vectors.json`, shared with flowd's TestPairingVectors.
  @MainActor func testPairingVectorsMatchFlowd() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("fixtures/remote/pairing-vectors.json")
    let v = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    func hex(_ key: String) -> Data {
      let text = v[key]!
      return Data(
        stride(from: 0, to: text.count, by: 2).map { offset in
          let start = text.index(text.startIndex, offsetBy: offset)
          return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    let input = RemoteEnrollment.pairSignatureInput(binding: hex("binding"))
    XCTAssertEqual(input, hex("signature_input"))
    XCTAssertEqual(input.prefix(v["label"]!.utf8.count), Data(v["label"]!.utf8))
    let key = try P256.Signing.PublicKey(x963Representation: hex("device_public_key"))
    let signature = try P256.Signing.ECDSASignature(derRepresentation: hex("signature"))
    XCTAssertTrue(key.isValidSignature(signature, for: input))
    let parsed = try XCTUnwrap(PairingToken(v["token"]!))
    XCTAssertEqual(parsed.serverKey, hex("server_public_key"))
    XCTAssertEqual(
      v["token"], "lfp_" + (hex("server_public_key") + hex("token_random")).base64URL)
  }

  func testTheFixedRefusalMessage() {
    XCTAssertEqual(
      pairingFailureMessage(RemoteChannelError.server(.pairingTokenInvalid)),
      "This token has expired, been used or been revoked. Ask for a new one.")
    XCTAssertEqual(RemoteErrorCode(rawValue: "pairing_token_invalid"), .pairingTokenInvalid)
  }
}
