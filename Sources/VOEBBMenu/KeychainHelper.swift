import Foundation
import Security

enum KeychainHelper {
    /// Updates the existing item in place and only adds one when there is none. Delete + Add would
    /// create a fresh item each time and drop its "Immer erlauben" ACL — for the Tonies refresh
    /// token, which rotates on every enrichment run, that is every refresh.
    static func save(password: String, for cardNumber: String) {
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: cardNumber,
            kSecAttrService as String: "de.voebb.menubar",
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // A lost write matters most for the rotating Tonies token: the next refresh would present
        // the already-consumed one and get disconnected. At least leave a trace.
        if status != errSecSuccess {
            NSLog("voebbar keychain: saving an item failed (OSStatus %d)", status)
        }
    }

    static func load(for cardNumber: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: cardNumber,
            kSecAttrService as String: "de.voebb.menubar",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for cardNumber: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: cardNumber,
            kSecAttrService as String: "de.voebb.menubar",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
