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
    @State private var freshPairingCode: SeedkeepClient.WebPairingCodeDTO?
    @State private var generatingPair = false

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
                            Text("Issue a token (Claude Desktop)")
                                .font(HerbFont.smallCaps(size: 11))
                                .tracking(1.4)
                                .foregroundStyle(HerbColor.sepia)
                                .textCase(.uppercase)
                        }
                    }
                } header: {
                    Rubric(text: "claude desktop")
                } footer: {
                    Text("Claude Desktop uses a long-lived bearer token. Issue one here, paste it into your config, restart Claude.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }

                Section {
                    Button {
                        Task { await pairBrowser() }
                    } label: {
                        HStack(spacing: 6) {
                            if generatingPair {
                                ProgressView().controlSize(.small).tint(HerbColor.sepia)
                            } else {
                                Text("◇").foregroundStyle(HerbColor.sepia)
                            }
                            Text("Pair browser (Claude.ai / OAuth)")
                                .font(HerbFont.smallCaps(size: 11))
                                .tracking(1.4)
                                .foregroundStyle(HerbColor.sepia)
                                .textCase(.uppercase)
                        }
                    }
                    .disabled(generatingPair)
                } header: {
                    Rubric(text: "claude.ai web")
                } footer: {
                    Text("Claude.ai uses OAuth. Tap to generate a short code, then add the MCP server in claude.ai with the URL below and type the code on the pairing page.")
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
        .sheet(item: $freshPairingCode) { code in
            PairingCodeSheet(code: code)
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
            .vellumForm()
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
                } catch let err as SeedkeepError where err.code == "not_found" {
                    // Already revoked elsewhere (other device, expired) —
                    // the user's intent is satisfied. Don't error-flash.
                } catch let err as SeedkeepError {
                    errorMessage = "\(err.code): \(err.message)"
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func pairBrowser() async {
        generatingPair = true
        defer { generatingPair = false }
        do {
            let code = try await appEnv.client.createWebPairingCode()
            freshPairingCode = code
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
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
extension SeedkeepClient.WebPairingCodeDTO: Identifiable {
    public var id: String { code }
}

/// One-time view of a freshly-minted browser pairing code. The user
/// keeps this sheet open while connecting claude.ai's MCP UI; when the
/// browser asks for the code they type it from here.
private struct PairingCodeSheet: View {
    let code: SeedkeepClient.WebPairingCodeDTO
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Browser pairing code")
                                .font(HerbFont.display(size: 26))
                                .foregroundStyle(HerbColor.ink)
                            Text("Use this in claude.ai's MCP connect flow. Valid for 10 minutes, single-use.")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("YOUR CODE")
                                .herbRubricStyle(size: 9, tracking: 1.4)
                            Text(formattedCode)
                                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                                .tracking(8)
                                .foregroundStyle(HerbColor.ink)
                                .textSelection(.enabled)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .background(HerbColor.vellumHi)
                                .overlay(Rectangle().strokeBorder(HerbColor.sepia, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("HOW TO USE")
                                .herbRubricStyle(size: 9, tracking: 1.4)
                            VStack(alignment: .leading, spacing: 6) {
                                stepRow(num: 1, text: "In claude.ai, open Settings → Integrations → Add MCP server")
                                stepRow(num: 2, text: "MCP server URL: ")
                                Text("\(appEnv.preferences.effectiveServerURL.absoluteString)/mcp")
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(HerbColor.vellumHi)
                                stepRow(num: 3, text: "When the browser asks you to pair, type the code above")
                                stepRow(num: 4, text: "Approve the consent screen — Claude.ai gets read + write access via OAuth")
                            }
                        }

                        Text("Authorization happens on \(appEnv.preferences.effectiveServerURL.absoluteString) — claude.ai never sees your iOS session or Apple credentials.")
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.inkSoft)
                            .padding(.top, 8)
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

    @ViewBuilder
    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).")
                .font(HerbFont.bodyEmph(size: 13))
                .foregroundStyle(HerbColor.sepia)
            Text(text)
                .font(HerbFont.body(size: 13))
                .foregroundStyle(HerbColor.ink)
        }
    }

    /// Split the 8-char code in half for readability (XXXX-XXXX).
    private var formattedCode: String {
        let s = code.code
        guard s.count >= 6 else { return s }
        let half = s.count / 2
        return s.prefix(half) + "-" + s.suffix(s.count - half)
    }
}

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
