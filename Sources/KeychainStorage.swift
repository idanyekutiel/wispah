import Foundation
import Security

enum KeychainStorage {
    private static let service = Bundle.main.bundleIdentifier ?? "com.zachlatta.freeflow"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func save(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let baseQuery = baseQuery(account: account)
        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        switch SecItemCopyMatching(baseQuery as CFDictionary, nil) {
        case errSecSuccess:
            SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        default:
            break
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
