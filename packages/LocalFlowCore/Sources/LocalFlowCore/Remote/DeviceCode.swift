import CryptoKit
import Foundation

/// Feature 028 (ADR 0039): the 6-digit code both devices show while an invited device waits
/// for confirmation. Test vectors: `fixtures/remote/device-code.json`.
public enum DeviceCode {
  /// The first 4 bytes of SHA-256(label ‖ inviter key ‖ new key ‖ pair binding), big-endian,
  /// mod 1,000,000, as six digits with leading zeros.
  public static func code(inviterKey: Data, newKey: Data, pairBinding: Data) -> String {
    let digest = SHA256.hash(
      data: Data("localflow-v1-device-code".utf8) + inviterKey + newKey + pairBinding)
    let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
    let digits = String(value)
    return String(repeating: "0", count: 6 - digits.count) + digits
  }

  /// `123456` as `123 456`, the way both screens show it.
  public static func grouped(_ code: String) -> String {
    "\(code.prefix(3)) \(code.dropFirst(3))"
  }
}
