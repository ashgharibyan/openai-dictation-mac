import Foundation
import Security

/// Stores the OpenAI API key as a generic password in the login Keychain.
enum KeychainStore {
    private static let service = "local.dictate.openai"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The key is read from the Keychain at most once per launch and then kept in memory.
    /// Every Keychain read can trigger a macOS access prompt (always, for an ad hoc signed build),
    /// so repeated reads turned into a stream of password dialogs.
    private static var cached: String?
    private static var didLoad = false

    static func loadAPIKey() -> String? {
        if didLoad { return cached }
        didLoad = true
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cached = key
        return key
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> OSStatus {
        // Delete and re-add rather than update: the new item is owned by this build of the app,
        // so this build can read it later without asking.
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Dictate – OpenAI API key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            cached = key
            didLoad = true
        }
        return status
    }

    @discardableResult
    static func deleteAPIKey() -> OSStatus {
        cached = nil
        didLoad = true
        return SecItemDelete(baseQuery as CFDictionary)
    }

    /// "sk-…abcd" for display; never shows the full key.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }
}
