import Foundation
import Security

/// Tiny Keychain wrapper for storing the user's Anthropic API key. Generic
/// password item, scoped to the app (no access groups), no iCloud sync —
/// the key never leaves the device.
enum KeychainStore {
    private static let service = "com.murumoto.sitephoto.apikey"
    private static let account = "anthropic"

    static func saveAnthropicKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account
        ]
        // Try update first; if there's no existing item, fall through to add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String]      = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func loadAnthropicKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    static func clearAnthropicKey() {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
