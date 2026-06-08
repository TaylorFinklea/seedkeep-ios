import SwiftUI

/// Lets the BYOK user paste / clear their Anthropic + OpenAI API keys.
/// Keys live in the device Keychain via `APIKeyStore`. They are never
/// transmitted to the Seedkeep server — every call that uses them goes
/// directly to api.anthropic.com / api.openai.com from the device.
struct APIKeysSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var anthropicKey: String = ""
    @State private var openaiKey: String = ""
    @State private var anthropicSaved: Bool = false
    @State private var openaiSaved: Bool = false
    @State private var anthropicWarning: String?
    @State private var openaiWarning: String?

    var body: some View {
        Form {
            Section {
                Label("These keys never leave your device. The Seedkeep server never sees them — every BYOK extraction goes from your iPhone directly to the model provider.", systemImage: "lock.shield")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }

            keySection(
                provider: .anthropic,
                draft: $anthropicKey,
                saved: $anthropicSaved,
                warning: $anthropicWarning
            )

            keySection(
                provider: .openai,
                draft: $openaiKey,
                saved: $openaiSaved,
                warning: $openaiWarning
            )

            Section {
                if let preferred = appEnv.apiKeys.preferredProvider() {
                    LabeledContent("Active") {
                        Text(preferred.displayName)
                            .foregroundStyle(HerbColor.sage)
                    }
                } else {
                    LabeledContent("Active") {
                        Text("None")
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            } header: {
                Rubric(text: "active provider")
            } footer: {
                Text("If both keys are set, BYOK extractions prefer Anthropic (matches the server's Hosted-tier model family).")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
        }
        .vellumForm()
        .navigationTitle("API keys")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            anthropicSaved = appEnv.apiKeys.has(.anthropic)
            openaiSaved = appEnv.apiKeys.has(.openai)
        }
    }

    @ViewBuilder
    private func keySection(
        provider: APIKeyStore.Provider,
        draft: Binding<String>,
        saved: Binding<Bool>,
        warning: Binding<String?>
    ) -> some View {
        Section {
            SecureField(saved.wrappedValue ? "•••••• (saved)" : "Paste key", text: draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(HerbFont.body(size: 14).monospaced())

            if let warning = warning.wrappedValue {
                Text(warning)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.ochre)
            }

            HStack {
                Button("Save") { save(provider: provider, draft: draft, saved: saved, warning: warning) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if saved.wrappedValue {
                    Button("Clear", role: .destructive) {
                        appEnv.apiKeys.clear(provider)
                        draft.wrappedValue = ""
                        saved.wrappedValue = false
                        warning.wrappedValue = nil
                    }
                }
            }
        } header: {
            Rubric(text: provider.displayName.lowercased())
        } footer: {
            Text(provider.keyHelpText)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
        }
    }

    private func save(
        provider: APIKeyStore.Provider,
        draft: Binding<String>,
        saved: Binding<Bool>,
        warning: Binding<String?>
    ) {
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix(provider.expectedPrefix) {
            warning.wrappedValue = "Doesn't look like a \(provider.displayName) key (expected to start with \(provider.expectedPrefix)). Saved anyway, but double-check."
        } else {
            warning.wrappedValue = nil
        }
        appEnv.apiKeys.save(provider, key: trimmed)
        saved.wrappedValue = true
        draft.wrappedValue = ""   // clear the field; the SecureField placeholder reflects the saved state
    }
}
