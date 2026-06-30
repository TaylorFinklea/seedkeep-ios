import UIKit

/// Minimal `UIApplicationDelegate` adopted via `@UIApplicationDelegateAdaptor` on `SeedkeepApp`.
/// Seedkeep is otherwise a pure SwiftUI-lifecycle app; the delegate exists ONLY to route every scene
/// through `ShareSceneDelegate` so CKShare acceptance is delivered (the SwiftUI `WindowGroup` lifecycle
/// does NOT surface `userDidAcceptCloudKitShareWith` on the app delegate). It holds a reference to the
/// live `AppEnvironment` so the scene delegate can drive the participant-adopt flow on a warm tap.
final class SeedkeepAppDelegate: NSObject, UIApplicationDelegate {
    /// Injected by `SeedkeepApp` once the environment is built.
    @MainActor var environment: AppEnvironment?

    #if canImport(CloudKit)
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShareSceneDelegate.self   // captures CKShare metadata only; SwiftUI owns the UI
        return config
    }
    #endif
}
