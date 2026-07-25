import Testing
import Foundation
@testable import Seedkeep
import SeedkeepKit

/// Disk-resume tests for the account-deletion checkpoint
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
/// § "Durable state": "The iOS app stores a local Codable checkpoint
/// outside SwiftData local-data erasure, keyed by authenticated user id").
///
/// The checkpoint is the only thing that can tell a relaunched app that a
/// CloudKit zone was already deleted but the server account was not — the
/// one state where guessing wrong is unrecoverable. So the store is
/// pinned on three properties:
///
///   1. Durable and atomic: a crash mid-write never leaves half a JSON
///      document, and a failed replacement leaves the PREVIOUS checkpoint
///      intact rather than nothing.
///   2. Fail-closed: an unreadable checkpoint throws. Returning `nil`
///      would read as "no deletion in progress" and silently strand a
///      half-finished deletion.
///   3. Per-user: one signed-in account's checkpoint can never be read,
///      overwritten, or cleared by another's.
@Suite("Account-deletion checkpoint store")
struct AccountDeletionCheckpointStoreTests {

    // MARK: - Helpers

    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDeletionCheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fullCheckpoint(userID: String = "u_owner") -> AccountDeletionCheckpoint {
        AccountDeletionCheckpoint(
            userID: userID,
            role: .sharedOwner,
            phase: .verified,
            transferID: "tr_abc123",
            sourceZoneName: "household-hh_1",
            sourceZoneOwnerName: "__defaultOwner__",
            destinationZoneName: "household-hh_1",
            destinationZoneOwnerName: "_succ_owner",
            lastFailure: .init(
                phase: .ownerVerified,
                message: "Copied garden does not match the original.",
                occurredAt: 1_700_000_000_000
            ),
            updatedAt: 1_700_000_000_500
        )
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Round trip

    @Test("save then load round-trips every field")
    func roundTrip() throws {
        let store = AccountDeletionCheckpointStore(directory: makeDirectory())
        let checkpoint = fullCheckpoint()
        try store.save(checkpoint)
        #expect(try store.load(userID: "u_owner") == checkpoint)
    }

    @Test("minimal checkpoint (participant, no transfer, no zones) round-trips")
    func roundTripMinimal() throws {
        let store = AccountDeletionCheckpointStore(directory: makeDirectory())
        let checkpoint = AccountDeletionCheckpoint(
            userID: "u_part",
            role: .participant,
            phase: .participantLeaving,
            updatedAt: 42
        )
        try store.save(checkpoint)
        let loaded = try #require(try store.load(userID: "u_part"))
        #expect(loaded == checkpoint)
        #expect(loaded.transferID == nil)
        #expect(loaded.sourceZoneName == nil)
        #expect(loaded.destinationZoneName == nil)
        #expect(loaded.lastFailure == nil)
    }

    @Test("absent checkpoint loads as nil, not an error")
    func loadAbsent() throws {
        let store = AccountDeletionCheckpointStore(directory: makeDirectory())
        #expect(try store.load(userID: "nobody") == nil)
    }

    @Test("load from a directory that does not exist yet is nil (fresh install)")
    func loadMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-created-\(UUID().uuidString)", isDirectory: true)
        let store = AccountDeletionCheckpointStore(directory: dir)
        #expect(try store.load(userID: "u_owner") == nil)
    }

    // MARK: - On-disk schema

