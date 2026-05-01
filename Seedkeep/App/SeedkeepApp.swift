import SwiftUI
import SeedkeepKit

@main
struct SeedkeepApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.auth)
                .task {
                    await environment.auth.restoreSession()
                }
        }
    }
}

struct RootView: View {
    @Environment(AuthController.self) private var auth

    var body: some View {
        switch auth.state {
        case .signedOut, .failed:
            SignInView()
        case .authenticating:
            ProgressView("Signing you in…")
                .progressViewStyle(.circular)
        case .signedIn:
            MainTabView()
        }
    }
}
