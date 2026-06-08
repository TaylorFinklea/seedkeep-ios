import SwiftUI

/// Lets the user point the app at a different Seedkeep server (the
/// official cloud host by default, or any self-hosted instance reachable
/// from the device). Saving validates the URL by hitting `/api/health`
/// before persisting.
///
/// Why this lives in Settings: the server is decoupled from the iOS app
/// (Phase 1 architecture pivot — we ship a portable Bun + Postgres + S3
/// backend that anyone can self-host). Without an in-app picker, the
/// only way to switch servers would be a rebuild.
struct ServerSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @State private var draftURLText: String = ""
    @State private var validating = false
    @State private var errorText: String?
    @State private var savedSuccessfully = false

    var body: some View {
        Form {
            Section {
                TextField("https://api.example.com", text: $draftURLText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server URL")
            } footer: {
                Text("The base URL for the Seedkeep API. Saving validates the URL by calling /api/health.")
            }

            Section("Current") {
                LabeledContent("Active") {
                    Text(appEnv.preferences.effectiveServerURL.absoluteString)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Default") {
                    Text(appEnv.preferences.bundleDefault.absoluteString)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if !appEnv.preferences.isUsingDefaultServer {
                    Button("Reset to default", role: .destructive) {
                        Task { await reset() }
                    }
                }
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(HerbColor.rose)
                }
            } else if savedSuccessfully {
                Section {
                    Label("Server reachable. Saved.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(HerbColor.sage)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(validating || draftURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if draftURLText.isEmpty {
                draftURLText = appEnv.preferences.effectiveServerURL.absoluteString
            }
        }
    }

    private func save() async {
        let trimmed = draftURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            errorText = "Enter a full URL with http:// or https://"
            savedSuccessfully = false
            return
        }
        errorText = nil
        savedSuccessfully = false
        validating = true
        defer { validating = false }
        if let problem = await appEnv.setServerURL(url) {
            errorText = problem
            return
        }
        savedSuccessfully = true
        // Refresh tier immediately — the new server may report a
        // different tier (free vs hosted) for this user.
        await appEnv.refreshTier()
    }

    private func reset() async {
        await appEnv.resetServerURLToDefault()
        draftURLText = appEnv.preferences.bundleDefault.absoluteString
        errorText = nil
        savedSuccessfully = true
        await appEnv.refreshTier()
    }
}
