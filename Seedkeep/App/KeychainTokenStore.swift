import Foundation
import Security

/// What `AuthController` needs from the legacy bearer-token item: deleting it. N1 made the iCloud
/// account the identity; a legacy rebind clears the old Sign in with Apple token, and nothing
/// reads or writes one any more. Tests inject an in-memory conformer (the unit-test host lacks
/// the keychain-access-group entitlement newer simulators require).
public protocol TokenStoring: Sendable {
    func clear()
}

/// Minimal Keychain item store for one `service` + `account`. Holds the BYOK provider keys
/// (`APIKeyStore`), and deletes the legacy bearer token through `TokenStoring`. Items are
/// device-local (`kSecAttrSynchronizable` is not set) and have no `kSecAttrAccessGroup`, so they
/// stay bound to this app's bundle id. Every operation is scoped to the exact service and
/// account: nothing clears the whole service.
public struct KeychainTokenStore: TokenStoring, Sendable {
    /// The account that held the retired server's Sign in with Apple bearer token. Kept so the
    /// legacy rebind deletes exactly that item.
    public static let legacyBearerTokenAccount = "bearer-token"

    public let service: String
    public let account: String

    public init(service: String, account: String) {
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
