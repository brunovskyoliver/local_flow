// The only Swift in the Rust client: CryptoKit has no C API, and its key blob is the handle Swift's
// `SecureEnclaveDeviceKeys` keeps in Keychain. Called from keys_mac.rs. No ACL and no prompt.
import CryptoKit
import Foundation

private func key(_ handle: UnsafePointer<UInt8>, _ count: Int) -> SecureEnclave.P256.Signing.PrivateKey? {
  try? SecureEnclave.P256.Signing.PrivateKey(
    dataRepresentation: Data(bytes: handle, count: count))
}

private func copy(_ data: Data, _ to: UnsafeMutablePointer<UInt8>) {
  data.copyBytes(to: to, count: data.count)
}

/// `handleCount` holds the buffer's size going in and the handle's size coming out.
@_cdecl("lf_enclave_create")
public func create(
  _ handle: UnsafeMutablePointer<UInt8>, _ handleCount: UnsafeMutablePointer<Int>,
  _ publicKey: UnsafeMutablePointer<UInt8>
) -> Bool {
  guard SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey(),
    key.dataRepresentation.count <= handleCount.pointee
  else { return false }
  copy(key.dataRepresentation, handle)
  handleCount.pointee = key.dataRepresentation.count
  copy(key.publicKey.x963Representation, publicKey)
  return true
}

/// `out` takes the 65-byte X9.63 public key.
@_cdecl("lf_enclave_public_key")
public func publicKey(
  _ handle: UnsafePointer<UInt8>, _ handleCount: Int, _ out: UnsafeMutablePointer<UInt8>
) -> Bool {
  guard let key = key(handle, handleCount) else { return false }
  copy(key.publicKey.x963Representation, out)
  return true
}

/// `out` takes the 64-byte r||s. CryptoKit hashes `message` with SHA-256.
@_cdecl("lf_enclave_sign")
public func sign(
  _ handle: UnsafePointer<UInt8>, _ handleCount: Int, _ message: UnsafePointer<UInt8>,
  _ messageCount: Int, _ out: UnsafeMutablePointer<UInt8>
) -> Bool {
  guard let key = key(handle, handleCount),
    let signature = try? key.signature(for: Data(bytes: message, count: messageCount))
  else { return false }
  copy(signature.rawRepresentation, out)
  return true
}
