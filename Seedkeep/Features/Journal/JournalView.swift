import SwiftUI
import SwiftData

/// Top-level Journal tab. Read-only feed of `LocalJournalEntry` rows
/// reverse-sorted by `occurredOn`. Pull-to-refresh hits the server feed
/// via `JournalStore.refresh()`. Rows + the toolbar "+" both push into
/// `JournalEntryView`.
///
/// Pass `filterParent` to scope the feed (and refresh calls) to a single
/// seed / bed / planting event — used by `EntityScopedJournalSection`'s
/// "See all" link.
struct JournalView: View {
    @Environment(AppEnvironment.self) private var appEnv

    enum Route: Hashable {
        case existing(String)   // entry id
        case new
    }

    let filterParent: EntityScopedJournalSection.Parent?
    @Query private var entries: [LocalJournalEntry]

    init(filterParent: EntityScopedJournalSection.Parent? = nil) {
        self.filterParent = filterParent
        let predicate: Predicate<LocalJournalEntry>
        switch filterParent {
        case .none:
            predicate = #Predicate<LocalJournalEntry> { $0.deletedAt == nil }
        case .seed(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.seedID == id && $0.deletedAt == nil }
        case .bed(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.bedID == id && $0.deletedAt == nil }
        case .plantingEvent(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.plantingEventID == id && $0.deletedAt == nil }
        }
        _entries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    var body: some View {
        NavigationStack {
            List {
                if filterParent == nil {
                    RetrospectiveCard()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Start your garden journal",
                        systemImage: "book.closed",
                        description: Text("Track what happened in the garden over time. Tap + to add your first entry.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink(value: Route.existing(entry.id)) {
                            entryRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Journal")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .existing(let id):
                    JournalEntryView(entryID: id)
                case .new:
                    // TODO: when arriving from EntityScopedJournalSection's
                    // "See all", pre-fill the parent on the new entry.
                    JournalEntryView(entryID: nil)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: Route.new) {
                        Label("New entry", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                await refresh()
            }
            .task {
                await refresh()
            }
            .overlay(alignment: .bottomTrailing) { SproutFAB() }
        }
    }

    private func refresh() async {
        switch filterParent {
        case .none:
            await appEnv.journal.refresh()
        case .seed(let id):
            await appEnv.journal.refresh(seedID: id)
        case .bed(let id):
            await appEnv.journal.refresh(bedID: id)
        case .plantingEvent(let id):
            await appEnv.journal.refresh(plantingEventID: id)
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
