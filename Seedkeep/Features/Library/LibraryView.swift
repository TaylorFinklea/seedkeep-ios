import SwiftUI
import SwiftData
import SeedkeepKit

/// Real Library: live list of `LocalSeed` filtered by lifecycle state,
/// with search, pull-to-refresh, and the "older — check" badge.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.modelContext) private var modelContext

    @State private var selectedState: SeedState = .active
    @State private var searchText: String = ""
    @State private var showingAdd = false
    @State private var showingScan = false
    @State private var scanPrefill: AddSeedView.Prefill?
    @AppStorage("library.groupByType") private var groupByType: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Lifecycle", selection: $selectedState) {
                    Text("Active").tag(SeedState.active)
                    Text("Wishlist").tag(SeedState.wishlist)
                    Text("Saved").tag(SeedState.saved)
                    Text("Archive").tag(SeedState.archived)
                }
                .pickerStyle(.segmented)
                .padding()

                SeedListContent(
                    state: selectedState,
                    searchText: searchText,
                    groupByType: groupByType
                )
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search seeds")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Group by type", isOn: $groupByType)
                    } label: {
                        Image(systemName: groupByType ? "rectangle.3.group" : "line.3.horizontal")
                    }
                    .accessibilityLabel("Library options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingScan = true
                    } label: {
                        Image(systemName: "viewfinder")
                    }
                    .accessibilityLabel("Scan packet")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add seed")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddSeedView()
            }
            .fullScreenCover(isPresented: $showingScan) {
                ScanFlow { result in
                    switch result {
                    case .catalogHit(let barcode, let cat):
                        scanPrefill = .catalog(barcode: barcode, cat)
                    case .extracted(let extraction, let barcode):
                        scanPrefill = .extraction(extraction, barcode: barcode)
                    case .preExtracted(let pre, let barcode):
                        scanPrefill = .preExtraction(pre, barcode: barcode)
                    }
                }
            }
            .sheet(item: Binding(
                get: { scanPrefill.map { ScanPrefillBox(prefill: $0) } },
                set: { box in scanPrefill = box?.prefill }
            )) { box in
                AddSeedView(prefill: box.prefill)
            }
            .refreshable {
                await appEnv.syncIfPossible()
            }
        }
    }
}

/// Identifiable wrapper so the prefill sheet can use `.sheet(item:)`.
private struct ScanPrefillBox: Identifiable {
    let prefill: AddSeedView.Prefill
    var id: String {
        switch prefill {
        case .catalog(_, let cat): return "catalog-\(cat.id)"
        case .extraction(let r, _): return "extraction-\(r.extraction_id)"
        case .preExtraction(let r, _): return "pre-extraction-\(r.extraction_id)"
        }
    }
}

/// Pulled into its own view so `@Query` can take filter parameters via
/// the initializer — a SwiftData-friendly pattern for state-scoped lists.
private struct SeedListContent: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Query private var seeds: [LocalSeed]
    @Query private var locations: [LocalLocation]

    private let searchText: String
    private let groupByType: Bool

    init(state: SeedState, searchText: String, groupByType: Bool) {
        let raw = state.rawValue
        let seedDescriptor = FetchDescriptor<LocalSeed>(
            predicate: #Predicate<LocalSeed> { seed in
                seed.deletedAt == nil && seed.stateRaw == raw
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        self._seeds = Query(seedDescriptor)

        let locDescriptor = FetchDescriptor<LocalLocation>(
            predicate: #Predicate<LocalLocation> { loc in loc.deletedAt == nil }
        )
        self._locations = Query(locDescriptor)
        self.searchText = searchText
        self.groupByType = groupByType
    }

    var body: some View {
        let filtered = filterBySearch(seeds, query: searchText)
        let locationByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.name) })
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

        if filtered.isEmpty {
            ContentUnavailableView(
                seeds.isEmpty ? "No seeds yet" : "No matches",
                systemImage: "leaf",
                description: Text(seeds.isEmpty
                    ? "Tap + to add a packet, or pull to refresh from the server."
                    : "Try a different search term."
                )
            )
        } else {
            if groupByType {
                List {
                    ForEach(groupedByType(filtered), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.seeds) { seed in
                                seedRowLink(seed, locationByID: locationByID, currentYear: currentYear)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationDestination(for: String.self) { seedID in
                    SeedDetailView(seedID: seedID)
                }
            } else {
                List {
                    ForEach(filtered) { seed in
                        seedRowLink(seed, locationByID: locationByID, currentYear: currentYear)
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: String.self) { seedID in
                    SeedDetailView(seedID: seedID)
                }
            }
        }
    }

    @ViewBuilder
    private func seedRowLink(_ seed: LocalSeed, locationByID: [String: String], currentYear: Int) -> some View {
        NavigationLink(value: seed.id) {
            SeedRow(
                seed: seed,
                locationName: seed.locationID.flatMap { locationByID[$0] },
                currentYear: currentYear
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                try? appEnv.sync.enqueueDeleteSeed(id: seed.id)
                Task { try? await appEnv.sync.flushPending() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Bucket seeds by their customType (with an "Untyped" bucket for nil /
    /// blank values), sorted alphabetically by type so the section order is
    /// stable across renders.
    private func groupedByType(_ seeds: [LocalSeed]) -> [(title: String, seeds: [LocalSeed])] {
        let buckets = Dictionary(grouping: seeds) { seed -> String in
            let trimmed = (seed.customType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untyped" : trimmed
        }
        return buckets
            .map { (title: $0.key, seeds: $0.value) }
            .sorted { lhs, rhs in
                // Push "Untyped" to the bottom so typed groups read first.
                if lhs.title == "Untyped" { return false }
                if rhs.title == "Untyped" { return true }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func filterBySearch(_ all: [LocalSeed], query: String) -> [LocalSeed] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { seed in
            (seed.customName ?? "").lowercased().contains(q)
            || (seed.customVariety ?? "").lowercased().contains(q)
            || (seed.customCompany ?? "").lowercased().contains(q)
            || (seed.notes ?? "").lowercased().contains(q)
        }
    }
}
