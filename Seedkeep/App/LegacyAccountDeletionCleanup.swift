import Foundation
import OSLog

/// N3: removes the files the removed account deletion and garden transfer left on disk.
///
/// Older builds kept account-deletion checkpoints as JSON files in
/// `Application Support/AccountDeletion` (plus scratch files from atomic writes) and staged
/// transfer photo bytes in `HouseholdSync/TransferWorkspace`. Nothing reads either any more. The
/// owner confirmed no device ever started an account deletion or transfer, so these files carry
/// no state worth acting on: they are deleted, whatever they contain, and nothing else changes —
/// no erase, no identity or garden change, and CloudKit is never paused.
///
/// Best effort and idempotent. A failure is logged and the next launch tries again.
enum LegacyAccountDeletionCleanup {
    /// `~/Library/Application Support/AccountDeletion`, where older builds kept checkpoints.
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDeletion", isDirectory: true)
    }

    static let log = Logger(subsystem: "app.seedkeep", category: "LegacyDeletionCleanup")

    /// Removes `checkpointDirectory` (every file in it, damaged and scratch files included) and
    /// `householdSyncDirectory/TransferWorkspace`. Does nothing unless `enabled`: live launches
    /// pass `FeatureFlags.canRunLiveAppStartup`, so the unit-test host, which shares the real
    /// app's data, never runs it. Returns true when nothing is left to remove.
    @discardableResult
    static func removeLegacyFiles(
        enabled: Bool,
        checkpointDirectory: URL = defaultDirectory,
        householdSyncDirectory: URL = HouseholdCloudCoordinator.householdSyncDirURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard enabled else { return false }
        let transferWorkspace = householdSyncDirectory.appendingPathComponent(
            PhotoByteStore.Lifetime.transferWorkspace.rawValue, isDirectory: true)
        var removedAll = true
        for url in [checkpointDirectory, transferWorkspace] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                removedAll = false
                log.error("could not remove legacy \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return removedAll
    }
}
