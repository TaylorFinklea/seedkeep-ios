import Foundation
import Synchronization

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

    private let backend: any APIKeyBackend

    /// The Keychain, under `service`.
    public init(service: String) {
        self.backend = KeychainAPIKeyBackend(service: service)
    }

    /// The storage seam. Sample-garden mode and tests pass their own backend.
    init(backend: any APIKeyBackend) {
        self.backend = backend
    }

    public func load(_ provider: Provider) -> String? {
        backend.load(account: provider.account)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func save(_ provider: Provider, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            backend.clear(account: provider.account)
        } else {
            backend.save(trimmed, account: provider.account)
        }
    }

    public func clear(_ provider: Provider) {
        backend.clear(account: provider.account)
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

/// Where the provider keys are kept, by account name. The Keychain is the default. Sample-garden mode uses an
/// in-memory store, so the fixture never reads or writes the Keychain.
protocol APIKeyBackend: Sendable {
    func load(account: String) -> String?
    func save(_ value: String, account: String)
    func clear(account: String)
}

/// The Keychain, under `service`. Each account is a `KeychainTokenStore` item, as before the seam.
struct KeychainAPIKeyBackend: APIKeyBackend {
    let service: String

    func load(account: String) -> String? {
        KeychainTokenStore(service: service, account: account).load()
    }

    func save(_ value: String, account: String) {
        KeychainTokenStore(service: service, account: account).save(value)
    }

    func clear(account: String) {
        KeychainTokenStore(service: service, account: account).clear()
    }
}

/// Keys held in memory for the life of the object. A new instance starts empty.
final class InMemoryAPIKeyBackend: APIKeyBackend {
    private let values = Mutex<[String: String]>([:])

    func load(account: String) -> String? {
        values.withLock { $0[account] }
    }

    func save(_ value: String, account: String) {
        values.withLock { $0[account] = value }
    }

    func clear(account: String) {
        values.withLock { $0[account] = nil }
    }
}
