// The Seeds header: lifecycle tabs with counts, type filter, search, and the table actions
// (redesign R1, slice B). Controls are 44 pt on iPad and smaller on Mac, where a pointer is precise.
import SwiftUI

enum SeedsLayout {
    /// Minimum height for toolbar and bulk-bar controls.
    static var controlMinHeight: CGFloat {
        PlatformCapabilities.isMac ? 28 : WBMetrics.touchTarget
    }
}

struct SeedsToolbar: View {
    @Binding var filter: SeedsFilter
    let counts: [SeedStateFilter: Int]
    let typeOptions: [String]
    var searchFocus: FocusState<Bool>.Binding
    /// Touch selection mode. Only shown where there is no pointer (iPad).
    @Binding var isSelecting: Bool
    @Binding var isInspectorOpen: Bool
    let canUndo: Bool
    let canRedo: Bool
    let canExport: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onExport: () -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SeedStateFilter.allCases) { tab in
                        tabButton(tab)
                    }
                }
            }
            HStack(spacing: WBMetrics.gap) {
                searchField
                typeMenu
                Spacer(minLength: 0)
                if !PlatformCapabilities.isMac {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                    }
                    .frame(minHeight: SeedsLayout.controlMinHeight)
                    .accessibilityHint(isSelecting ? "Ends selection mode" : "Lets you tap rows to select several seeds")
                    Button(action: onUndo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!canUndo)
                    .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
                    Button(action: onRedo) {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!canRedo)
                    .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
                }
                Toggle(isOn: $isInspectorOpen) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
                Button(action: onExport) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canExport)
                .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
                Button(action: onNew) {
                    Label("New seed", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WBColor.panel)
    }

    private func tabButton(_ tab: SeedStateFilter) -> some View {
        let isSelected = filter.stateTab == tab
        let count = counts[tab] ?? 0
        return Button {
            filter.stateTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(tab.title)
                    .font(.wbBody)
                Text("\(count)")
                    .font(.wbMonoCaption)
                    .foregroundStyle(isSelected ? WBColor.accent : WBColor.muted)
            }
            .foregroundStyle(isSelected ? WBColor.accent : WBColor.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: SeedsLayout.controlMinHeight)
            .background(
                isSelected ? WBColor.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.title), \(count) \(count == 1 ? "seed" : "seeds")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WBColor.faint)
                .accessibilityHidden(true)
            TextField("Search seeds", text: $filter.search)
                .textFieldStyle(.plain)
                .font(.wbBody)
                .focused(searchFocus)
                .accessibilityLabel("Search seeds")
            if !filter.search.isEmpty {
                Button {
                    filter.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WBColor.faint)
                }
                .buttonStyle(.plain)
                .frame(minWidth: SeedsLayout.controlMinHeight, minHeight: SeedsLayout.controlMinHeight)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: SeedsLayout.controlMinHeight)
        .background(WBColor.panel2, in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: WBMetrics.radiusControl)
                .stroke(WBColor.line2, lineWidth: 1)
        )
        .frame(maxWidth: 320)
    }

    private var typeMenu: some View {
        Menu {
            Button("All types") { filter.type = nil }
            if !typeOptions.isEmpty {
                Divider()
                ForEach(typeOptions, id: \.self) { type in
                    Button(type) { filter.type = type }
                }
            }
        } label: {
            Label(filter.type ?? "All types", systemImage: "tag")
                .font(.wbBody)
                .lineLimit(1)
        }
        .frame(minHeight: SeedsLayout.controlMinHeight)
        .accessibilityLabel("Type filter, \(filter.type ?? "all types")")
    }
}
