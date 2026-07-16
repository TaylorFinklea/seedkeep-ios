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
        Group {
        if FeatureFlags.serverGardenFeaturesRestricted {
            restrictedState
        } else {
        Form {
            if appEnv.assistant.keyConfigured && !showingReplaceField {
                Section {
                    Label("Anthropic key configured", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(HerbColor.sage)
                    Button("Replace key") {
                        showingReplaceField = true
                    }
                    Button("Revoke key", role: .destructive) {
                        Task { await revoke() }
                    }
                    .disabled(working)
                }
            } else {
                Section {
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
                } header: {
                    Rubric(text: "anthropic api key")
                }
            }

            Section {
                Text("Your API key is encrypted with AES-256-GCM and stored on Seedkeep's server. We use it to make Anthropic calls on your behalf when you talk to Sprout. The key is never displayed back to you after saving.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
                Text("Cost: Anthropic bills you directly through their API. Seedkeep doesn't add fees.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            } header: {
                Rubric(text: "privacy")
            }

            if let infoMessage {
                Section {
                    Text(infoMessage)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.sage)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.rose)
                }
            }
        }
        }
        }
        .vellumForm()
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !FeatureFlags.serverGardenFeaturesRestricted else { return }
            await appEnv.assistant.refreshKeyStatus()
        }
    }

    @ViewBuilder
    private var restrictedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 36))
                .foregroundStyle(HerbColor.sepia.opacity(0.65))
            Text("Sprout is temporarily unavailable")
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
                .multilineTextAlignment(.center)
            Text(FeatureFlags.cloudKitGardenCapabilityMessage)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Actions

    private func save() async {
        guard !FeatureFlags.serverGardenFeaturesRestricted else {
            errorMessage = FeatureFlags.cloudKitGardenCapabilityMessage
            return
        }
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
        guard !FeatureFlags.serverGardenFeaturesRestricted else {
            errorMessage = FeatureFlags.cloudKitGardenCapabilityMessage
            return
        }
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
