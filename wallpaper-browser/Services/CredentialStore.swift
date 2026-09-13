import Foundation
import Security

enum CredentialStoreError: LocalizedError {
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "credential.error.keychain|\(status)"
    }
  }
}

nonisolated final class CredentialStore: @unchecked Sendable {
  static let shared = CredentialStore()

  private let service = "neon.wallpaper-browser"
  private let apiKeyAccount = "steam-web-api-key"
  private let lock = NSLock()
  // `nil` means that Keychain has not been queried yet. An empty string is a
  // cached, valid result for a missing/invalid credential and must not trigger
  // another synchronous Keychain lookup.
  private var cachedAPIKey: String?

  func loadAPIKey() -> String {
    withLock {
      if let cachedAPIKey { return cachedAPIKey }

      var query = baseQuery(account: apiKeyAccount)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      let apiKey: String
      if status == errSecSuccess, let data = result as? Data {
        apiKey = String(data: data, encoding: .utf8) ?? ""
      } else {
        apiKey = ""
      }
      cachedAPIKey = apiKey
      return apiKey
    }
  }

  func saveAPIKey(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return }

    try withLock {
      let query = baseQuery(account: apiKeyAccount)
      SecItemDelete(query as CFDictionary)

      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(item as CFDictionary, nil)
      guard status == errSecSuccess else {
        // The delete above intentionally preserves the original save
        // semantics (its status is ignored). If the add fails, the actual
        // Keychain value may therefore be either the old value or no value;
        // force the next read to resolve it instead of returning stale data.
        cachedAPIKey = nil
        throw CredentialStoreError.unexpectedStatus(status)
      }
      cachedAPIKey = trimmed
    }
    NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)
  }

  func deleteAPIKey() throws {
    try withLock {
      let status = SecItemDelete(baseQuery(account: apiKeyAccount) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw CredentialStoreError.unexpectedStatus(status)
      }
      cachedAPIKey = ""
    }
    NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)
  }

  private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

extension Notification.Name {
  static let apiKeyDidChange = Notification.Name("WallpaperBrowser.APIKeyDidChange")
}
