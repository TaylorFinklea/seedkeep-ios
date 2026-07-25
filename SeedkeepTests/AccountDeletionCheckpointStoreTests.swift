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
/// pinned on four properties:
///
///   1. Durable and atomic: a crash mid-write never leaves half a JSON
///      document, and a failed replacement leaves the PREVIOUS checkpoint
///      intact rather than nothing.
///   2. Ordered by the store: every write presents the lease issued by the
///      previous one, so a delayed write is rejected regardless of the
///      timestamp it carries or the direction its phase moved.
///   3. Fail-closed: an unreadable or foreign checkpoint throws — on read
///      AND on write. Only an explicit `clear` removes one.
///   4. Per-user: one signed-in account's checkpoint can never be read,
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
        #expect(try store.load(userID: "u_owner")?.checkpoint == checkpoint)
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
        let loaded = try #require(try store.load(userID: "u_part")).checkpoint
        #expect(loaded == checkpoint)
        #expect(loaded.transferID == nil)
        #expect(loaded.sourceZoneName == nil)
        #expect(loaded.destinationZoneName == nil)
        #expect(loaded.lastFailure == nil)
    }

    @Test("a successor's checkpoint round-trips and carries the transfer id")
    func roundTripSuccessor() throws {
        // Accepting the handoff consumed a single-use token: if the
        // successor's device is killed here, re-opening the link cannot
        // recover the transfer. Only this file can.
        let store = AccountDeletionCheckpointStore(directory: makeDirectory())
        let checkpoint = AccountDeletionCheckpoint(
            userID: "u_succ",
            role: .successor,
            phase: .destinationZoneCreated,
            transferID: "tr_abc123",
            sourceZoneName: "household-hh_1",
            sourceZoneOwnerName: "_owner_name",
            destinationZoneName: "household-hh_1",
            destinationZoneOwnerName: "__defaultOwner__",
            updatedAt: 99
        )
        try store.save(checkpoint)
        let loaded = try #require(try store.load(userID: "u_succ")).checkpoint
        #expect(loaded == checkpoint)
        #expect(loaded.role == .successor)
        #expect(loaded.transferID == "tr_abc123")
    }

    @Test("every phase survives a round trip, including the local-only crash windows")
    func roundTripEveryPhase() throws {
        let store = AccountDeletionCheckpointStore(directory: makeDirectory())
        var lease: AccountDeletionCheckpointStore.Lease?
        for phase in AccountDeletionCheckpoint.Phase.allCases {
            var checkpoint = fullCheckpoint()
            checkpoint.phase = phase
            lease = try store.save(checkpoint, lease: lease)
            #expect(try store.load(userID: "u_owner")?.checkpoint == checkpoint,
                    "\(phase.rawValue) did not survive")
        }
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
        let lease = try store.save(fullCheckpoint())

        var advanced = fullCheckpoint()
        advanced.phase = .sourceDeleted
        advanced.lastFailure = nil
        advanced.updatedAt = 1_700_000_999_999
        try store.save(advanced, lease: lease)

        #expect(try store.load(userID: "u_owner")?.checkpoint == advanced)
        #expect(contents(of: dir).count == 1, "left stray files: \(contents(of: dir))")
    }

    @Test("repeated saves leave no partial or temporary siblings behind")
    func noTemporaryResidue() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        var lease: AccountDeletionCheckpointStore.Lease?
        for phase in AccountDeletionCheckpoint.Phase.allCases {
            var checkpoint = fullCheckpoint()
            checkpoint.phase = phase
            lease = try store.save(checkpoint, lease: lease)
            // Every intermediate state on disk must be a complete,
            // decodable document — never a truncated write in progress.
            #expect(try store.load(userID: "u_owner")?.checkpoint.phase == phase)
        }
        #expect(contents(of: dir) == [store.url(forUserID: "u_owner").lastPathComponent])
    }

    // MARK: - Ordering: store-issued leases, not caller clocks

    @Test("a spent lease is rejected even when the delayed write carries the same timestamp")
    func spentLeaseRejectedAtEqualTimestamp() throws {
        // The regression a timestamp watermark cannot catch: two writes
        // stamped in the same millisecond, the later one carrying an
        // EARLIER phase.
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        var advanced = fullCheckpoint()
        advanced.phase = .sourceDeleted
        let first = try store.save(advanced)

        var next = advanced
        next.phase = .deletingAccount
        _ = try store.save(next, lease: first)

        var regression = advanced
        regression.phase = .destinationReady
        #expect(regression.updatedAt == next.updatedAt, "the point of this test is an identical stamp")
        #expect(throws: AccountDeletionCheckpointStore.Failure.staleSave(userID: "u_owner")) {
            try store.save(regression, lease: first)
        }
        #expect(try store.load(userID: "u_owner")?.checkpoint.phase == .deletingAccount,
                "a spent lease must not rewind the phase")
    }

    @Test("a delayed write after clear is rejected even with a newer timestamp")
    func delayedWriteAfterClearRejected() throws {
        // The other regression a watermark cannot catch: the resurrecting
        // write is NEWER than everything the store ever saw.
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        let lease = try store.save(fullCheckpoint())
        try store.clear(userID: "u_owner")

        var late = fullCheckpoint()
        late.phase = .deletingAccount
        late.updatedAt = 9_999_999_999_999
        #expect(throws: AccountDeletionCheckpointStore.Failure.staleSave(userID: "u_owner")) {
            try store.save(late, lease: lease)
        }
        #expect(try store.load(userID: "u_owner") == nil, "a cleared deletion must stay cleared")
        #expect(contents(of: dir).isEmpty)
    }

    @Test("a write without a lease cannot replace an existing checkpoint")
    func leaselessWriteCannotReplace() throws {
        // Covers the cross-launch case: a checkpoint left by an earlier
        // run must be loaded (and thus seen) before it can be replaced.
        let dir = makeDirectory()
        let onDisk = fullCheckpoint()
        try JSONEncoder().encode(onDisk).write(
            to: AccountDeletionCheckpointStore(directory: dir).url(forUserID: "u_owner"))

        let store = AccountDeletionCheckpointStore(directory: dir)
        var blind = fullCheckpoint()
        blind.phase = .transferPending
        #expect(throws: AccountDeletionCheckpointStore.Failure.staleSave(userID: "u_owner")) {
            try store.save(blind)
        }
        #expect(try store.load(userID: "u_owner")?.checkpoint == onDisk)

        // Loading yields the lease that authorizes the replacement.
        let lease = try #require(try store.load(userID: "u_owner")).lease
        try store.save(blind, lease: lease)
        #expect(try store.load(userID: "u_owner")?.checkpoint == blind)
    }

    @Test("a genuinely new deletion after a clear is accepted")
    func newDeletionAfterClearAccepted() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())
        try store.clear(userID: "u_owner")

        var restarted = fullCheckpoint()
        restarted.phase = .transferPending
        try store.save(restarted)
        #expect(try store.load(userID: "u_owner")?.checkpoint == restarted)
    }

    @Test("concurrent saves serialize: exactly one wins each generation, the file stays valid")
    func concurrentSaves() async throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        let lease = try store.save(fullCheckpoint())
        let phases: [AccountDeletionCheckpoint.Phase] = [
            .destinationShareAccepted, .copyComplete, .ownerVerified,
            .verified, .sourceZoneDeleted, .sourceDeleted, .deletingAccount,
        ]

        // Every task holds the SAME lease, so exactly one may win.
        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for phase in phases {
                group.addTask {
                    var checkpoint = self.fullCheckpoint()
                    checkpoint.phase = phase
                    do { _ = try store.save(checkpoint, lease: lease); return true } catch { return false }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }

        #expect(winners == 1, "a lease authorizes exactly one write, got \(winners)")
        let loaded = try #require(try store.load(userID: "u_owner")).checkpoint
        #expect(phases.contains(loaded.phase))
        #expect(contents(of: dir).count == 1, "concurrent saves left residue: \(contents(of: dir))")
    }

    @Test("concurrent clears are all idempotent — no loser throws")
    func concurrentClears() async throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        try store.save(fullCheckpoint())

        let failures = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<8 {
                group.addTask {
                    do { try store.clear(userID: "u_owner"); return false } catch { return true }
                }
            }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }

        #expect(failures == 0, "a losing clear must not turn a successful cancellation into a failure")
        #expect(try store.load(userID: "u_owner") == nil)
        #expect(contents(of: dir).isEmpty)
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

    @Test("clear is the only operation that removes a checkpoint the store cannot decode")
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
        #expect(try store.load(userID: "u_owner")?.checkpoint == owner)
        #expect(try store.load(userID: "u_other")?.checkpoint == other)

        try store.clear(userID: "u_owner")
        #expect(try store.load(userID: "u_owner") == nil)
        #expect(try store.load(userID: "u_other")?.checkpoint == other,
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
        #expect(try store.load(userID: hostile)?.checkpoint.userID == hostile)
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

    // MARK: - Fail-closed writing

    @Test("save refuses to overwrite a corrupt checkpoint and leaves the bytes untouched")
    func saveRefusesCorruptDestination() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        let destination = store.url(forUserID: "u_owner")
        let damaged = Data("{ half a document".utf8)
        try damaged.write(to: destination)

        #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: "u_owner")) {
            try store.save(fullCheckpoint())
        }
        #expect(try Data(contentsOf: destination) == damaged,
                "a damaged checkpoint is evidence of a failed deletion; only clear may remove it")
        #expect(contents(of: dir) == [destination.lastPathComponent], "left scratch residue")

        // The documented escape hatch.
        try store.clear(userID: "u_owner")
        try store.save(fullCheckpoint())
        #expect(try store.load(userID: "u_owner")?.checkpoint == fullCheckpoint())
    }

    @Test("save refuses to overwrite another account's checkpoint")
    func saveRefusesForeignDestination() throws {
        let dir = makeDirectory()
        let store = AccountDeletionCheckpointStore(directory: dir)
        // A valid checkpoint for u_owner sitting in u_victim's slot.
        let foreign = try JSONEncoder().encode(fullCheckpoint(userID: "u_owner"))
        let destination = store.url(forUserID: "u_victim")
        try foreign.write(to: destination)

        #expect(throws: AccountDeletionCheckpointStore.Failure.userMismatch(
            expected: "u_victim", found: "u_owner")) {
            try store.save(fullCheckpoint(userID: "u_victim"))
        }
        #expect(try Data(contentsOf: destination) == foreign)
    }

    @Test("a rejected save never reaches the write seam")
    func rejectedSaveDoesNoIO() throws {
        let dir = makeDirectory()
        let recorder = WriteRecorder()
        let store = AccountDeletionCheckpointStore(
            directory: dir,
            writer: .init(
                writeTemporary: { data, url in try recorder.recordWrite(data, url) },
                replace: { source, destination in try recorder.recordReplace(source, destination) }
            )
        )
        try Data("{ broken".utf8).write(to: store.url(forUserID: "u_owner"))

        #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: "u_owner")) {
            try store.save(fullCheckpoint())
        }
        #expect(recorder.writeCount == 0, "validation must happen before any bytes are written")
    }

    // MARK: - Atomicity

    @Test("a save writes a scratch file first and never opens the destination directly")
    func saveWritesScratchThenReplaces() throws {
        let dir = makeDirectory()
        let recorder = WriteRecorder()
        let store = AccountDeletionCheckpointStore(
            directory: dir,
            writer: .init(
                writeTemporary: { data, url in try recorder.recordWrite(data, url) },
                replace: { source, destination in try recorder.recordReplace(source, destination) }
            )
        )
        let checkpoint = fullCheckpoint()
        try store.save(checkpoint)

        let destination = store.url(forUserID: "u_owner")
        let scratch = try #require(recorder.writtenURL)
        #expect(scratch != destination,
                "bytes must land in a scratch file — writing the destination in place is not atomic")
        #expect(scratch.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
                "the scratch file must share the destination's filesystem for rename to be atomic")
        #expect(recorder.replaced?.destination == destination)
        #expect(recorder.replaced?.source == scratch)

        // One complete document, encoded before any file I/O.
        let payload = try #require(recorder.writtenData)
        #expect(try JSONDecoder().decode(AccountDeletionCheckpoint.self, from: payload) == checkpoint)
        #expect(recorder.writeCount == 1, "save must be a single write, not an incremental stream")
    }

    @Test("a failure between the scratch write and the replacement preserves the prior bytes")
    func failedReplacePreservesPrior() throws {
        let dir = makeDirectory()
        let prior = fullCheckpoint()
        let lease = try AccountDeletionCheckpointStore(directory: dir).save(prior)
        let destination = AccountDeletionCheckpointStore(directory: dir).url(forUserID: "u_owner")
        let priorBytes = try Data(contentsOf: destination)

        // The scratch write SUCCEEDS — this is the window a non-atomic
        // in-place write would already have destroyed the destination in.
        struct DiskFull: Error {}
        let failing = AccountDeletionCheckpointStore(
            directory: dir,
            writer: .init(
                writeTemporary: { data, url in try data.write(to: url, options: .atomic) },
                replace: { _, _ in throw DiskFull() }
            )
        )
        var advanced = prior
        advanced.phase = .deletingAccount

        #expect(throws: DiskFull.self) { try failing.save(advanced, lease: lease) }

        #expect(try Data(contentsOf: destination) == priorBytes,
                "the previous checkpoint must survive a failed replacement byte for byte")
        #expect(try AccountDeletionCheckpointStore(directory: dir)
            .load(userID: "u_owner")?.checkpoint == prior)
        #expect(contents(of: dir) == [destination.lastPathComponent],
                "a failed save must not leave scratch files behind: \(contents(of: dir))")
    }

    // MARK: - Role, party, and disposition

    @Test("transfer party is derived from the role, so the two can never disagree")
    func transferParty() {
        var checkpoint = fullCheckpoint()
        checkpoint.role = .sharedOwner
        #expect(checkpoint.transferParty == .owner)
        #expect(checkpoint.deletesOwnAccount)

        checkpoint.role = .successor
        #expect(checkpoint.transferParty == .successor)
        #expect(!checkpoint.deletesOwnAccount,
                "a successor is finishing someone else's handoff, not deleting an account")

        for role: AccountDeletionCheckpoint.Role in [.participant, .soloOwner, .noCloudKitGarden] {
            checkpoint.role = role
            #expect(checkpoint.transferParty == nil)
            #expect(checkpoint.deletesOwnAccount)
        }
    }

    @Test("each role claims exactly the CloudKit disposition it can honestly prove")
    func dispositionMapping() {
        var checkpoint = fullCheckpoint()
        checkpoint.phase = .deletingAccount

        checkpoint.role = .noCloudKitGarden
        #expect(checkpoint.disposition == .noCloudKitGarden)
        checkpoint.role = .participant
        #expect(checkpoint.disposition == .participantLeftShare)
        checkpoint.role = .soloOwner
        #expect(checkpoint.disposition == .ownerZoneDeleted)
        checkpoint.role = .sharedOwner
        #expect(checkpoint.disposition == .transferSourceDeleted(transferID: "tr_abc123"))
        checkpoint.role = .successor
        #expect(checkpoint.disposition == nil)
    }

    @Test("no role may claim a disposition before the account-deletion step itself")
    func dispositionOnlyAtDeletingAccount() {
        // The disposition asserts the CloudKit work is DONE. Any earlier
        // phase means it is not, whatever the role — including the roles
        // whose CloudKit work is a single step.
        for role in AccountDeletionCheckpoint.Role.allCases {
            for phase in AccountDeletionCheckpoint.Phase.allCases where phase != .deletingAccount {
                var checkpoint = fullCheckpoint()
                checkpoint.role = role
                checkpoint.phase = phase
                #expect(checkpoint.disposition == nil,
                        "\(role.rawValue) at \(phase.rawValue) must not authorize account deletion")
            }
        }
    }

    @Test("a shared owner that lost its transfer id fails closed at the deletion step")
    func dispositionRequiresTransferID() {
        var checkpoint = fullCheckpoint()
        checkpoint.role = .sharedOwner
        checkpoint.phase = .deletingAccount
        #expect(checkpoint.disposition == .transferSourceDeleted(transferID: "tr_abc123"))

        // Never fall back to a simpler disposition the server would accept.
        checkpoint.transferID = nil
        #expect(checkpoint.disposition == nil)
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

    @Test("local-only phases report the server phase they sit inside")
    func impliedTransferPhase() {
        let expected: [(AccountDeletionCheckpoint.Phase, AccountDeletionTransferPhase?)] = [
            (.participantLeaving, nil),
            (.ownerDeletingZone, nil),
            (.transferPending, .pendingSuccessor),
            (.successorBound, .successorBound),
            (.destinationZoneCreated, .successorBound),
            (.destinationReady, .destinationReady),
            (.destinationShareAccepted, .destinationReady),
            (.copyComplete, .destinationReady),
            (.ownerVerified, .ownerVerified),
            (.verified, .verified),
            (.sourceZoneDeleted, .verified),
            (.sourceDeleted, .sourceDeleted),
            (.deletingAccount, nil),
        ]
        for (local, server) in expected {
            #expect(local.impliedTransferPhase == server, "\(local.rawValue) mapped wrong")
        }
        #expect(expected.count == AccountDeletionCheckpoint.Phase.allCases.count,
                "a new local phase needs a server-phase decision")
    }
}

/// Records what the store handed to each half of its write seam.
private final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(data: Data, url: URL)] = []
    private var replacement: (source: URL, destination: URL)?

    var writeCount: Int { lock.withLock { writes.count } }
    var writtenURL: URL? { lock.withLock { writes.first?.url } }
    var writtenData: Data? { lock.withLock { writes.first?.data } }
    var replaced: (source: URL, destination: URL)? { lock.withLock { replacement } }

    func recordWrite(_ data: Data, _ url: URL) throws {
        lock.withLock { writes.append((data, url)) }
        try data.write(to: url, options: .atomic)
    }

    func recordReplace(_ source: URL, _ destination: URL) throws {
        lock.withLock { replacement = (source, destination) }
        try AccountDeletionCheckpointStore.FileWriter.atomicReplace.replace(source, destination)
    }
}
