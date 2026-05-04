import Foundation

/// Keychain-backed storage for the user's BYOK provider keys.
///
/// We deliberately keep keys *only* on the device. They're never sent to
/// the Seedkeep server and never written to logs. The user can clear
/// them from Settings → API keys at any time.
///
/// Two providers are supported in F4: Anthropic (preferred — matches the
/// server's Hosted-tier model family) and OpenAI. The BYOK extractor
/// picks the first one that has a key configured.
public struct APIKeyStore: Sendable {
    public enum Provider: String, CaseIterable, Sendable, Identifiable {
        case anthropic
        case openai

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            }
        }

        public var keyHelpText: String {
            switch self {
            case .anthropic: return "API key from console.anthropic.com (starts with sk-ant-)."
            case .openai: return "API key from platform.openai.com (starts with sk-)."
            }
        }

        public var expectedPrefix: String {
            switch self {
            case .anthropic: return "sk-ant-"
            case .openai: return "sk-"
            }
        }

        fileprivate var account: String {
            switch self {
            case .anthropic: return "byok-anthropic-key"
            case .openai: return "byok-openai-key"
            }
        }
    }

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func load(_ provider: Provider) -> String? {
        let store = KeychainTokenStore(service: service, account: provider.account)
        return store.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func save(_ provider: Provider, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = KeychainTokenStore(service: service, account: provider.account)
        if trimmed.isEmpty {
            store.clear()
        } else {
            store.save(trimmed)
        }
    }

    public func clear(_ provider: Provider) {
        KeychainTokenStore(service: service, account: provider.account).clear()
    }

    public func has(_ provider: Provider) -> Bool {
        guard let key = load(provider) else { return false }
        return !key.isEmpty
    }

    /// Returns whichever configured provider should be tried first for a
    /// BYOK extraction. Anthropic wins if both are set (matches the
    /// server's Hosted-tier model family — same prompt shape, same
    /// expectations).
    public func preferredProvider() -> Provider? {
        if has(.anthropic) { return .anthropic }
        if has(.openai) { return .openai }
        return nil
    }
}
