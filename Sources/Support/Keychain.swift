import Foundation
import Security

/// Parolaları Keychain'de saklar (UserDefaults'ta değil).
enum Keychain {
    private static let service = "com.huseyinozer.g526"
    /// Yalnız testler için: imzasız derlemede (CI benzetici) gerçek Keychain çalışmaz; bu sözlük doluysa değerler burada tutulur
    static var testStore: [String: String]?

    private static func baseQuery(_ key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    static func set(_ value: String, for key: String) {
        remove(key)
        if value.isEmpty { return }
        if testStore != nil {
            testStore?[key] = value
            return
        }
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        if let store = testStore { return store[key] }
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        if testStore != nil {
            testStore?[key] = nil
            return
        }
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
