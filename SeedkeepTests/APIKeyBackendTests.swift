import Foundation
import Synchronization
import Testing
@testable import Seedkeep

@Suite("APIKeyStore backend seam")
struct APIKeyBackendTests {

    /// Records each account it's asked about, and keeps the values in memory.
    private final class RecordingBackend: APIKeyBackend {
        private let values = Mutex<[String: String]>([:])
        private let accounts = Mutex<[String]>([])

        var recordedAccounts: [String] { accounts.withLock { $0 } }

        func load(account: String) -> String? {
            accounts.withLock { $0.append(account) }
            return values.withLock { $0[account] }
        }

        func save(_ value: String, account: String) {
            accounts.withLock { $0.append(account) }
            values.withLock { $0[account] = value }
        }

        func clear(account: String) {
            accounts.withLock { $0.append(account) }
            values.withLock { $0[account] = nil }
        }
    }

    @Test("the in-memory backend keeps each provider's key under its own account")
    func inMemoryKeysAreIndependent() {
        let store = APIKeyStore(backend: InMemoryAPIKeyBackend())
        #expect(!store.has(.anthropic))
        #expect(store.preferredProvider() == nil)

        store.save(.openai, key: "test-openai-key")
        #expect(store.has(.openai))
        #expect(!store.has(.anthropic))
        #expect(store.preferredProvider() == .openai)

        store.save(.anthropic, key: "test-anthropic-key")
        #expect(store.load(.anthropic) == "test-anthropic-key")
        #expect(store.load(.openai) == "test-openai-key")
        // Anthropic wins when both are set.
        #expect(store.preferredProvider() == .anthropic)
    }

    @Test("keys are trimmed on save, and a blank key clears the stored one")
    func trimAndBlankClear() {
        let store = APIKeyStore(backend: InMemoryAPIKeyBackend())
        store.save(.anthropic, key: "  test-key \n")
        #expect(store.load(.anthropic) == "test-key")

        store.save(.anthropic, key: "   ")
        #expect(!store.has(.anthropic))
        #expect(store.load(.anthropic) == nil)
    }

    @Test("clear removes the key")
    func clearRemovesKey() {
        let store = APIKeyStore(backend: InMemoryAPIKeyBackend())
        store.save(.openai, key: "test-openai-key")
        store.clear(.openai)
        #expect(!store.has(.openai))
    }

    @Test("a new in-memory store starts empty, so nothing persists between launches")
    func newInMemoryStoreStartsEmpty() {
        APIKeyStore(backend: InMemoryAPIKeyBackend()).save(.anthropic, key: "test-key")
        #expect(!APIKeyStore(backend: InMemoryAPIKeyBackend()).has(.anthropic))
    }

    @Test("the store routes every operation through the backend it was given")
    func storeUsesOnlyItsBackend() {
        let backend = RecordingBackend()
        let store = APIKeyStore(backend: backend)

        store.save(.anthropic, key: " test-key ")
        #expect(store.load(.anthropic) == "test-key")
        store.clear(.anthropic)
        #expect(store.load(.anthropic) == nil)

        // Every call named an account, and the two providers never share one.
        #expect(backend.recordedAccounts.count == 4)
        #expect(Set(backend.recordedAccounts).count == 1)
        store.save(.openai, key: "test-openai-key")
        #expect(Set(backend.recordedAccounts).count == 2)
    }
}
