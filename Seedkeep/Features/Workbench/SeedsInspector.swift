// The Seeds inspector (redesign R1, slice B): one seed shows the existing `SeedDetailView`, several
// show a summary, and none shows a hint. A seed that was deleted or belongs to another household
// shows an unavailable state rather than its detail.
import SwiftUI
import SeedkeepKit

/// The inspector's starting state for a visit to the Seeds route (R2c C3-d). It starts closed when the
/// detail column can't hold the table's minimum width beside the inspector's minimum width.
enum SeedsInspectorPolicy {
    /// False when the detail column can't fit the table and the inspector side by side, so the
    /// inspector starts closed. Nil otherwise (wide enough, or a choice made during the visit holds),
    /// and the caller keeps the current state.
    static func startsOpen(
        availableWidth: CGFloat,
        tableMinWidth: CGFloat,
        inspectorMinWidth: CGFloat,
        userToggledThisVisit: Bool
    ) -> Bool? {
        guard !userToggledThisVisit else { return nil }
        return availableWidth < tableMinWidth + inspectorMinWidth ? false : nil
    }
}

struct SeedsInspector: View {
    /// Narrowest the inspector column may be. The Seeds screen's starting-state policy uses it.
    static let minimumWidth: CGFloat = 300

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
        .inspectorColumnWidth(min: Self.minimumWidth, ideal: 360, max: 480)
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
            Section {
                ForEach(SeedStateFilter.allCases.filter { $0 != .all }) { tab in
                    let count = selectedRows.filter { $0.state == tab.stateRaw }.count
                    if count > 0 {
                        LabeledContent(tab.title, value: "\(count)")
                    }
                }
            } header: {
                WBSectionHeader("By status")
            }
        }
        .font(.wbBody)
    }

    private func isLive(_ seed: LocalSeed) -> Bool {
        seed.deletedAt == nil && seed.householdID == householdID
    }
}
