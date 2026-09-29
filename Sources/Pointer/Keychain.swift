import Foundation
import Security

/// API keys live in the login keychain, one entry per provider, so switching
/// providers doesn't destroy the other key. Never written to config.json.
enum Keychain {
    private static let service = "com.kavi.pointer"

    static func setKey(_ key: String, for provider: Provider) {
        let account = provider.rawValue
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            deleteKey(for: provider)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(trimmed.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("Pointer: keychain add failed (%d)", Int(addStatus))
            }
        } else if status != errSecSuccess {
            NSLog("Pointer: keychain update failed (%d)", Int(status))
        }
    }

    static func key(for provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    static func hasKey(for provider: Provider) -> Bool {
        key(for: provider) != nil
    }

    static func deleteKey(for provider: Provider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
