import Foundation
import Security

/// Stores the refresh token in the login keychain. (Access tokens live in memory only.)
enum Keychain {
    private static let service = "TimeTaggerBar"
    private static let account = "refreshtoken"

    /// Whether a token is stored, without reading it. Reading the secret can make macOS ask
    /// for keychain access (and block until answered); checking that the item exists never does.
    static func hasToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    /// Reads the token. Call it off the main thread: it can wait on a keychain prompt.
    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
