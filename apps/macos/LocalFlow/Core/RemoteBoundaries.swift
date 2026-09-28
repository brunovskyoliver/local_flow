import CryptoKit
import Foundation

/// Feature 014 boundaries. Everything remote dictation touches outside the process
/// (the WebSocket, Keychain, the Secure Enclave, the identity providers, the identity
/// endpoint and time) sits behind one of these so tests run with fakes and no network.

/// One message received from the WebSocket.
enum RemoteTransportMessage: Sendable, Equatable {
  case binary(Data)
  /// The channel accepts binary messages only; a text message closes it.
  case text
}

/// Errors a transport reports. Close codes come from the server.
enum RemoteTransportError: Error, Equatable, Sendable {
  case closed(code: Int)
  case unreachable
  case timeout
}

/// A connected WebSocket: binary only, no cookies, no `Authorization` header.
protocol RemoteTransport: AnyObject, Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> RemoteTransportMessage
  func close(code: Int)
}

/// Opens the channel WebSocket at `wss://<host>/v1/remote/channel`.
protocol RemoteTransportOpening: Sendable {
  func open(_ url: URL) async throws -> any RemoteTransport
}

/// The four Keychain items of service `<bundle id>.remote`.
enum RemoteCredentialItem: String, CaseIterable, Sendable {
  case deviceKey = "device-key"
  case serverKey = "server-key"
  case refreshToken = "refresh-token"
  case accessToken = "access-token"
}

protocol RemoteCredentialStoring: Sendable {
  func read(_ item: RemoteCredentialItem) throws -> Data?
  func write(_ item: RemoteCredentialItem, _ value: Data) throws
  func remove(_ item: RemoteCredentialItem) throws
  /// Deletes all four items; missing items are not an error.
  func removeAll() throws
}

/// The device's signing key. Production is a Secure Enclave P-256 key whose
/// `dataRepresentation` is kept in Keychain; it cannot be exported.
protocol RemoteDeviceKeys: Sendable {
  /// A new key: its handle (stored as `device-key`) and X9.63 public key (65 bytes).
  func create() throws -> (handle: Data, publicKey: Data)
  /// Nil when the handle no longer loads, for example after a restore onto new hardware.
  func publicKey(handle: Data) -> Data?
  /// DER ECDSA signature over `message`.
  func sign(_ message: Data, handle: Data) throws -> Data
}

enum IdentityProvider: String, Sendable, CaseIterable {
  case apple, google
}

/// Sign in with Apple or Google. Returns the provider's ID token (a JWT) whose
/// `nonce` claim is `nonce`, exactly as given.
protocol IdentitySignIn: Sendable {
  func signIn(provider: IdentityProvider, nonce: String) async throws -> String
  func isAvailable(_ provider: IdentityProvider) -> Bool
}

/// `GET /v1/remote/identity`. Used only during enrollment and to explain a pin mismatch.
protocol RemoteIdentityFetching: Sendable {
  func fetch(origin: URL) async throws -> RemoteServerIdentity
}

/// Monotonic time. Token refresh and fallback thresholds never read the wall clock.
protocol RemoteClock: Sendable {
  /// Time since an arbitrary fixed point, never going backwards.
  func now() -> Duration
  func sleep(for duration: Duration) async throws
}

struct SystemRemoteClock: RemoteClock {
  func now() -> Duration {
    .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
  }
  func sleep(for duration: Duration) async throws {
    try await ContinuousClock().sleep(for: duration)
  }
}
