import Foundation
import Security

/// Keychain generic password: service `org.localflow.LocalFlow.rewrite`, account
/// = endpoint origin. Errors map to bounded codes; the secret never leaves this
/// type except through `read`.
struct RewriteCredentialStore: Sendable {
  static let service = "org.localflow.LocalFlow.rewrite"

  private func query(origin: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: origin,
    ]
  }

  func read(origin: String) throws -> String? {
    var query = query(origin: origin)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, data.count <= RewriteCredentialValidation.maximumBytes,
        let secret = String(data: data, encoding: .utf8)
      else { throw RewriteCredentialError.tooLarge }
      return secret
    case errSecItemNotFound: return nil
    default: throw RewriteCredentialError.unavailable(status)
    }
  }

  func write(origin: String, secret: String) throws {
    try RewriteCredentialValidation.validate(secret: secret)
    let data = Data(secret.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query(origin: origin) as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw RewriteCredentialError.unavailable(updateStatus)
    }
    var add = query(origin: origin)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw RewriteCredentialError.unavailable(status) }
  }

  func remove(origin: String) throws {
    let status = SecItemDelete(query(origin: origin) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RewriteCredentialError.unavailable(status)
    }
  }

  /// Attributes only: the value is not returned, so the snapshot never copies it.
  func exists(origin: String) -> Bool {
    var query = query(origin: origin)
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
  }
}

/// Caches presence per origin so polling callers (the Settings snapshot, view
/// bodies) do not hit the Keychain on every read. LocalFlow is the only writer
/// of its items, and every write or removal goes through this wrapper, which
/// invalidates that origin. A different origin is a different cache key, so an
/// endpoint change looks up again. `read` always goes to the backing store.
final class CachedRewriteCredentialStore: RewriteCredentialStoring, @unchecked Sendable {
  private let base: any RewriteCredentialStoring
  private let lock = NSLock()
  private var presence: [String: Bool] = [:]

  init(_ base: any RewriteCredentialStoring = RewriteCredentialStore()) {
    self.base = base
  }

  func read(origin: String) throws -> String? { try base.read(origin: origin) }

  func write(origin: String, secret: String) throws {
    defer { invalidate(origin) }
    try base.write(origin: origin, secret: secret)
  }

  func remove(origin: String) throws {
    defer { invalidate(origin) }
    try base.remove(origin: origin)
  }

  func exists(origin: String) -> Bool {
    lock.lock()
    if let cached = presence[origin] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let present = base.exists(origin: origin)
    lock.lock()
    // Bounded by the handful of origins a user configures; drop all if it grows.
    if presence.count >= 16 { presence.removeAll() }
    presence[origin] = present
    lock.unlock()
    return present
  }

  private func invalidate(_ origin: String) {
    lock.lock()
    presence[origin] = nil
    lock.unlock()
  }
}
