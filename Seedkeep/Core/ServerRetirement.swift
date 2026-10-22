// Apple-only app (N1). PARENT-OWNED contract: workers use these and do not change their shape.
//
// The Seedkeep server is retired: the app makes no requests to it, and N3 (T1) deleted the server
// client and every caller this switch gated. The switch and the refusing session stay until F
// removes them.
import Foundation
import OSLog
import Synchronization

enum ServerRetirement {
    /// True in every build. Gates read this rather than a literal so the gated code still
    /// compiles (and its unit tests still run) until N3 removes it.
    static let isRetired = true

    /// A URLSession whose every request fails immediately with `URLError(.cannotConnectToHost)`
    /// and never reaches the network.
    static func makeRefusingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    struct RefusalSnapshot: Equatable, Sendable {
        var count = 0
        var lastPath: String?
    }

    /// Refused requests, recorded synchronously before the failure is delivered, so a caller
    /// that has seen the failure always sees the count. Diagnostics and tests use it to prove
    /// nothing tried to reach the server.
    static var refusals: RefusalSnapshot { refusalStore.withLock { $0 } }

    static func resetRefusals() { refusalStore.withLock { $0 = RefusalSnapshot() } }

    fileprivate static func noteRefused(path: String?) {
        refusalStore.withLock { $0.count += 1; $0.lastPath = path }
        logger.error("Refused a Seedkeep server request: \(path ?? "?", privacy: .public)")
    }

    private static let refusalStore = Mutex(RefusalSnapshot())
    private static let logger = Logger(subsystem: "app.seedkeep", category: "ServerRetirement")
}

/// Refuses every request without network access.
final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ServerRetirement.noteRefused(path: request.url?.path)
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
