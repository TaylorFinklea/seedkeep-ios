import SwiftUI
import SwiftData

/// Top-level Journal tab. Read-only feed of `LocalJournalEntry` rows
/// reverse-sorted by `occurredOn`. Pull-to-refresh hits the server feed
/// via `JournalStore.refresh()`. Compose / detail come in T5.
struct JournalView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(
        filter: #Predicate<LocalJournalEntry> { $0.deletedAt == nil },
        sort: \.occurredOn,
        order: .reverse
    )
    private var entries: [LocalJournalEntry]

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Start your garden journal",
                        systemImage: "book.closed",
                        description: Text("Track what happened in the garden over time. Tap + to add your first entry.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
            .navigationTitle("Journal")
            // TODO (T5): toolbar "+ New entry" button + navigation destination
            .refreshable {
                await appEnv.journal.refresh()
            }
            .task {
                await appEnv.journal.refresh()
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.occurredOn)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.body.isEmpty ? "(empty)" : entry.body)
                .font(.body)
                .lineLimit(3)
        }
    }
}
