#if canImport(CloudKit)
import CloudKit
import UIKit

/// Receives CKShare acceptance for the SwiftUI-lifecycle app. The deprecated
/// `application(_:userDidAcceptCloudKitShareWith:)` does NOT fire for `WindowGroup` apps, so the
/// scene delegate is wired via `UISceneConfiguration` (see `SeedkeepAppDelegate`). It never creates
/// or assigns a `window` — SwiftUI's `WindowGroup` owns the scene's content; this only captures the
/// share metadata and routes it through `PendingShareInbox`. Ported from SimmerSmith's ShareSceneDelegate.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the app was terminated when the user tapped the share link. Metadata rides in on
    /// the connection options; stash it for AppEnvironment to drain once it's constructed.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in PendingShareInbox.shared.deposit(metadata) }
        }
        // Cold-launch invite links: this custom scene delegate replaces SwiftUI's, which can suppress
        // .onOpenURL / .onContinueUserActivity — so forward both ways' URLs to the invite router.
        let coldURLs = connectionOptions.urlContexts.map(\.url)
            + connectionOptions.userActivities.compactMap(\.webpageURL)
        if !coldURLs.isEmpty { forwardURLs(coldURLs) }
    }

    /// Warm custom-scheme open (e.g. seedkeep://invite/<code>).
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        forwardURLs(URLContexts.map(\.url))
    }

    /// Warm universal-link open (https://seedkeep.app/invite/<code>).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { forwardURLs([url]) }
    }

    private func forwardURLs(_ urls: [URL]) {
        Task { @MainActor in
            let environment = (UIApplication.shared.delegate as? SeedkeepAppDelegate)?.environment
            for url in urls { environment?.routeIncomingURL(url) }
        }
    }

    /// Warm tap: the app was running. Deposit + process immediately so an already-booted owner
    /// coordinator can swap to the participant household.
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            PendingShareInbox.shared.deposit(cloudKitShareMetadata)
            let environment = (UIApplication.shared.delegate as? SeedkeepAppDelegate)?.environment
            await environment?.processPendingShare()
        }
    }
}
#endif
