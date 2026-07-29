import Foundation
import CryptoKit

/// On-disk byte storage for photo content — Photos-on-CloudKit Stage B (see
/// `.docs/ai/phases/2026-07-28-photos-on-cloudkit-spec.md` D2/D6 in the seedkeep repo, especially
/// D4's completeness roster and the eviction-bug rationale below).
///
/// THREE separate lifetimes, not one cache — see `Lifetime` — because a single "photo files"
/// directory eventually lets cache eviction delete the only copy of a pending upload. There is NO
/// eviction of any kind in 1.0: "cache = full library, never evict." Only the explicit purge paths
/// below (wired into account-switch, wipe, share-adopt/leave, and photo delete) ever remove bytes.
///
/// Namespaced by CloudKit environment + household exactly like `HouseholdCloudCoordinator`'s
/// durable state paths (same `Application Support/HouseholdSync` root, same
/// `cloudKitEnvironmentTag`) — a Development build's bytes must never leak into Production and one
/// household's photos must never leak into another's.
struct PhotoByteStore: Sendable {
    enum Lifetime: String, CaseIterable, Sendable {
        /// Bytes authored locally, not yet confirmed uploaded. DURABLE — never removed except on
        /// confirmed save success or explicit abandonment. Losing an entry here destroys the only
        /// copy of a user's photo.
        case pendingUploads = "PendingUploads"
        /// Bytes downloaded from CloudKit. Freely discardable — always re-fetchable.
        case cache = "PhotoCache"
        /// Bytes staged during an account-deletion garden transfer. Durable through destination
        /// save AND verification, then deleted.
        case transferWorkspace = "TransferWorkspace"
    }

    let lifetime: Lifetime
    let householdID: String
    let directory: URL

    init(lifetime: Lifetime, householdID: String) {
        self.lifetime = lifetime
        self.householdID = householdID
        self.directory = Self.rootDirectory(lifetime: lifetime, householdID: householdID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    struct Ref: Equatable, Sendable {
        let recordName: String
        let sha256: String
        let url: URL
    }

    // MARK: - Write (D2 immutability invariant)

    /// Writes `data` for `recordName`. The final path is content-addressed
    /// (`<recordName>.<sha256>.jpg`) and is only ever created by an atomic rename FROM a throwaway
    /// staging path, AFTER the hash is computed — see `stageAndHash`. Nothing external can ever
    /// observe the final path before it holds fully-hashed, correct bytes: CloudKit only receives
    /// `ref.url` once `write` has already returned. A prior ref for the same `recordName` with
    /// DIFFERENT bytes is removed, but only after the new file lands, so the record is never left
    /// with zero valid bytes on disk mid-write.
    @discardableResult
    func write(_ data: Data, for recordName: String) throws -> Ref {
        let (sha256, stagingURL) = try Self.stageAndHash(data, in: directory)
        let finalURL = fileURL(recordName: recordName, sha256: sha256)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: stagingURL)   // identical content already stored
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        }
        for stale in existingFiles(for: recordName) where stale != finalURL {
            try? FileManager.default.removeItem(at: stale)
        }
        return Ref(recordName: recordName, sha256: sha256, url: finalURL)
    }

    /// Writes `data` to a fresh, unique staging path inside `directory`, closes it (`Data.write`
    /// is synchronous and returns only once the file descriptor is closed), then hashes bytes READ
    /// BACK from that closed file — never the `data` argument — so the returned hash is provably
    /// over exactly what is on disk, not whatever was in memory at call time. `static` and free of
    /// `self` so the ordering invariant holds independent of any instance state.
    private static func stageAndHash(_ data: Data, in directory: URL) throws -> (sha256: String, url: URL) {
        let stagingURL = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try data.write(to: stagingURL, options: .atomic)
        let readBack = try Data(contentsOf: stagingURL)
        let digest = SHA256.hash(data: readBack)
        return (digest.map { String(format: "%02x", $0) }.joined(), stagingURL)
    }

    // MARK: - Read

    func ref(for recordName: String) -> Ref? {
        guard let url = existingFiles(for: recordName).first else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let sha256 = String(stem.dropFirst(Self.sanitize(recordName).count + 1))
        return Ref(recordName: recordName, sha256: sha256, url: url)
    }

    func data(for recordName: String) -> Data? {
        guard let ref = ref(for: recordName) else { return nil }
        return try? Data(contentsOf: ref.url)
    }

    func contains(_ recordName: String) -> Bool { ref(for: recordName) != nil }

    // MARK: - Purge

    /// Remove a single record's bytes. Safe to call when nothing is stored. Best-effort: an
    /// orphaned file left behind by a rare failure here is a disk-space nit, not the
    /// cross-household/account leak `removeAll` guards against, so callers on the per-record
    /// delete path (a simple, unguarded loop — see `HouseholdApplyGate.deleteLocal`) are not
    /// forced to propagate it.
    func remove(_ recordName: String) {
        for url in existingFiles(for: recordName) { try? FileManager.default.removeItem(at: url) }
    }

    /// Delete every byte this store holds (one lifetime, one household). THROWS: callers that
    /// must guarantee removal (the AC5 privacy purge, `purgeHousehold`) propagate failure into
    /// their own retry machinery rather than silently leaving bytes on disk.
    func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Remove `recordName`'s bytes from BOTH per-record mutable stores (PendingUploads +
    /// PhotoCache) for a household. Wired into `HouseholdApplyGate.deleteLocal`'s `.seedPhoto` /
    /// `.journalEntryPhoto` arms — a delete landing from CloudKit (or the local cascade) must not
    /// leave orphaned bytes behind. TransferWorkspace has no per-record delete concept; it is
    /// purged wholesale once a transfer completes (see `AppEnvironment.adoptTransferredGarden`, or
    /// `purgeHousehold` for the full wipe).
    static func purgeRecord(_ recordName: String, householdID: String) {
        PhotoByteStore(lifetime: .pendingUploads, householdID: householdID).remove(recordName)
        PhotoByteStore(lifetime: .cache, householdID: householdID).remove(recordName)
    }

    /// Purge every byte a household has across ALL THREE lifetimes. Wired into
    /// `HouseholdCloudCoordinator.wipeAndClear` (account switch/sign-out — AC5, a PRIVACY
    /// requirement: another household's photo bytes must not survive an account switch — plus the
    /// CKShare adopt/leave paths, which route through that same function). THROWS — see
    /// `removeAll`.
    static func purgeHousehold(_ householdID: String) throws {
        for lifetime in Lifetime.allCases {
            try PhotoByteStore(lifetime: lifetime, householdID: householdID).removeAll()
        }
    }

    // MARK: - Paths — mirrors `HouseholdCloudCoordinator`'s durable-path derivation exactly (same
    // Application Support / HouseholdSync root, same `cloudKitEnvironmentTag` namespacing) rather
    // than inventing a new location scheme.

    static func rootDirectory(lifetime: Lifetime, householdID: String) -> URL {
        HouseholdCloudCoordinator.householdSyncDir()
            .appendingPathComponent(lifetime.rawValue, isDirectory: true)
            .appendingPathComponent(HouseholdCloudCoordinator.cloudKitEnvironmentTag, isDirectory: true)
            .appendingPathComponent(Self.sanitize(householdID), isDirectory: true)
    }

    private func fileURL(recordName: String, sha256: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitize(recordName)).\(sha256).jpg")
    }

    private func existingFiles(for recordName: String) -> [URL] {
        let prefix = Self.sanitize(recordName) + "."
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jpg" }
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
