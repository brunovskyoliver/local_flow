import XCTest

@testable import LocalFlowCore

final class ServerAddressKindTests: XCTestCase {
  func testClassifiesWithTheSameRuleAsPlainHTTP() {
    let table: [(String, ServerAddressKind?)] = [
      ("192.168.1.20", .lan), ("10.0.0.2", .lan), ("172.16.0.1", .lan), ("172.31.255.1", .lan),
      ("fd12:3456::1", .lan),
      ("100.64.0.1", .tailscale), ("100.127.255.254", .tailscale),
      ("fd7a:115c:a1e0::1", .tailscale),
      // Skipped: loopback, link-local, public, and things that aren't addresses.
      ("127.0.0.1", nil), ("::1", nil), ("169.254.1.1", nil), ("fe80::1", nil),
      ("100.63.255.255", nil), ("100.128.0.1", nil), ("172.32.0.1", nil), ("8.8.8.8", nil),
      ("2001:4860:4860::8888", nil), ("mini.local", nil), ("", nil),
    ]
    for (ip, kind) in table {
      XCTAssertEqual(RemoteDictationSettings.serverAddressKind(ip: ip), kind, ip)
    }
    // Every address it offers must be one `origin` accepts over http.
    for (ip, kind) in table where kind != nil {
      let host = ip.contains(":") ? "[\(ip)]" : ip
      XCTAssertNotNil(RemoteDictationSettings.origin("http://\(host):8090"), ip)
    }
  }
}
