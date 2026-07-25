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
///   - **Atomic.** A save writes a complete document to a scratch file in
///     the same directory and then `rename(2)`s it over the destination. A
///     crash, or a failure between the two steps, leaves the previous
///     document byte-for-byte intact — never a truncated one. The two
///     steps are separate injectable operations so a test can fail
///     *between* them; an in-place write cannot pass those tests.
///   - **Ordered by the store, not by the caller.** Every operation runs
///     under one process-wide lock, and each write must present the
///     `Lease` issued by the previous one. Leases carry a store-issued
///     generation that nobody outside can mint or predict, so a delayed
///     write is rejected no matter what timestamp it carries and no matter
///     which direction its phase moved. A caller's clock is data, never
///     authority.
///   - **Fail-closed.** An unreadable checkpoint throws — on read AND on
///     write. Treating it as "no checkpoint" would report *no deletion in
///     progress* for a user whose CloudKit garden may already be gone, and
///     overwriting it would destroy the evidence of what went wrong. Only
///     an explicit `clear` removes a file the store cannot validate.
///   - **Per-user.** Files are keyed by user id, and a decoded checkpoint
///     whose `user_id` disagrees with the requested one is refused: it
///     would resume the wrong account's deletion.
///
/// Usage is a compare-and-swap loop:
///
///     var lease = try store.load(userID: id)?.lease
///     lease = try store.save(checkpoint, lease: lease)   // repeat per phase
///     try store.clear(userID: id)                        // when it is over
///
/// Nothing here touches credentials, CloudKit, or SwiftData, so loading
/// and clearing a checkpoint — including cancellation — is safe at any
/// point in the flow.
struct AccountDeletionCheckpointStore: Sendable {

    /// Proof that its holder has seen the current state of a checkpoint
    /// file, and the right to replace it exactly once.
    ///
    /// Opaque on purpose: the generation is `fileprivate`, so no caller
    /// can mint one, guess the next, or reuse a spent one. A save whose
    /// lease is not the current one lost a race — reload and decide again.
    struct Lease: Sendable, Equatable {
        fileprivate let path: String
        fileprivate let generation: UInt64
    }

    /// A checkpoint together with the lease needed to replace it.
    struct Loaded: Sendable, Equatable {
        var checkpoint: AccountDeletionCheckpoint
        var lease: Lease
    }

    /// The two halves of an atomic replacement, injectable so tests can
    /// fail after the scratch file exists but before it is moved into
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
        /// The write did not present the current lease: another write or a
        /// `clear` already moved this checkpoint on. Rejected rather than
        /// applied — last-writer-wins would rewind a phase or resurrect a
        /// finished flow. Reload and decide from the durable state.
        case staleSave(userID: String)

