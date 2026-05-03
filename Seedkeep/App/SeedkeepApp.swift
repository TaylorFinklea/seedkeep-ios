import SwiftUI
import SwiftData
import SeedkeepKit

@main
struct SeedkeepApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.auth)
                .modelContainer(environment.container)
                .task {
                    await environment.auth.restoreSession()
                }
        }
    }
}

struct RootView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        switch auth.state {
        case .signedOut, .failed:
            SignInView()
        case .authenticating:
            ProgressView("Signing you in…")
                .progressViewStyle(.circular)
        case .signedIn:
            MainTabView()
                .task(id: snapshotID(auth.state)) {
                    await appEnv.syncIfPossible()
                }
        }
    }

    /// Stable identity for the `.task(id:)` so we kick a sync once per
    /// sign-in transition and not every state mutation.
    private func snapshotID(_ state: AuthController.State) -> String {
        switch state {
        case .signedIn(_, let household): return "signedIn:\(household.id)"
        case .signedOut: return "signedOut"
        case .authenticating: return "authenticating"
        case .failed(let m): return "failed:\(m)"
        }
    }
}
