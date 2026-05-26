import SwiftUI
import SeedkeepKit

/// Phase 4 E — issue + manage MCP bearer tokens for connecting
/// Seedkeep to Claude Desktop / claude.ai.
///
/// Flow: tap "New token" → paste a label → server returns the raw
/// secret ONCE in a "copy this now" sheet. From then on we only show
/// metadata (label, created date, last-used).
struct MCPSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var tokens: [SeedkeepClient.MCPTokenDTO] = []
    @State private var loading = false
    @State private var errorMessage: String?

    @State private var showNewTokenSheet = false
    @State private var pendingLabel = ""
    @State private var creating = false

    @State private var freshSecret: SeedkeepClient.MCPTokenSecretDTO?

    var body: some View {
        ZStack {
            VellumBackground()
            Form {
                Section {
                    aboutBlock
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                }

                if !tokens.isEmpty {
                    Section {
                        ForEach(tokens) { token in
                            tokenRow(token)
                        }
                        .onDelete(perform: revoke)
                    } header: {
                        Rubric(text: "issued tokens")
                    }
                }

                Section {
                    Button {
                        pendingLabel = ""
                        showNewTokenSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("✦").foregroundStyle(HerbColor.sepia)
                            Text("Issue a new token")
                                .font(HerbFont.smallCaps(size: 11))
                                .tracking(1.4)
                                .foregroundStyle(HerbColor.sepia)
                                .textCase(.uppercase)
                        }
                    }
                } footer: {
                    Text("You can issue multiple tokens — one per device or client. Revoke any token by swiping it away.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.rose)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Claude / MCP")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showNewTokenSheet) {
            newTokenSheet
        }
        .sheet(item: $freshSecret) { secret in
            FreshSecretSheet(secret: secret)
        }
    }

    @ViewBuilder
    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Desktop / claude.ai")
                .font(HerbFont.display(size: 26))
                .foregroundStyle(HerbColor.ink)
            Text("Use your Claude subscription — no API tokens billed to you. Issue a token here, paste it into your Claude client's MCP config, and Sprout's tools work from inside Claude.")
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(HerbColor.inkSoft)
            Text("Server: \(serverURL)/mcp")
                .font(.caption.monospaced())
                .foregroundStyle(HerbColor.sepia)
                .padding(.top, 4)
        }
    }

    private var serverURL: String {
        appEnv.preferences.effectiveServerURL.absoluteString
    }

    @ViewBuilder
    private func tokenRow(_ token: SeedkeepClient.MCPTokenDTO) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(token.label)
                .font(HerbFont.body(size: 14))
                .foregroundStyle(HerbColor.ink)
            HStack(spacing: 6) {
                Text("Created \(relative(token.created_at))")
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkSoft)
                if let last = token.last_used_at {
                    Text("·")
                        .foregroundStyle(HerbColor.inkFaint)
                    Text("Used \(relative(last))")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                } else {
                    Text("·")
                        .foregroundStyle(HerbColor.inkFaint)
                    Text("Never used")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkFaint)
                }
            }
        }
    }

    @ViewBuilder
    private var newTokenSheet: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                Form {
                    Section {
                        TextField("Label (e.g. \"Claude Desktop\")", text: $pendingLabel)
                            .font(HerbFont.body(size: 14))
                    } header: {
                        Rubric(text: "name this token")
                    } footer: {
                        Text("Pick a label you'll recognize when you come back to revoke this token later. Defaults to \"Untitled\".")
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New MCP token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewTokenSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(creating)
                }
            }
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            tokens = try await appEnv.client.listMCPTokens()
            errorMessage = nil
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let trimmed = pendingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let secret = try await appEnv.client.createMCPToken(
                label: trimmed.isEmpty ? nil : trimmed)
            freshSecret = secret
            showNewTokenSheet = false
            await refresh()
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(at offsets: IndexSet) {
        let targets = offsets.map { tokens[$0] }
        Task {
            for token in targets {
                do {
                    try await appEnv.client.revokeMCPToken(token.id)
                } catch let err as SeedkeepError {
                    errorMessage = "\(err.code): \(err.message)"
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func relative(_ ms: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
            relativeTo: Date()
        )
    }
}

extension SeedkeepClient.MCPTokenSecretDTO: Identifiable {}

/// One-time view of the raw token secret, with a copy button and the
/// MCP config snippet ready to paste into Claude Desktop.
private struct FreshSecretSheet: View {
    let secret: SeedkeepClient.MCPTokenSecretDTO
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv
    @State private var copiedToken = false
    @State private var copiedConfig = false

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Token created")
                                .font(HerbFont.display(size: 26))
                                .foregroundStyle(HerbColor.ink)
                            Text("Copy it now — Seedkeep never shows this value again.")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("TOKEN")
                                .herbRubricStyle(size: 9, tracking: 1.4)
                            Text(secret.token)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(HerbColor.vellumHi)
                                .overlay(Rectangle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5))
                            Button {
                                UIPasteboard.general.string = secret.token
                                copiedToken = true
                            } label: {
                                Text(copiedToken ? "✓ COPIED" : "COPY TOKEN")
                                    .font(HerbFont.smallCaps(size: 11))
                                    .tracking(1.5)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 11)
                                    .background(HerbColor.sepia, in: .capsule)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("CLAUDE DESKTOP CONFIG")
                                .herbRubricStyle(size: 9, tracking: 1.4)
                            Text("Add to your `~/Library/Application Support/Claude/claude_desktop_config.json`:")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                            Text(configSnippet)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(HerbColor.vellumHi)
                                .overlay(Rectangle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5))
                            Button {
                                UIPasteboard.general.string = configSnippet
                                copiedConfig = true
                            } label: {
                                Text(copiedConfig ? "✓ COPIED" : "COPY CONFIG")
                                    .font(HerbFont.smallCaps(size: 11))
                                    .tracking(1.5)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 11)
                                    .background(HerbColor.sepia, in: .capsule)
                            }
                        }

                        Text("Restart Claude Desktop after editing the config. Then ask Claude what it can do — you should see the Seedkeep tools.")
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.inkSoft)
                            .padding(.top, 4)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var configSnippet: String {
        """
        {
          "mcpServers": {
            "seedkeep": {
              "url": "\(appEnv.preferences.effectiveServerURL.absoluteString)/mcp",
              "headers": {
                "Authorization": "Bearer \(secret.token)"
              }
            }
          }
        }
        """
    }
}
