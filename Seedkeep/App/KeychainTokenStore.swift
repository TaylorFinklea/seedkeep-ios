import Foundation
import Security

/// Minimal Keychain-backed token store. Items are device-local —
/// `kSecAttrSynchronizable` is not set, so the token does not sync
/// to iCloud Keychain. Items survive app reinstall on iOS by default
/// (no `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` set), which
/// matches the "stay signed in across reinstalls on the same device"
/// expectation for Sign in with Apple. No `kSecAttrAccessGroup`, so
/// the item stays bound to this app's bundle id.
public struct KeychainTokenStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String = "bearer-token") {
        self.service = service
        self.account = account
    }

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    public func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
