import SwiftUI
import SeedkeepKit

/// "You" tab — identity, household, sign out. Phase 1's bare necessities.
struct YouView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv
    @State private var inviteCode: String?
    @State private var isCreatingInvite = false
    @State private var inviteError: String?

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
                        LabeledContent("ID", value: household.id)
                            .font(.caption.monospaced())
                    }
                    Section("Invite") {
                        if let code = inviteCode {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Share this code")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(code)
                                    .font(.title3.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Button {
                                Task { await createInvite() }
                            } label: {
                                HStack {
                                    Text("Create invite link")
                                    if isCreatingInvite { ProgressView().controlSize(.small) }
                                }
                            }
                            .disabled(isCreatingInvite)
                        }
                        if let inviteError {
                            Text(inviteError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
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

    private func createInvite() async {
        isCreatingInvite = true
        inviteError = nil
        defer { isCreatingInvite = false }
        do {
            let res = try await appEnv.client.createInvite()
            inviteCode = res.invite.code
        } catch let err as SeedkeepError {
            inviteError = "\(err.code): \(err.message)"
        } catch {
            inviteError = error.localizedDescription
        }
    }
}
