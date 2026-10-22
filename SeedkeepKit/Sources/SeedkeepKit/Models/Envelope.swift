import Foundation

/// A typed app error: a machine `code` and a `message`. User-facing copy comes from
/// `humanizeError`, never from these fields directly.
public struct SeedkeepError: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// `error.localizedDescription` on a bridged Swift error without
/// `LocalizedError` yields the useless NSError placeholder ("The
/// operation couldn't be completed…"). Route it through `humanizeError`
/// so every view-level `catch { … error.localizedDescription … }` site
/// shows the same user-readable copy as the banner path.
extension SeedkeepError: LocalizedError {
    public var errorDescription: String? { humanizeError(self) }
}
