import SwiftUI
import SwiftData
import SeedkeepKit

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var selectedState: SeedStateFilter = .active
    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var showingScan = false
    @State private var showingRandom = false
    @State private var scanPrefill: AddSeedView.Prefill?
    @AppStorage("library.groupByType") private var groupByType = false

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var queriedSeeds: [LocalSeed]
    @Query private var queriedTags: [LocalTag]
    @Query private var queriedLocations: [LocalLocation]

    @ScaledMetric(relativeTo: .caption) private var verdictDotSize: CGFloat = 7
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let householdID = appEnv.activeGardenHouseholdID
        let seeds = queriedSeeds.filter { $0.householdID == householdID }
        let tags = queriedTags.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let locations = queriedLocations.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let recommendations = Dictionary(
            seeds.compactMap { seed in appEnv.recommendations.recommendation(for: seed).map { (seed.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = SeedTableRow.rows(
            seeds: seeds, locations: locations, tags: tags, recommendations: recommendations
        )
        let recentRows = SeedsTableModel.recentFirst(rows)
        let counts = SeedsTableModel.libraryStateCounts(rows, search: searchText)
        let selectedRows = recentRows.filter { $0.state == selectedState.rawValue }
        let visibleRows = SeedsTableModel.filtered(
            recentRows,
            SeedsFilter(stateTab: selectedState, type: nil, search: searchText)
        )
        NavigationStack {
            List {
                Section {
                    WBScreenTitle("Seeds", subtitle: SeedsListText.subtitle(
                        total: rows.count,
                        active: SeedsTableModel.libraryCounts(rows).active
                    ))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    statePicker(counts: counts)
                        .listRowInsets(EdgeInsets(top: 8, leading: WBMetrics.screenGutter, bottom: 8, trailing: WBMetrics.screenGutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if rows.isEmpty && appEnv.isSyncingForDisplay {
                    Section {
                        ProgressView("Syncing…")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                            .frame(maxWidth: .infinity, minHeight: WBMetrics.minTouchTarget)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else if visibleRows.isEmpty {
                    Section {
                        emptyState(rowsInSelectedState: selectedRows, searchMatches: visibleRows)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else if groupByType {
                    ForEach(SeedsTableModel.groupedByType(visibleRows)) { group in
                        Section {
                            ForEach(group.rows) { row in
                                seedRow(row)
                            }
                        } header: {
                            WBSectionHeader(group.title)
                        }
                    }
                } else {
                    Section {
                        ForEach(visibleRows) { row in
                            seedRow(row)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { WBScreenBackground() }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search seeds")
            #else
            .searchable(text: $searchText, prompt: "Search seeds")
            #endif
            .refreshable { await appEnv.syncIfPossible() }
            .publishesAssistantContext(pageType: "library")
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Menu {
                        Toggle("Group by type", isOn: $groupByType)
                    } label: {
                        Image(systemName: groupByType ? "rectangle.3.group" : "line.3.horizontal")
                            .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                    }
                    .accessibilityLabel("Library options")
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button { showingRandom = true } label: {
                        Image(systemName: "shuffle")
                            .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                    }
                    .accessibilityLabel("Random pick")
                }
                if PlatformCapabilities.supportsCameraScanning {
                    ToolbarItem(placement: .platformTrailing) {
                        Button { showingScan = true } label: {
                            Image(systemName: "viewfinder")
                                .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                        }
                        .accessibilityLabel("Scan packet")
                    }
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                    }
                    .accessibilityLabel("Add seed")
                }
            }
            .sheet(isPresented: $showingAdd) { AddSeedView() }
            .sheet(isPresented: $showingRandom) { RandomPickView() }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingScan) {
                ScanFlow { result in
                    switch result {
                    case .localExtraction(let scanID, let fields, let binding):
                        scanPrefill = .localExtraction(scanID: scanID, fields: fields, binding: binding)
                    }
                }
            }
            #endif
            .sheet(item: Binding(
                get: { scanPrefill.map { ScanPrefillBox(prefill: $0) } },
                set: { box in scanPrefill = box?.prefill }
            )) { box in
                AddSeedView(prefill: box.prefill)
            }
            .navigationDestination(for: String.self) { seedID in
                SeedDetailView(seedID: seedID)
            }
        }
    }

    /// Segmented at standard sizes. At accessibility sizes a menu, because segmented control text
    /// doesn't grow with Dynamic Type. Each option reads its title and count; the control itself
    /// announces the selection.
    @ViewBuilder
    private func statePicker(counts: [SeedStateFilter: Int]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Seed state", selection: $selectedState) {
                ForEach(visibleStateFilters) { state in
                    Text(optionTitle(state, counts: counts)).tag(state)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(WBColor.accent)
        } else {
            Picker("Seed state", selection: $selectedState) {
                ForEach(visibleStateFilters) { state in
                    Text(optionTitle(state, counts: counts)).tag(state)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var visibleStateFilters: [SeedStateFilter] {
        [.active, .wishlist, .saved, .archived]
    }

    private func optionTitle(_ state: SeedStateFilter, counts: [SeedStateFilter: Int]) -> String {
        "\(state.title) \(counts[state, default: 0])"
    }

    @ViewBuilder
    private func seedRow(_ row: SeedTableRow) -> some View {
        // At accessibility sizes the verdict goes under the name; beside it, both break mid-word.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WBMetrics.gap))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WBMetrics.gap))
        NavigationLink(value: row.id) {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SeedsListText.displayName(for: row))
                        .font(.wbHeadline)
                        .foregroundStyle(WBColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(SeedsListText.rowLines(for: row).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let verdict = row.verdict {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(WBColor.verdict(verdict))
                            .frame(width: verdictDotSize, height: verdictDotSize)
                            .accessibilityHidden(true)
                        Text(row.verdictLabel)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(minHeight: WBMetrics.minTouchTarget)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SeedsListText.accessibilityLabel(for: row))
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
        // On the page background and the screen gutter, like the Journal list.
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(
            top: WBMetrics.gap, leading: WBMetrics.screenGutter,
            bottom: WBMetrics.gap, trailing: WBMetrics.screenGutter))
    }

    @ViewBuilder
    private func emptyState(rowsInSelectedState: [SeedTableRow], searchMatches: [SeedTableRow]) -> some View {
        switch SeedsListText.emptyState(rowsInSelectedState: rowsInSelectedState, searchMatches: searchMatches) {
        case .noSeeds:
            WBEmptyState(title: "No seeds yet", message: "Tap + to add a seed.", systemImage: "leaf")
        case .noMatches:
            WBEmptyState(title: "No matches", message: "Try a different search.", systemImage: "magnifyingglass")
        case .hasResults:
            EmptyView()
        }
    }
}

/// Identifiable wrapper so the prefill sheet can use `.sheet(item:)`.
struct ScanPrefillBox: Identifiable {
    let prefill: AddSeedView.Prefill
    var id: String {
        switch prefill {
        case .localExtraction(let scanID, _, _): return "scan-\(scanID.uuidString)"
        }
    }
}
