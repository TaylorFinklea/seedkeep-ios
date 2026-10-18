// The Seeds inspector (redesign R1, slice B): one seed shows the existing `SeedDetailView`, several
// show a summary, and none shows a hint. A seed that was deleted or belongs to another household
// shows an unavailable state rather than its detail.
import SwiftUI
import SeedkeepKit

struct SeedsInspector: View {
    let selectedIDs: Set<String>
    let selectedRows: [SeedTableRow]
    let seedsByID: [String: LocalSeed]
    let householdID: String?

    var body: some View {
        Group {
            if selectedIDs.count == 1, let seedID = selectedIDs.first {
                detail(for: seedID)
            } else if selectedIDs.count > 1 {
                summary
            } else {
                ContentUnavailableView(
                    "No seed selected",
                    systemImage: "leaf",
                    description: Text("Select a seed in the table to see its details here.")
                )
            }
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
    }

    @ViewBuilder
    private func detail(for seedID: String) -> some View {
        if let seed = seedsByID[seedID], isLive(seed) {
            // Its own stack (the Tags link needs one), and keyed by id so drafts and cached state
            // reset when the selection changes.
            NavigationStack {
                SeedDetailView(seedID: seedID)
            }
            .id(seedID)
        } else {
            ContentUnavailableView(
                "Seed unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This seed was deleted or belongs to another garden.")
            )
        }
    }

    private var summary: some View {
        let total = selectedRows.reduce(0) { $0 + $1.packets }
        return Form {
            Section {
                LabeledContent("Selected", value: "\(selectedRows.count) seeds")
                LabeledContent("Packets", value: "\(total)")
            }
            Section("By status") {
                ForEach(SeedStateFilter.allCases.filter { $0 != .all }) { tab in
                    let count = selectedRows.filter { $0.state == tab.stateRaw }.count
                    if count > 0 {
                        LabeledContent(tab.title, value: "\(count)")
                    }
                }
            }
        }
        .font(.wbBody)
    }

    private func isLive(_ seed: LocalSeed) -> Bool {
        seed.deletedAt == nil && seed.householdID == householdID
    }
}
