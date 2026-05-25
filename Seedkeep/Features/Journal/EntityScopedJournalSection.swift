import SwiftUI
import SwiftData

/// Collapsible "Journal" section for embedding inside a parent entity's
/// detail view. Shows the most recent N entries for that entity with a
/// "See all" link that pushes the full Journal feed pre-filtered.
struct EntityScopedJournalSection: View {
    enum Parent: Hashable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
    }

    let parent: Parent
    var maxEntries: Int = 3

    @Query private var entries: [LocalJournalEntry]

    init(parent: Parent, maxEntries: Int = 3) {
        self.parent = parent
        self.maxEntries = maxEntries
        let predicate: Predicate<LocalJournalEntry>
        switch parent {
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
        Section("Journal") {
            if entries.isEmpty {
                Text("No entries yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(maxEntries)) { entry in
                    NavigationLink {
                        JournalEntryView(entryID: entry.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.occurredOn)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.body.isEmpty ? "(empty)" : entry.body)
                                .font(.body)
                                .lineLimit(2)
                        }
                    }
                }
                if entries.count > maxEntries {
                    Text("\(entries.count - maxEntries) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                JournalView(filterParent: parent)
            } label: {
                Label("See all journal entries", systemImage: "book")
                    .font(.footnote)
            }
        }
    }
}
