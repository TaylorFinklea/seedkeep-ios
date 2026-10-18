import SwiftUI
import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    enum Kind: Equatable { case action(SeedsRequest), route(WorkbenchRoute), seed(String) }
    let title: String
    let hint: String
    let group: String
    let kind: Kind
    var id: String {
        switch kind {
        case .action(let request):
            let identity: String
            switch request {
            case .newSeed: identity = "newSeed"
            case .exportCSV: identity = "exportCSV"
            case .focusSearch: identity = "focusSearch"
            case .deleteSelection: identity = "deleteSelection"
            }
            return "action:\(identity)"
        case .route(let route): return "route:\(route.rawValue)"
        case .seed(let seedID): return "seed:\(seedID)"
        }
    }
}

enum CommandPaletteSearch {
    static func results(query: String, rows: [SeedTableRow]) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            .init(title: "New seed", hint: "Create a seed", group: "Actions", kind: .action(.newSeed)),
            .init(title: "Export CSV", hint: "Export selected or visible seeds", group: "Actions", kind: .action(.exportCSV)),
            .init(title: "Find", hint: "Search seeds", group: "Actions", kind: .action(.focusSearch))
        ]
        items += WorkbenchRoute.allCases.map { .init(title: $0.title, hint: "Go to \($0.title)", group: "Go to", kind: .route($0)) }
        items += rows.map { .init(title: $0.name, hint: [$0.variety, $0.type, $0.company].filter { !$0.isEmpty }.joined(separator: " · "), group: "Seeds", kind: .seed($0.id)) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items.sorted(by: tieBreak).prefix(9).map { $0 } }
        return items.compactMap { item -> (Int, CommandPaletteItem)? in
            let fields = [item.title, item.hint, item.group].map { $0.lowercased() }
            let rank: Int? = fields.contains(where: { $0.hasPrefix(needle) }) ? 0 :
                (fields.contains(where: { hasWordStart($0, matching: needle) }) ? 1 :
                    (fields.contains(where: { $0.contains(needle) }) ? 2 : nil))
            return rank.map { ($0, item) }
        }.sorted { lhs, rhs in lhs.0 == rhs.0 ? tieBreak(lhs.1, rhs.1) : lhs.0 < rhs.0 }
            .prefix(9).map(\.1)
    }

    private static func tieBreak(_ lhs: CommandPaletteItem, _ rhs: CommandPaletteItem) -> Bool {
        let order = ["Actions": 0, "Go to": 1, "Seeds": 2]
        let a = order[lhs.group, default: 3], b = order[rhs.group, default: 3]
        return a == b ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending : a < b
    }

    private static func hasWordStart(_ value: String, matching needle: String) -> Bool {
        var searchStart = value.startIndex
        while let range = value.range(of: needle, range: searchStart..<value.endIndex) {
            if range.lowerBound == value.startIndex { return true }
            let previous = value[..<range.lowerBound].last!
            if !previous.isLetter && !previous.isNumber && previous != "_" { return true }
            searchStart = value.index(after: range.lowerBound)
        }
        return false
    }
}

@MainActor
enum CommandPaletteSelection {
    static func apply(_ item: CommandPaletteItem, to model: WorkbenchModel) {
        switch item.kind {
        case .action(let request): model.request(request)
        case .route(let route): model.route = route
        case .seed(let id): model.reveal(seedID: id)
        }
        model.isPaletteOpen = false
    }
}

struct CommandPaletteView: View {
    @Bindable var model: WorkbenchModel
    let rows: [SeedTableRow]
    @State private var query = ""
    @State private var cachedResults: [CommandPaletteItem] = []
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] { cachedResults }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search actions, screens, and seeds", text: $query)
                .font(.wbBody).padding(12).accessibilityLabel("Search command palette")
                .focused($searchFocused)
                .onChange(of: query) { _, _ in refreshResults() }
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.return) { chooseSelected(); return .handled }
                .onKeyPress(.escape) { model.isPaletteOpen = false; return .handled }
            Divider().overlay(WBColor.line)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(Array(results.enumerated()), id: \.element.id) { index, item in
                    Button { choose(item) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.wbBody).foregroundStyle(WBColor.ink)
                                Text(item.hint).font(.wbCaption).foregroundStyle(WBColor.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(item.group).font(.wbMonoCaption).foregroundStyle(WBColor.faint)
                        }
                        .padding(.horizontal, 8).frame(minHeight: WBMetrics.touchTarget)
                        .background(index == selectedIndex ? WBColor.paletteSelection : WBColor.panel)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).listRowBackground(WBColor.panel)
                    .accessibilityLabel("\(item.title), \(item.group). \(item.hint)")
                    .onHover { if $0 { selectedIndex = index } }
                }
                .listStyle(.plain)
            }
        }
        .background(WBColor.panel)
        #if os(macOS)
        // Mac-only move/exit commands cover focus outside the search field; the field's own
        // onKeyPress handlers cover both platforms.
        .onMoveCommand { direction in
            guard !results.isEmpty else { return }
            switch direction {
            case .up: selectedIndex = (selectedIndex - 1 + results.count) % results.count
            case .down: selectedIndex = (selectedIndex + 1) % results.count
            default: break
            }
        }
        .onExitCommand { model.isPaletteOpen = false }
        #endif
        .onSubmit { chooseSelected() }
        .onAppear { searchFocused = true }
        .onAppear { refreshResults() }
        .onChange(of: rows) { _, _ in refreshResults() }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
        return .handled
    }

    private func refreshResults() {
        cachedResults = CommandPaletteSearch.results(query: query, rows: rows)
        selectedIndex = 0
    }

    private func chooseSelected() { guard results.indices.contains(selectedIndex) else { return }; choose(results[selectedIndex]) }
    private func choose(_ item: CommandPaletteItem) {
        CommandPaletteSelection.apply(item, to: model)
    }
}
