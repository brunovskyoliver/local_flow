import Foundation
import Security

/// Keychain generic passwords under service `<bundle id>.remote` (Feature 014 R7):
/// accounts `device-key`, `server-key`, `refresh-token` and `access-token`. The dev
/// variant's service differs, so it can never read the installed app's items. Values
/// leave this type only through `read`; nothing here logs. The caller picks the service
/// and the Keychain accessibility of new items (Feature 020 R7).
public final class RemoteCredentialStore: RemoteCredentialStoring, @unchecked Sendable {
  public let service: String
  private let accessibility: CFString
  private let lock = NSLock()
  private var issuedAt: Duration?

  public init(service: String, accessibility: CFString) {
    self.service = service
    self.accessibility = accessibility
  }

  /// Monotonic issue time of the stored access token; memory only, never persisted.
  public var accessTokenIssuedAt: Duration? {
    get { lock.withLock { issuedAt } }
    set { lock.withLock { issuedAt = newValue } }
  }

  private func query(_ item: RemoteCredentialItem) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: item.rawValue,
    ]
  }

  public func read(_ item: RemoteCredentialItem) throws -> Data? {
    var query = query(item)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, data.count <= 16_384 else {
        throw RemoteCredentialError.unavailable(errSecDecode)
      }
      return data
    case errSecItemNotFound: return nil
    default: throw RemoteCredentialError.unavailable(status)
    }
  }

  public func write(_ item: RemoteCredentialItem, _ value: Data) throws {
    guard !value.isEmpty, value.count <= 16_384 else {
      throw RemoteCredentialError.unavailable(errSecParam)
    }
    let update = [kSecValueData as String: value]
    let updated = SecItemUpdate(query(item) as CFDictionary, update as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw RemoteCredentialError.unavailable(updated) }
    var add = query(item)
    add[kSecValueData as String] = value
    add[kSecAttrAccessible as String] = accessibility
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw RemoteCredentialError.unavailable(status) }
  }

  public func remove(_ item: RemoteCredentialItem) throws {
    if item == .accessToken { accessTokenIssuedAt = nil }
    let status = SecItemDelete(query(item) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RemoteCredentialError.unavailable(status)
    }
  }

  public func removeAll() throws {
    var failure: (any Error)?
    for item in RemoteCredentialItem.allCases {
      do { try remove(item) } catch { failure = failure ?? error }
    }
    if let failure { throw failure }
  }
}

public enum RemoteCredentialError: Error, Equatable, Sendable {
  case unavailable(OSStatus)
}