        var description: String {
            switch self {
            case .unreadable(let userID):
                return "account-deletion checkpoint for \(userID) could not be read"
            case .userMismatch(let expected, let found):
                return "account-deletion checkpoint belongs to \(found), not \(expected)"
            case .staleSave(let userID):
                return "account-deletion checkpoint for \(userID) moved on; reload before saving"
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

    /// The current generation of a checkpoint file and whether it is
    /// occupied. Keyed by file path, not by user id: the store is a value
    /// type that callers (and tests) construct freely, so the ordering
    /// state has to belong to the file everyone is writing, not to any one
    /// instance.
    ///
    /// The generation only ever increases, and it advances on `clear` as
    /// well as on `save`, so every lease issued before a clear is dead.
    private struct Slot {
        var generation: UInt64
        var occupied: Bool
    }

    private nonisolated(unsafe) static var slots: [String: Slot] = [:]
    private static let lock = NSLock()

    /// Must be called with `lock` held.
    private static func slot(forPath path: String, occupied: Bool) -> Slot {
        if let existing = slots[path] { return existing }
        // First time this process has touched the file — a checkpoint left
        // by an earlier launch starts at generation 1, so a caller that
        // has not loaded it cannot write over it.
        let seeded = Slot(generation: 1, occupied: occupied)
        slots[path] = seeded
        return seeded
    }

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

    /// The user's checkpoint and the lease that replaces it, or `nil` when
    /// there is genuinely none.
    ///
    /// Throws `Failure` when a checkpoint exists but cannot be trusted.
    /// "Exists" is decided before reading: a file that is present but
    /// unreadable must not be reported as absence, which the caller would
    /// read as *no deletion in progress*.
    func load(userID: String) throws -> Loaded? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let destination = url(forUserID: userID)
        guard let checkpoint = try Self.read(url: destination, userID: userID) else { return nil }
        let slot = Self.slot(forPath: destination.path, occupied: true)
        return Loaded(
            checkpoint: checkpoint,
            lease: Lease(path: destination.path, generation: slot.generation)
        )
    }

    /// Every checkpoint on disk, for callers that do not yet know — or can
    /// no longer learn — which user they belong to.
    ///
    /// This exists for exactly one situation, and it is the worst one:
    /// `DELETE /api/me` committed, the response was lost, and the next
    /// launch cannot authenticate because the deletion took the session
    /// with it. `load(userID:)` is useless there, because the signed-in
    /// identity it needs is precisely what is gone. The filename encodes
    /// the user id, so the record can still be found — and its receipt can
    /// still prove, unauthenticated, that the deletion happened.
    ///
    /// Undecodable files are SKIPPED, not thrown on and not deleted. A
    /// sweep is a background best-effort over records that may belong to
    /// other accounts; refusing to look at any of them because one is
    /// damaged would be the opposite of fail-closed here, and the damaged
    /// one is still protected — nothing in this method writes.
    func allCheckpoints() -> [Loaded] {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name -> Loaded? in
            guard name.hasPrefix("checkpoint-"), name.hasSuffix(".json") else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let checkpoint = try? JSONDecoder().decode(AccountDeletionCheckpoint.self, from: data),
                  // The name is derived from the user id, so a file whose
                  // contents disagree with its own path has been tampered
                  // with or hand-edited. Leave it alone.
                  url == self.url(forUserID: checkpoint.userID) else { return nil }
            let slot = Self.slot(forPath: url.path, occupied: true)
            return Loaded(checkpoint: checkpoint,
                          lease: Lease(path: url.path, generation: slot.generation))
        }
    }

    /// Replaces the user's checkpoint and returns the lease for the next
    /// write.
    ///
    /// `lease` is the one returned by the previous `save`, or by `load` at
    /// startup; pass `nil` only to create a record where the store has
    /// none. Anything else means this caller is working from a state the
    /// store has already moved past — `Failure.staleSave`.
    ///
    /// The destination is decoded and validated first, under the same
    /// lock: a corrupt or foreign file is reported, never overwritten.
    /// Encoding happens before any file I/O, so a failure to encode cannot
    /// damage the stored document.
    @discardableResult
    func save(_ checkpoint: AccountDeletionCheckpoint, lease: Lease? = nil) throws -> Lease {
        let data = try JSONEncoder().encode(checkpoint)
        let destination = url(forUserID: checkpoint.userID)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        // Fail closed on anything already there that we cannot account
        // for. Overwriting a damaged or foreign checkpoint would destroy
        // the only record of a deletion that may already have deleted a
        // CloudKit zone.
        let existing = try Self.read(url: destination, userID: checkpoint.userID)
        var slot = Self.slot(forPath: destination.path, occupied: existing != nil)
        // Keep occupancy honest if the file appeared or vanished outside
        // this store; the generation is untouched, so live leases survive.
        slot.occupied = existing != nil
        Self.slots[destination.path] = slot

        let presented = lease.flatMap { $0.path == destination.path ? $0.generation : nil }
        if slot.occupied {
            // Replacing a record requires having seen it.
            guard presented == slot.generation else { throw Failure.staleSave(userID: checkpoint.userID) }
        } else {
            // Creating one requires either no lease at all, or the lease
            // for this exact empty slot. A lease minted before a `clear`
            // carries an older generation and is refused, so a write still
            // in flight cannot resurrect a finished or cancelled deletion.
            guard presented == nil || presented == slot.generation else {
                throw Failure.staleSave(userID: checkpoint.userID)
            }
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

        let next = slot.generation &+ 1
        Self.slots[destination.path] = Slot(generation: next, occupied: true)
        return Lease(path: destination.path, generation: next)
    }

    /// Removes the user's checkpoint and retires every outstanding lease.
    ///
    /// Idempotent — clearing a deletion that already finished, cancelling
    /// twice, or racing another clear is not an error. This is the only
    /// operation allowed to remove a checkpoint the store cannot decode.
    func clear(userID: String) throws {
        let destination = url(forUserID: userID)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        let slot = Self.slot(forPath: destination.path, occupied: true)
        Self.slots[destination.path] = Slot(generation: slot.generation &+ 1, occupied: false)

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
