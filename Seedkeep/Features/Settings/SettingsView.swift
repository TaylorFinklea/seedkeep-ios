import SwiftUI
import SeedkeepKit

/// Root Settings tab. Hosts Locations + Tags CRUD plus the household
/// invite flow that used to live in the You tab.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth

    @State private var inviteCode: String?
    @State private var isCreatingInvite = false
    @State private var inviteError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Inventory") {
                    NavigationLink {
                        LocationsView()
                    } label: {
                        Label("Locations", systemImage: "tray")
                    }
                    NavigationLink {
                        TagsView()
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                }

                if case .signedIn(_, let household) = auth.state {
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

                Section("Sync") {
                    Button {
                        Task { await appEnv.syncIfPossible() }
                    } label: {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                    if let err = appEnv.sync.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
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
