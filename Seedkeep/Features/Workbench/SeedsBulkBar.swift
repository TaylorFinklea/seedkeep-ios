// Actions for the selected seeds (redesign R1, slice B). The bar only reports the user's choice;
// the Seeds table applies it through `SeedWriter` and asks for confirmation before a delete.
import SwiftUI
import SeedkeepKit

struct SeedsBulkBar: View {
    let selectedCount: Int
    let locations: [LocalLocation]
    let tags: [LocalTag]
    let onStatus: (SeedState) -> Void
    let onMove: (String?) -> Void
    let onAddTag: (String) -> Void
    let onDelete: () -> Void
    let onClear: () -> Void

    private static let states: [SeedState] = [.active, .wishlist, .saved, .archived]

    var body: some View {
        HStack(spacing: WBMetrics.gap) {
            Text("\(selectedCount) selected")
                .font(.wbMono)
                .foregroundStyle(WBColor.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu("Set status") {
                ForEach(Self.states, id: \.self) { state in
                    Button(SeedsTableModel.stateLabel(state.rawValue)) { onStatus(state) }
                }
            }
            .frame(minHeight: SeedsLayout.controlMinHeight)
            Menu("Move to") {
                Button("No location") { onMove(nil) }
                if !locations.isEmpty {
                    Divider()
                    ForEach(locations) { location in
                        Button(location.name) { onMove(location.id) }
                    }
                }
            }
            .frame(minHeight: SeedsLayout.controlMinHeight)
            Menu("Add tag") {
                ForEach(tags) { tag in
                    Button(tag.name) { onAddTag(tag.id) }
                }
            }
            .disabled(tags.isEmpty)
            .frame(minHeight: SeedsLayout.controlMinHeight)
            Button("Delete", role: .destructive, action: onDelete)
                .frame(minHeight: SeedsLayout.controlMinHeight)
            Button("Clear selection", action: onClear)
                .frame(minHeight: SeedsLayout.controlMinHeight)
        }
        .font(.wbBody)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WBColor.selection)
        .overlay(alignment: .top) {
            Rectangle().fill(WBColor.line).frame(height: 1)
        }
    }
}
