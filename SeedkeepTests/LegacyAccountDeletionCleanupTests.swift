import Foundation
import Testing
@testable import Seedkeep

/// N3: the launch-time removal of the files the removed account deletion and transfer left
/// behind, and the incoming-link router that no longer knows garden handoff links. That the rest
/// of the device is untouched and CloudKit is not paused is in `AppEnvironmentGateTests`.
@Suite("Legacy account-deletion cleanup", .serialized)
struct LegacyAccountDeletionCleanupTests {
    private struct Dirs {
        let root: URL
        var checkpoints: URL { root.appendingPathComponent("AccountDeletion", isDirectory: true) }
        var sync: URL { root.appendingPathComponent("HouseholdSync", isDirectory: true) }
        func path(_ relative: String) -> String { sync.appendingPathComponent(relative).path }
    }

    /// A legacy checkpoint directory (a checkpoint, a damaged file and a scratch file) and a
    /// `HouseholdSync` directory holding every photo lifetime and an engine-state file.
    private static func makeDirs() throws -> Dirs {
        let dirs = Dirs(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCleanup-\(UUID().uuidString)", isDirectory: true))
        let fm = FileManager.default
        try fm.createDirectory(at: dirs.checkpoints, withIntermediateDirectories: true)
        try Data(#"{"user_id":"u","role":"solo_owner","phase":"deleting_account","updated_at":1}"#.utf8)
            .write(to: dirs.checkpoints.appendingPathComponent("checkpoint-dQ.json"))
        try Data("{".utf8).write(to: dirs.checkpoints.appendingPathComponent("checkpoint-ZA.json"))
        try Data("partial".utf8).write(to: dirs.checkpoints.appendingPathComponent(".checkpoint-dQ.json.1.tmp"))
        for lifetime in PhotoByteStore.Lifetime.allCases {
            let dir = dirs.sync.appendingPathComponent("\(lifetime.rawValue)/production/hh_a", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("jpeg".utf8).write(to: dir.appendingPathComponent("seedPhoto_p1.abc.jpg"))
        }
        try Data("x".utf8).write(to: dirs.sync.appendingPathComponent("engine-state-production-hh_a.json"))
        return dirs
    }

    private static func remove(_ dirs: Dirs) { try? FileManager.default.removeItem(at: dirs.root) }

    @Test("removes the checkpoint directory and TransferWorkspace only, idempotently")
    func removesOnlyLegacyFiles() throws {
        let dirs = try Self.makeDirs()
        defer { Self.remove(dirs) }

        #expect(LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: true, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync))
        #expect(LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: true, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync),
            "a second run finds nothing and succeeds")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dirs.checkpoints.path))
        #expect(!fm.fileExists(atPath: dirs.path("TransferWorkspace")))
        #expect(fm.fileExists(atPath: dirs.path("PendingUploads/production/hh_a/seedPhoto_p1.abc.jpg")))
        #expect(fm.fileExists(atPath: dirs.path("PhotoCache/production/hh_a/seedPhoto_p1.abc.jpg")))
        #expect(fm.fileExists(atPath: dirs.path("engine-state-production-hh_a.json")))
    }

    @Test("with nothing to remove it succeeds without creating anything")
    func noLegacyFilesIsANoOp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCleanup-empty-\(UUID().uuidString)", isDirectory: true)
        let dirs = Dirs(root: root)
        #expect(LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: true, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a removal that fails is reported and succeeds on the next launch's retry")
    func failedRemovalIsRetried() throws {
        let dirs = try Self.makeDirs()
        let fm = FileManager.default
        // A read-only directory can't have its files removed.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dirs.checkpoints.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirs.checkpoints.path)
            Self.remove(dirs)
        }

        #expect(!LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: true, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync))
        #expect(fm.fileExists(atPath: dirs.checkpoints.path), "left for the next launch")
        #expect(!fm.fileExists(atPath: dirs.path("TransferWorkspace")), "one failure doesn't stop the other removal")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirs.checkpoints.path)
        #expect(LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: true, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync))
        #expect(!fm.fileExists(atPath: dirs.checkpoints.path))
    }

    @Test("inert unless enabled; the unit-test host never enables it")
    func inertWhenDisabled() throws {
        let dirs = try Self.makeDirs()
        defer { Self.remove(dirs) }

        #expect(!LegacyAccountDeletionCleanup.removeLegacyFiles(
            enabled: false, checkpointDirectory: dirs.checkpoints, householdSyncDirectory: dirs.sync))
        #expect(FileManager.default.fileExists(atPath: dirs.checkpoints.path))
        #expect(FileManager.default.fileExists(atPath: dirs.path("TransferWorkspace")))
        // `live()` passes `canRunLiveAppStartup`, which is false in this host. Sample-garden mode
        // returns from `live()` (to `makeForFixture`) before the call.
        #expect(!FeatureFlags.canRunLiveAppStartup)
    }

    @Test("invite links still route; garden handoff links route nowhere")
    func incomingLinkRouting() {
        #expect(IncomingLink(url: URL(string: "https://seedkeep.app/invite/code99")!) == .invite(code: "code99"))
        #expect(IncomingLink(url: URL(string: "seedkeep://invite/code42")!) == .invite(code: "code42"))
        #expect(IncomingLink(url: URL(string: "https://seedkeep.app/garden-handoff/tr_42?token=abc")!) == nil)
        #expect(IncomingLink(url: URL(string: "seedkeep://garden-handoff/tr_42?token=abc")!) == nil)
        #expect(IncomingLink(url: URL(string: "https://seedkeep.app/")!) == nil)
        #expect(IncomingLink(url: URL(string: "https://www.icloud.com/share/0abc")!) == nil)
    }
}
