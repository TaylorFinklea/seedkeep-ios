import SwiftUI
import SeedkeepKit

/// Identity tab — who am I, who is my household, sign out. Locations, Tags,
/// and the household-invite flow live in the Settings tab now.
struct YouView: View {
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            Form {
                if case .signedIn(let user, let household) = auth.state {
                    Section("You") {
                        LabeledContent("Email", value: user.email ?? "—")
                        LabeledContent("Name", value: user.name ?? "—")
                    }
                    Section("Household") {
                        LabeledContent("Name", value: household.name)
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }
            }
            .navigationTitle("You")
        }
    }
}
