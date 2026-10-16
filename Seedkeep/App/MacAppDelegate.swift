#if os(macOS)
import AppKit
import CloudKit

/// Receives CloudKit share acceptance on macOS and routes it through AppEnvironment.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        MacPendingShareQueue.shared.deposit(metadata)
        Task { @MainActor in await processPendingShares() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await processPendingShares() }
    }

    /// A share can only be drained after restore has resolved the authenticated identity.
    func processPendingShares() async {
        guard let environment, case .signedIn = environment.auth.state else { return }
        await environment.processPendingShare()
    }
}
#endif
