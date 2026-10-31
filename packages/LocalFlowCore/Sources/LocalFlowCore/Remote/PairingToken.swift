import Foundation

/// A one-time pairing token (specs/027-remote-pairing): `lfp_` and the base64url of the
/// server's public key and 32 random bytes. Held in memory only until it is redeemed; its
/// descriptions leave the value out, so string interpolation can't log it.
public struct PairingToken: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let value: String
  /// The X25519 key of the server that issued the token.
  public let serverKey: Data

  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("lfp_") else { return nil }
    let encoded = String(trimmed.dropFirst(4))
    guard let raw = Data(base64URL: encoded), raw.count == 64, raw.base64URL == encoded else {
      return nil
    }
    value = trimmed
    serverKey = Data(raw.prefix(32))
  }

  public var description: String { "PairingToken(redacted)" }
  public var debugDescription: String { description }
}

/// `localflow://pair?address=<origin>#token=<token>` (`localflow-dev` in development builds).
/// Opening one fills in the pairing form and spends nothing. Never log the URL.
public struct PairingLink: Sendable, Equatable {
  /// As given; `RemoteDictationSettings.origin` decides whether it is usable.
  public let address: String?
  public let token: PairingToken

  public init?(_ url: URL) {
    guard url.scheme == "localflow" || url.scheme == "localflow-dev",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.host == "pair", components.path.isEmpty,
      let fragment = components.fragment, fragment.hasPrefix("token="),
      let token = PairingToken(String(fragment.dropFirst(6)))
    else { return nil }
    self.token = token
    address = components.queryItems?.first { $0.name == "address" }?.value
  }

  /// A whole link pasted into the token field.
  public init?(pasted text: String) {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    self.init(url)
  }
}

/// What the pairing form says about a failed `RemoteEnrollment.pair`.
public func pairingFailureMessage(_ error: any Error) -> String {
  switch error {
  case RemoteEnrollmentError.wrongServer:
    "This address reaches a different server. Check the address or ask for a new token."
  case RemoteEnrollmentError.updateRequired:
    "Update the LocalFlow server to pair with a token. The token was not used."
  case RemoteEnrollmentError.invalidIdentity:
    "The server did not answer with a LocalFlow identity. Check the address."
  case RemoteEnrollmentError.deviceKeyUnavailable:
    "This device can't create a device key."
  case RemoteChannelError.server(.pairingTokenInvalid):
    "This token has expired, been used or been revoked. Ask for a new one."
  case RemoteChannelError.server(.revoked):
    "The server removed this device or its account. Ask the server's owner."
  case RemoteChannelError.server(.unauthorized):
    "The server knows this device under another account. Ask the server's owner."
  case RemoteChannelError.server(.busy):
    "The server is busy. Try again in a minute."
  default:
    "The server could not be reached. Try again."
  }
}
