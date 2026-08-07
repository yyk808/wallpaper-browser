import Foundation
import Security

enum CredentialStoreError: LocalizedError {
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "无法访问钥匙串（错误 \(status)）"
    }
  }
}

nonisolated final class CredentialStore: @unchecked Sendable {
  static let shared = CredentialStore()

  private let service = "neon.wallpaper-browser"
  private let apiKeyAccount = "steam-web-api-key"

  func loadAPIKey() -> String {
    var query = baseQuery(account: apiKeyAccount)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  func saveAPIKey(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return }

    let query = baseQuery(account: apiKeyAccount)
    SecItemDelete(query as CFDictionary)

    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw CredentialStoreError.unexpectedStatus(status)
    }
    NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(baseQuery(account: apiKeyAccount) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.unexpectedStatus(status)
    }
    NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)
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
