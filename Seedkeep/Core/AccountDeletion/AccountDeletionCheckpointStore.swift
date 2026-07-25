import Foundation

/// Durable, per-user storage for `AccountDeletionCheckpoint`.
///
/// One JSON file per authenticated user under Application Support —
/// deliberately NOT SwiftData, because `SyncEngine.eraseAllLocalData()`
/// wipes every SwiftData row on sign-out and the whole point of this
/// record is to outlive the local garden it is deleting.
///
/// Three properties matter more than convenience here:
///
///   - **Atomic.** The payload is encoded in full and handed to a single
///     atomic replacement. A crash mid-write leaves either the previous
///     document or the new one, never a truncated one — and a write that
///     fails outright leaves the previous checkpoint in place rather than
///     destroying the only resume point.
///   - **Fail-closed.** An unreadable checkpoint throws. Treating it as
///     "no checkpoint" would report *no deletion in progress* for a user
///     whose CloudKit garden may already be gone.
///   - **Per-user.** Files are keyed by user id, and a decoded checkpoint
///     whose `user_id` disagrees with the requested one is refused: it
///     would resume the wrong account's deletion.
///
/// Nothing here touches credentials, CloudKit, or SwiftData, so loading
/// and clearing a checkpoint — including cancellation — is safe at any
/// point in the flow.
struct AccountDeletionCheckpointStore: Sendable {

    /// The seam that actually puts bytes on disk. Injectable so tests can
    /// prove the store hands over one complete document and preserves the
    /// prior checkpoint when replacement fails.
    typealias Write = @Sendable (Data, URL) throws -> Void

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file exists but is not a checkpoint this build can decode:
        /// corrupt, truncated, or written by a newer app version.
        ///
        /// Carries only the user id — never the file's contents, which
        /// would drag whatever happens to be in a damaged file into logs
        /// and error surfaces.
        case unreadable(userID: String)
        /// The stored checkpoint belongs to a different account.
        case userMismatch(expected: String, found: String)

        var description: String {
            switch self {
            case .unreadable(let userID):
                return "account-deletion checkpoint for \(userID) could not be read"
            case .userMismatch(let expected, let found):
                return "account-deletion checkpoint belongs to \(found), not \(expected)"
            }
        }
    }

    /// `~/Library/Application Support/AccountDeletion`. Matches the
    /// `HouseholdSync` precedent in `HouseholdCloudCoordinator`.
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDeletion", isDirectory: true)
    }

    /// Foundation's atomic write: bytes land in a sibling temp file that
    /// is then renamed over the destination, so a reader sees the old
    /// document or the new one and never a partial one.
    static let atomicWrite: Write = { data, url in
        try data.write(to: url, options: .atomic)
    }

    private let directory: URL
    private let write: Write

    init(directory: URL = AccountDeletionCheckpointStore.defaultDirectory, write: @escaping Write = atomicWrite) {
        self.directory = directory
        self.write = write
    }

    /// Where a user's checkpoint lives.
    ///
    /// The user id is base64url-encoded into the filename rather than
    /// interpolated: a server id is opaque, and one containing `/` or
    /// `..` would otherwise write outside the store directory. The
    /// encoding is also injective, so two different ids can never land on
    /// the same file. Same trick as
    /// `HouseholdCloudCoordinator.durableScopeComponent`.
    func url(forUserID userID: String) -> URL {
        directory.appendingPathComponent("checkpoint-\(Self.fileComponent(userID)).json")
    }

    private static func fileComponent(_ userID: String) -> String {
        Data(userID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The user's checkpoint, or `nil` when there is genuinely none.
    ///
    /// Throws `Failure` when a checkpoint exists but cannot be trusted.
    /// "Exists" is decided before reading: a file that is present but
    /// unreadable must not be reported as absence, which the caller would
    /// read as *no deletion in progress*.
    func load(userID: String) throws -> AccountDeletionCheckpoint? {
        let url = url(forUserID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw Failure.unreadable(userID: userID)
        }
        guard let checkpoint = try? JSONDecoder().decode(AccountDeletionCheckpoint.self, from: data) else {
            throw Failure.unreadable(userID: userID)
        }
        guard checkpoint.userID == userID else {
            throw Failure.userMismatch(expected: userID, found: checkpoint.userID)
        }
        return checkpoint
    }

    /// Replaces the user's checkpoint. Encoding happens before any file
    /// I/O, so a failure to encode cannot damage the stored document.
    func save(_ checkpoint: AccountDeletionCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(data, url(forUserID: checkpoint.userID))
    }

    /// Removes the user's checkpoint. Idempotent — clearing a deletion
    /// that already finished, or cancelling twice, is not an error.
    func clear(userID: String) throws {
        let url = url(forUserID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
