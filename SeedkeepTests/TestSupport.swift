import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

// MARK: - Shared container factory

/// Build an in-memory `ModelContainer` from the full production schema.
/// `name` scopes the on-disk namespace so concurrently-running test
/// suites don't step on each other's stores.
func makeTestContainer(name: String) -> ModelContainer {
    let schema = Schema(SeedkeepSchema.all)
    let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
    return try! ModelContainer(for: schema, configurations: config)
}

// MARK: - In-memory token store

/// `TokenStoring` test double. The real `KeychainTokenStore` silently loses
/// writes in the unit-test host (the sim bundle lacks the keychain-access-group
/// entitlement → `SecItemAdd` returns `errSecMissingEntitlement`), so any
/// `AuthController` restore test that relies on a saved token collapses to
/// `.signedOut`. Reference type so a controller's internal `clear()`/`save()`
/// is observable by the constructing test's later assertions — matching the
/// shared-global behavior the real keychain provides in production.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ initial: String? = nil) { token = initial }

    func load() -> String? { lock.withLock { token } }
    func save(_ token: String) { lock.withLock { self.token = token } }
    func clear() { lock.withLock { token = nil } }
}

// MARK: - Shared routable URL protocol stub

/// Route-dispatching URLProtocol used across sync-engine test suites.
///
/// Supports two routing modes:
///   - `routes[path]` or `routes["METHOD /path"]` — always returns the same `Data`
///   - `sequences[path]` — returns successive elements; repeats the last when exhausted
///
/// Method-qualified keys ("POST /api/locations") take precedence over bare
/// path keys, so a pull GET and a push POST on the same path can be stubbed
/// independently. Every unrouted request falls back to `fallbackBody`.
///
/// Originally defined per-file in `CatalogCorrectionSyncTests.swift` (with
/// sequence support) and `PetDeparturesSyncTests.swift` (routes-only). This
/// shared class is the superset; the per-file duplicates have been removed.
final class CatalogRouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var sequences: [String: [Data]] = [:]
    nonisolated(unsafe) static var sequenceCursors: [String: Int] = [:]
    nonisolated(unsafe) static var fallbackBody: Data = Data()
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data] = [:],
        sequences: [String: [Data]] = [:],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.sequences = sequences
        Self.sequenceCursors = [:]
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        Self.capturedRequests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogRouterMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func resetCapture() {
        lock.lock()
        defer { lock.unlock() }
        Self.capturedRequests = []
    }

    static func capturedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.capturedRequests.compactMap { $0.url?.path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let body: Data
        if let seq = Self.sequences[path], !seq.isEmpty {
            let cursor = Self.sequenceCursors[path] ?? 0
            let idx = min(cursor, seq.count - 1)
            body = seq[idx]
            Self.sequenceCursors[path] = cursor + 1
        } else if let methodRouted = Self.routes["\(method) \(path)"] {
            body = methodRouted
        } else if let routed = Self.routes[path] {
            body = routed
        } else {
            body = Self.fallbackBody
        }
        let status = Self.fallbackStatus
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
