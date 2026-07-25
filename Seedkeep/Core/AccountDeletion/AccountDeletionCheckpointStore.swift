import Foundation

/// Durable, per-user storage for `AccountDeletionCheckpoint`.
///
/// One JSON file per authenticated user under Application Support —
/// deliberately NOT SwiftData, because `SyncEngine.eraseAllLocalData()`
/// wipes every SwiftData row on sign-out and the whole point of this
/// record is to outlive the local garden it is deleting.
///
/// Four properties matter more than convenience here:
///
///   - **Atomic.** A save writes a complete document to a temporary file
///     in the same directory and then `rename(2)`s it over the
///     destination. A crash, or a failure between the two steps, leaves
///     the previous document byte-for-byte intact — never a truncated
///     one. The two steps are separate injectable operations so a test can
///     fail *between* them; an in-place write cannot pass those tests.
///   - **Serialized.** Every operation runs under one process-wide lock
///     keyed by nothing (the lock is cheap and operations are
///     microseconds), so a save cannot interleave with another save or a
///     clear. Ordering is enforced on top of that by a per-file
///     watermark: a save carrying an `updatedAt` older than what is
///     already stored is rejected instead of regressing the phase, and a
///     save that lost a race with `clear` cannot resurrect a finished or
///     cancelled deletion.
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

    /// The two halves of an atomic replacement, injectable so tests can
    /// fail after the temporary file exists but before it is moved into
    /// place — the failure mode that separates a real atomic write from an
    /// in-place truncating one.
    struct FileWriter: Sendable {
        /// Writes the complete document to a scratch URL in the
        /// destination's directory.
        var writeTemporary: @Sendable (Data, URL) throws -> Void
        /// Atomically moves the scratch file onto the destination,
        /// replacing whatever is there.
        var replace: @Sendable (URL, URL) throws -> Void

        /// Production: a full write to scratch, then `rename(2)` — the
        /// POSIX primitive that is atomic within a filesystem and works
        /// whether or not the destination already exists.
        static let atomicReplace = FileWriter(
            writeTemporary: { data, url in try data.write(to: url, options: .atomic) },
            replace: { source, destination in
                let result = source.withUnsafeFileSystemRepresentation { from in
                    destination.withUnsafeFileSystemRepresentation { to in
                        guard let from, let to else { return Int32(-1) }
                        return rename(from, to)
                    }
                }
                guard result == 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "could not replace the checkpoint file"]
                    )
                }
            }
        )
    }

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
        /// The write lost a race: a newer checkpoint is already stored, or
        /// the deletion this one describes was already cleared. Rejected
        /// rather than applied, because last-writer-wins would rewind the
        /// phase or resurrect a finished flow. Callers may ignore it —
        /// it means someone else already moved past this state.
        case staleSave(userID: String)

        var description: String {
            switch self {
            case .unreadable(let userID):
                return "account-deletion checkpoint for \(userID) could not be read"
            case .userMismatch(let expected, let found):
                return "account-deletion checkpoint belongs to \(found), not \(expected)"
            case .staleSave(let userID):
                return "account-deletion checkpoint for \(userID) is older than the stored one"
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

    private let directory: URL
    private let writer: FileWriter

    init(
        directory: URL = AccountDeletionCheckpointStore.defaultDirectory,
        writer: FileWriter = .atomicReplace
    ) {
        self.directory = directory
        self.writer = writer
    }

    // MARK: - Serialization

    /// How far each checkpoint file has advanced, and whether it was
    /// cleared. Keyed by file path, not by user id: the store is a value
    /// type that callers (and tests) construct freely, so the ordering
    /// state has to belong to the file everyone is writing, not to any one
    /// instance.
    private struct Watermark {
        var updatedAt: Int64
        var cleared: Bool
    }

    private nonisolated(unsafe) static var watermarks: [String: Watermark] = [:]
    private static let lock = NSLock()

    // MARK: - Paths

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

    // MARK: - Operations

    /// The user's checkpoint, or `nil` when there is genuinely none.
    ///
    /// Throws `Failure` when a checkpoint exists but cannot be trusted.
    /// "Exists" is decided before reading: a file that is present but
    /// unreadable must not be reported as absence, which the caller would
    /// read as *no deletion in progress*.
    func load(userID: String) throws -> AccountDeletionCheckpoint? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try Self.read(url: url(forUserID: userID), userID: userID)
    }

    /// Replaces the user's checkpoint.
    ///
    /// Encoding happens before any file I/O, so a failure to encode cannot
    /// damage the stored document. Throws `Failure.staleSave` when a newer
    /// checkpoint is already on disk or the deletion was already cleared.
    func save(_ checkpoint: AccountDeletionCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        let destination = url(forUserID: checkpoint.userID)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let watermark = Self.watermarks[destination.path] {
            // Strictly older always loses. An equal timestamp is a
            // rewrite of the same state — harmless, EXCEPT after a clear,
            // where it is exactly the delayed save that would resurrect
            // the finished deletion.
            if checkpoint.updatedAt < watermark.updatedAt
                || (watermark.cleared && checkpoint.updatedAt <= watermark.updatedAt) {
                throw Failure.staleSave(userID: checkpoint.userID)
            }
        } else if let stored = try? Self.read(url: destination, userID: checkpoint.userID),
                  checkpoint.updatedAt < stored.updatedAt {
            // No watermark yet (first write of this process against a file
            // left by an earlier launch) — fall back to what is on disk.
            throw Failure.staleSave(userID: checkpoint.userID)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try writer.writeTemporary(data, scratch)
        do {
            try writer.replace(scratch, destination)
        } catch {
            // The destination still holds the previous document. Don't
            // leave the scratch file behind to be mistaken for one.
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        Self.watermarks[destination.path] = Watermark(updatedAt: checkpoint.updatedAt, cleared: false)
    }

    /// Removes the user's checkpoint. Idempotent — clearing a deletion
    /// that already finished, cancelling twice, or racing another clear is
    /// not an error.
    func clear(userID: String) throws {
        let destination = url(forUserID: userID)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        // Remember how far the cleared flow had got, so a save still in
        // flight behind us cannot put it back.
        let stored = try? Self.read(url: destination, userID: userID)
        let previous = Self.watermarks[destination.path]?.updatedAt ?? Int64.min
        Self.watermarks[destination.path] = Watermark(
            updatedAt: max(previous, stored?.updatedAt ?? Int64.min),
            cleared: true
        )

        do {
            try FileManager.default.removeItem(at: destination)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — the contract is "no checkpoint afterwards",
            // and that is satisfied.
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
        }
    }

    private static func read(url: URL, userID: String) throws -> AccountDeletionCheckpoint? {
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
}
