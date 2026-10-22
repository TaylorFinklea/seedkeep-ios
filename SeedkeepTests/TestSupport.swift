import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

// MARK: - Shared container factory

/// Build an in-memory `ModelContainer` from the full production schema.
/// `name` scopes the on-disk namespace so concurrently-running test
/// suites don't step on each other's stores.
func makeTestContainer(name: String) -> ModelContainer {
    let schema = Schema(SeedkeepSchema.all)
    // cloudKitDatabase: .none — once the app target carries the CloudKit entitlement,
    // ModelConfiguration's default `.automatic` makes SwiftData validate the schema against
    // CloudKit's rules (all attributes optional / default) even for an in-memory store in the
    // test host, which throws on our `@Attribute(.unique) id` models (G1). Seedkeep syncs via its
    // own CKSyncEngine, never SwiftData-CloudKit, so the store stays local here too.
    let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try! ModelContainer(for: schema, configurations: config)
}

// MARK: - In-memory token store

/// `TokenStoring` test double. The real `KeychainTokenStore` silently loses
/// writes in the unit-test host (the sim bundle lacks the keychain-access-group
/// entitlement → `SecItemAdd` returns `errSecMissingEntitlement`). Reference
/// type so a controller's `clear()` of the legacy bearer token is observable by
/// the constructing test's later assertions (`load()`/`save()` are test-only).
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ initial: String? = nil) { token = initial }

    func load() -> String? { lock.withLock { token } }
    func save(_ token: String) { lock.withLock { self.token = token } }
    func clear() { lock.withLock { token = nil } }
}

// MARK: - Patch JSON

/// The JSON object an input encodes to, so a test can check exactly which keys a patch carries
/// (an omitted key is "leave alone"; `NSNull` is an explicit clear).
func encodedObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