    @Test("on-disk JSON has exactly the documented snake_case keys and no credential material")
    func onDiskSchema() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())

        let data = try Data(contentsOf: store.url(forUserID: "u_owner"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "user_id",
            "role",
            "phase",
            "transfer_id",
            "source_zone_name",
            "source_zone_owner_name",
            "destination_zone_name",
            "destination_zone_owner_name",
            "last_failure",
            "updated_at",
        ], "unexpected checkpoint keys: \(Set(object.keys))")

        let failure = try #require(object["last_failure"] as? [String: Any])
        #expect(Set(failure.keys) == ["phase", "message", "occurred_at"])

        // The single-use handoff token is a credential. It lives in the
        // universal link and the server's hash column — never on disk.
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("token"), "checkpoint must not persist any token material: \(text)")
        #expect(!text.contains("bearer"))
    }

    @Test("default directory is app-support JSON, outside the SwiftData store")
    func defaultDirectoryLocation() {
        let dir = AccountDeletionCheckpointStore.defaultDirectory
        #expect(dir.lastPathComponent == "AccountDeletion")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    // MARK: - Overwrite

    @Test("saving again replaces the checkpoint in place — one file, newest content")
    func overwrite() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())

        var advanced = fullCheckpoint()
        advanced.phase = .sourceDeleted
        advanced.lastFailure = nil
        advanced.updatedAt = 1_700_000_999_999
        try store.save(advanced)

        #expect(try store.load(userID: "u_owner") == advanced)
        #expect(contents(of: dir).count == 1, "left stray files: \(contents(of: dir))")
    }

    @Test("repeated saves leave no partial or temporary siblings behind")
    func noTemporaryResidue() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        for phase in AccountDeletionCheckpoint.Phase.allCases {
            var checkpoint = fullCheckpoint()
            checkpoint.phase = phase
            try store.save(checkpoint)
            // Every intermediate state on disk must be a complete,
            // decodable document — never a truncated write in progress.
            #expect(try store.load(userID: "u_owner")?.phase == phase)
        }
        #expect(contents(of: dir) == [store.url(forUserID: "u_owner").lastPathComponent])
    }

    // MARK: - Cancellation / removal

    @Test("clear removes the checkpoint and is idempotent")
    func clear() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())
        try store.clear(userID: "u_owner")
        #expect(try store.load(userID: "u_owner") == nil)
        #expect(contents(of: dir).isEmpty)
        // Cancelling twice (retry, or a resumed flow that already
        // finished) must not throw.
        try store.clear(userID: "u_owner")
        #expect(try store.load(userID: "u_owner") == nil)
    }

    @Test("clear on an unreadable file still removes it")
    func clearCorrupt() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())
        try Data("{ truncated".utf8).write(to: store.url(forUserID: "u_owner"))
        try store.clear(userID: "u_owner")
        #expect(try store.load(userID: "u_owner") == nil)
    }

    // MARK: - Per-user isolation

    @Test("two users keep separate checkpoints; clearing one leaves the other")
    func userIsolation() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        let owner = fullCheckpoint(userID: "u_owner")
        var other = fullCheckpoint(userID: "u_other")
        other.role = .soloOwner
        other.phase = .ownerDeletingZone

        try store.save(owner)
        try store.save(other)
        #expect(contents(of: dir).count == 2)
        #expect(try store.load(userID: "u_owner") == owner)
        #expect(try store.load(userID: "u_other") == other)

        try store.clear(userID: "u_owner")
        #expect(try store.load(userID: "u_owner") == nil)
        #expect(try store.load(userID: "u_other") == other,
                "clearing one account's checkpoint must not disturb another's")
    }

    @Test("a user id full of path separators cannot escape the store directory")
    func userIDCannotEscapeDirectory() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        let hostile = "../../etc/passwd"
        let url = store.url(forUserID: hostile)
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(!url.lastPathComponent.contains("/"))

        try store.save(AccountDeletionCheckpoint(
            userID: hostile, role: .participant, phase: .participantLeaving, updatedAt: 1))
        #expect(try store.load(userID: hostile)?.userID == hostile)
        #expect(try store.load(userID: "etc/passwd") == nil,
                "distinct ids must not collide onto one file")
        #expect(contents(of: dir).count == 1)
    }

    @Test("a checkpoint belonging to a different user fails closed instead of resuming")
    func userMismatchFailsClosed() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint(userID: "u_owner"))
        // Same bytes, other user's slot: resuming another account's
        // CloudKit deletion would delete the wrong garden.
        let stolen = try Data(contentsOf: store.url(forUserID: "u_owner"))
        try stolen.write(to: store.url(forUserID: "u_victim"))

        #expect(throws: AccountDeletionCheckpointStore.Failure.userMismatch(
            expected: "u_victim", found: "u_owner")) {
            _ = try store.load(userID: "u_victim")
        }
    }

    // MARK: - Fail-closed decoding

    @Test("corrupt checkpoint throws instead of reporting no deletion in progress")
    func corruptFailsClosed() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try Data([0xFF, 0x00, 0x01, 0x02]).write(to: store.url(forUserID: "u_owner"))

        #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: "u_owner")) {
            _ = try store.load(userID: "u_owner")
        }
    }

    @Test("truncated JSON throws, and the error never quotes the file contents")
    func truncatedFailsClosed() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())
        let whole = try Data(contentsOf: store.url(forUserID: "u_owner"))
        try whole.prefix(whole.count / 2).write(to: store.url(forUserID: "u_owner"))

        do {
            _ = try store.load(userID: "u_owner")
            Issue.record("a truncated checkpoint must not load")
        } catch let failure as AccountDeletionCheckpointStore.Failure {
            #expect(failure == .unreadable(userID: "u_owner"))
            #expect(!failure.description.contains("tr_abc123"),
                    "checkpoint errors must not echo file contents: \(failure.description)")
        }
    }

    @Test("an unknown phase on disk fails closed rather than resuming a wrong step")
    func unknownPhaseFailsClosed() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())
        let url = store.url(forUserID: "u_owner")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .replacingOccurrences(of: "\"verified\"", with: "\"teleported\"")
        try Data(text.utf8).write(to: url)

        #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: "u_owner")) {
            _ = try store.load(userID: "u_owner")
        }
    }

    @Test("a present-but-unreadable checkpoint throws instead of reading as absent")
    func unreadableFileFailsClosed() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        // A directory where the checkpoint should be: the path exists, so
        // "no file" is a lie, but the bytes cannot be read.
        try FileManager.default.createDirectory(
            at: store.url(forUserID: "u_owner"), withIntermediateDirectories: true)

        #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: "u_owner")) {
            _ = try store.load(userID: "u_owner")
        }
    }

    // MARK: - Atomicity

    @Test("the writer receives the complete document, so no partial JSON can reach disk")
    func writerReceivesCompleteDocument() throws {
        let box = CapturedWrites()
        let store = AccountDeletionCheckpointStore(
            directory: makeDirectory(),
            write: { data, url in try box.record(data, url) }
        )
        let checkpoint = fullCheckpoint()
        try store.save(checkpoint)

        #expect(box.payloads.count == 1, "save must be a single write, not an incremental stream")
        let decoded = try JSONDecoder().decode(AccountDeletionCheckpoint.self, from: try #require(box.payloads.first))
        #expect(decoded == checkpoint)
    }

    @Test("a failed replacement preserves the previous valid checkpoint")
    func failedWritePreservesPrior() throws {
        let dir = makeDirectory()
        let prior = fullCheckpoint()
        try AccountDeletionCheckpointStore(directory: dir).save(prior)

        struct DiskFull: Error {}
        let failing = AccountDeletionCheckpointStore(directory: dir, write: { _, _ in throw DiskFull() })
        var advanced = prior
        advanced.phase = .sourceDeleted

        #expect(throws: DiskFull.self) { try failing.save(advanced) }

        // The reader is the real store — the prior checkpoint must still
        // be there and still be the OLD one. Losing it would strand a
        // half-finished deletion with nothing to resume from.
        #expect(try AccountDeletionCheckpointStore(directory: dir).load(userID: "u_owner") == prior)
    }

    // MARK: - Server phase mapping

    @Test("server transfer phases map onto resumable checkpoint phases")
    func phaseMapping() {
        let expected: [(AccountDeletionTransferPhase, AccountDeletionCheckpoint.Phase?)] = [
            (.pendingSuccessor, .transferPending),
            (.successorBound, .successorBound),
            (.destinationReady, .destinationReady),
            (.ownerVerified, .ownerVerified),
            (.verified, .verified),
            (.sourceDeleted, .sourceDeleted),
            // A cancelled transfer has no resumable step: the checkpoint
            // is removed, not rewritten.
            (.cancelled, nil),
        ]
        for (server, local) in expected {
            #expect(AccountDeletionCheckpoint.Phase(transferPhase: server) == local,
                    "\(server.rawValue) mapped wrong")
        }
        #expect(expected.count == AccountDeletionTransferPhase.allCases.count,
                "a new server phase needs a mapping decision")
    }
}

/// Collects the bytes handed to the store's write seam.
private final class CapturedWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var payloads: [Data] { lock.withLock { storage } }

    func record(_ data: Data, _ url: URL) throws {
        lock.withLock { storage.append(data) }
        try data.write(to: url, options: .atomic)
    }
}
