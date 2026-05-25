import SwiftUI
import SeedkeepKit

/// Settings → AI Assistant. Lets the user paste their Anthropic API key
/// (write-only — never displayed back), replace it, or revoke. Privacy
/// disclosure explains that the key is encrypted on Seedkeep's server.
struct AssistantKeySettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var keyInput: String = ""
    @State private var showingReplaceField: Bool = false
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            if appEnv.assistant.keyConfigured && !showingReplaceField {
                Section {
                    Label("Anthropic key configured", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Replace key") {
                        showingReplaceField = true
                    }
                    Button("Revoke key", role: .destructive) {
                        Task { await revoke() }
                    }
                    .disabled(working)
                }
            } else {
                Section("Anthropic API key") {
                    SecureField("sk-ant-…", text: $keyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(working ? "Saving…" : "Save key") {
                        Task { await save() }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    if showingReplaceField {
                        Button("Cancel", role: .cancel) {
                            showingReplaceField = false
                            keyInput = ""
                        }
                    }
                }
            }

            Section("Privacy") {
                Text("Your API key is encrypted with AES-256-GCM and stored on Seedkeep's server. We use it to make Anthropic calls on your behalf when you talk to Sprout. The key is never displayed back to you after saving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Cost: Anthropic bills you directly through their API. Seedkeep doesn't add fees.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let infoMessage {
                Section { Text(infoMessage).font(.footnote).foregroundStyle(.green) }
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .task { await appEnv.assistant.refreshKeyStatus() }
    }

    // MARK: - Actions

    private func save() async {
        working = true
        defer { working = false }
        errorMessage = nil
        infoMessage = nil
        do {
            _ = try await appEnv.client.setAssistantKey(key: keyInput.trimmingCharacters(in: .whitespaces))
            await appEnv.assistant.refreshKeyStatus()
            keyInput = ""
            showingReplaceField = false
            infoMessage = "Key saved."
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke() async {
        working = true
        defer { working = false }
        errorMessage = nil
        infoMessage = nil
        do {
            try await appEnv.client.deleteAssistantKey()
            await appEnv.assistant.refreshKeyStatus()
            infoMessage = "Key revoked."
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
