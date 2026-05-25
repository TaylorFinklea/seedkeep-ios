import SwiftUI
import SwiftData

/// Top-level Assistant tab. Shows a list of threads or starter prompts +
/// a "+" button. Empty state when the user hasn't configured their key.
struct AssistantView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalAssistantThread> { $0.deletedAt == nil },
           sort: \.updatedAt, order: .reverse)
    private var threads: [LocalAssistantThread]

    @State private var path: [String] = []
    @State private var creatingThread = false
    @State private var errorMessage: String?

    private static let starterPrompts: [String] = [
        "What did I plant in May 2024?",
        "Help me plan Bed A for June",
        "Did peppers do well last year?",
        "Add a journal entry for today: watered everything",
    ]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !appEnv.assistant.keyConfigured {
                    emptyKeyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if threads.isEmpty {
                    starterPromptsList
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.id) {
                            threadRow(thread)
                        }
                    }
                    .onDelete(perform: deleteThreads)
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Sprout")
            .navigationDestination(for: String.self) { id in
                AssistantThreadView(threadID: id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await createAndOpen() } } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!appEnv.assistant.keyConfigured || creatingThread)
                }
            }
            .task {
                await appEnv.assistant.refreshKeyStatus()
            }
            .refreshable {
                await appEnv.assistant.refreshKeyStatus()
                if case .signedIn(_, let household) = appEnv.auth.state {
                    await appEnv.sync.syncAll(householdID: household.id)
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyKeyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Sprout needs your Anthropic key")
                .font(.headline)
            Text("Open Settings → AI Assistant and paste your Anthropic API key. Sprout will use it to read your garden data and help you plan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var starterPromptsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Ask Sprout anything")
                    .font(.title2.weight(.semibold))
                Text("A few ideas to get started:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            ForEach(Self.starterPrompts, id: \.self) { prompt in
                Button {
                    Task { await createAndOpen(initialPrompt: prompt) }
                } label: {
                    HStack {
                        Text(prompt)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(.tint)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func threadRow(_ thread: LocalAssistantThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                .font(.body)
                .lineLimit(1)
            Text(Self.formatDate(thread.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func createAndOpen(initialPrompt: String? = nil) async {
        creatingThread = true
        defer { creatingThread = false }
        do {
            let thread = try await appEnv.assistant.createThread()
            appEnv.assistant.openThread(thread.id)
            path = [thread.id]
            if let initialPrompt {
                try await appEnv.assistant.send(text: initialPrompt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteThreads(at offsets: IndexSet) {
        let toDelete = offsets.map { threads[$0] }
        Task {
            for thread in toDelete {
                do {
                    try await appEnv.assistant.deleteThread(thread.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func formatDate(_ ms: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), relativeTo: Date())
    }
}
