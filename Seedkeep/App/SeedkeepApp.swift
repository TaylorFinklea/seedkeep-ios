import SwiftUI
import SwiftData
import SeedkeepKit

@main
struct SeedkeepApp: App {
    @State private var environment = AppEnvironment.live()
    @State private var pendingInviteCode: String?

    var body: some Scene {
        WindowGroup {
            RootView(pendingInviteCode: $pendingInviteCode)
                .environment(environment)
                .environment(environment.auth)
                .modelContainer(environment.container)
                .task {
                    await environment.auth.restoreSession()
                }
                .onOpenURL { url in
                    if let code = InviteURLRouter.invitationCode(from: url) {
                        pendingInviteCode = code
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL,
                       let code = InviteURLRouter.invitationCode(from: url) {
                        pendingInviteCode = code
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv
    @Binding var pendingInviteCode: String?

    var body: some View {
        ZStack {
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
        .sheet(item: Binding(
            get: { pendingInviteCode.map { InviteRoute(code: $0) } },
            set: { newValue in pendingInviteCode = newValue?.code }
        )) { route in
            // Only present invite acceptance once the user is signed in;
            // otherwise the API call fails. The sheet shows the
            // confirmation step so the user can read the code while
            // the auth flow finishes.
            if case .signedIn = auth.state {
                InviteAcceptView(code: route.code)
            } else {
                signedOutInviteView(code: route.code)
            }
        }
    }

    @ViewBuilder
    private func signedOutInviteView(code: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tint)
            Text("Sign in first")
                .font(.title2.weight(.semibold))
            Text("Sign in with Apple to accept the invite for code \(code).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("OK") {
                pendingInviteCode = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .presentationDetents([.medium])
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

private struct InviteRoute: Identifiable {
    let code: String
    var id: String { code }
}
