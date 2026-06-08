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
            ZStack {
                VellumBackground()
                List {
                    Section {
                        headingBlock
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
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
                            .listRowBackground(Color.clear)
                        }
                        .onDelete(perform: deleteThreads)
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).font(.footnote).foregroundStyle(HerbColor.rose) }
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
    private var headingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            FolioStrip(section: "Scriptorium", folio: max(threads.count, 1))
                .padding(.horizontal, -16)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sprout")
                    .font(HerbFont.display(size: 38))
                    .foregroundStyle(HerbColor.ink)
                Text("The household scribe")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            ScholarRule(verticalMargin: 8)
        }
    }

    @ViewBuilder
    private var emptyKeyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 36))
                .foregroundStyle(HerbColor.sepia.opacity(0.65))
            Text("Sprout awaits a key")
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
            Text("Open Settings → AI Assistant and paste your Anthropic API key. Sprout will then read your garden and help you plan.")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var starterPromptsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rubric(text: "to begin")
                .padding(.bottom, 4)

            ForEach(Self.starterPrompts, id: \.self) { prompt in
                Button {
                    Task { await createAndOpen(initialPrompt: prompt) }
                } label: {
                    HStack {
                        Text(prompt)
                            .font(HerbFont.bodyItalic(size: 13))
                            .foregroundStyle(HerbColor.ink)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(HerbColor.sepia)
                    }
                    .padding(12)
                    .background(HerbColor.vellumHi)
                    .overlay(
                        Rectangle()
                            .strokeBorder(HerbColor.inkFaint, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func threadRow(_ thread: LocalAssistantThread) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("✦")
                .font(HerbFont.smallCaps(size: 11))
                .foregroundStyle(HerbColor.sepia)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(HerbFont.body(size: 14))
                    .foregroundStyle(HerbColor.ink)
                    .lineLimit(1)
                Text(Self.formatDate(thread.updatedAt))
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkSoft)
            }
        }
        .padding(.vertical, 4)
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
