import SwiftUI
import SwiftData
import SeedkeepKit

/// Library / Hortulus — "Pressed specimens".
///
/// A herbarium-styled grid of the user's seeds, filtered by lifecycle
/// state. Each seed renders as a paper specimen card with corner tape,
/// Roman specimen number, pressed-plant illustration, binomial / name,
/// and a verdict-dot provenance footer.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.modelContext) private var modelContext

    @State private var selectedState: SeedState = .active
    @State private var searchText: String = ""
    @State private var showingAdd = false
    @State private var showingScan = false
    @State private var showingRandom = false
    @State private var scanPrefill: AddSeedView.Prefill?
    @AppStorage("library.groupByType") private var groupByType: Bool = false

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var allSeeds: [LocalSeed]

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FolioStrip(section: "Hortulus", folio: max(activeCount, 1))

                        headingBlock
                            .padding(.horizontal, 26)
                            .padding(.top, 2)

                        lifecycleStrip
                            .padding(.horizontal, 26)
                            .padding(.top, 12)

                        ScholarRule(verticalMargin: 4)
                            .padding(.horizontal, 22)

                        SpecimenGrid(
                            state: selectedState,
                            searchText: searchText,
                            groupByType: groupByType
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 96)
                    }
                }
                .refreshable {
                    await appEnv.syncIfPossible()
                }
                .overlay(alignment: .bottomTrailing) { SproutFAB() }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search seeds")
            .publishesAssistantContext(pageType: "library")
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
                    Button { showingRandom = true } label: { Image(systemName: "shuffle") }
                        .accessibilityLabel("Random pick")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingScan = true } label: { Image(systemName: "viewfinder") }
                        .accessibilityLabel("Scan packet")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add seed")
                }
            }
            .sheet(isPresented: $showingAdd) { AddSeedView() }
            .sheet(isPresented: $showingRandom) { RandomPickView() }
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
        }
    }

    // MARK: - Heading

    @ViewBuilder
    private var headingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pressed\nspecimens")
                .font(HerbFont.display(size: 42))
                .foregroundStyle(HerbColor.ink)
                .lineSpacing(0)
            Text("\(allSeeds.count) specimens, of which \(activeCount) in the active garden")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
        }
    }

    private var activeCount: Int {
        allSeeds.filter { $0.stateRaw == SeedState.active.rawValue }.count
    }

    // MARK: - Lifecycle filter

    @ViewBuilder
    private var lifecycleStrip: some View {
        HStack(spacing: 0) {
            ForEach(SeedState.allCases, id: \.self) { state in
                lifecycleButton(state)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func lifecycleButton(_ state: SeedState) -> some View {
        let active = state == selectedState
        let count = allSeeds.filter { $0.stateRaw == state.rawValue }.count
        Button {
            selectedState = state
        } label: {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(label(state))
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.2)
                        .foregroundStyle(active ? HerbColor.ink : HerbColor.inkSoft)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("\(count)")
                        .font(HerbFont.bodyItalic(size: 10))
                        .foregroundStyle(HerbColor.inkSoft)
                }
                Rectangle()
                    .fill(active ? HerbColor.rose : Color.clear)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func label(_ s: SeedState) -> String {
        switch s {
        case .active:   return "Active"
        case .wishlist: return "Wished"
        case .saved:    return "Saved"
        case .archived: return "Archive"
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

// MARK: - Specimen grid

/// 2-column LazyVGrid of seed specimen cards. Pulled into its own view
/// so `@Query` can take filter parameters via the initializer.
private struct SpecimenGrid: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Query private var seeds: [LocalSeed]

    private let searchText: String
    private let groupByType: Bool

    init(state: SeedState, searchText: String, groupByType: Bool) {
        let raw = state.rawValue
        _seeds = Query(
            filter: #Predicate<LocalSeed> { seed in
                seed.deletedAt == nil && seed.stateRaw == raw
            },
            sort: \.updatedAt,
            order: .reverse)
        self.searchText = searchText
        self.groupByType = groupByType
    }

    var body: some View {
        let filtered = filterBySearch(seeds, query: searchText)
        Group {
            if filtered.isEmpty {
                emptyState
            } else if groupByType {
                groupedGrid(filtered)
            } else {
                grid(filtered)
            }
        }
        .task(id: seeds.map(\.id).joined()) {
            let catalogIDs = seeds.compactMap(\.catalogID)
            guard !catalogIDs.isEmpty else { return }
            await appEnv.recommendations.bulkRefresh(catalogSeedIDs: catalogIDs)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf")
                .font(.system(size: 32))
                .foregroundStyle(HerbColor.sepia.opacity(0.6))
            Text(seeds.isEmpty ? "No seeds yet" : "No matches")
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
            Text(seeds.isEmpty
                 ? "Tap + to lay a new packet upon the table."
                 : "Try a different search term.")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    @ViewBuilder
    private func grid(_ seeds: [LocalSeed]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(seeds.enumerated()), id: \.element.id) { (idx, seed) in
                NavigationLink(value: seed.id) {
                    SpecimenCard(seed: seed, romanNumber: idx + 1)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: String.self) { seedID in
            SeedDetailView(seedID: seedID)
        }
    }

    @ViewBuilder
    private func groupedGrid(_ seeds: [LocalSeed]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groupedByType(seeds), id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .herbRubricStyle(size: 11, tracking: 2)
                        .padding(.leading, 4)
                    grid(group.seeds)
                }
            }
        }
    }

    private func groupedByType(_ seeds: [LocalSeed]) -> [(title: String, seeds: [LocalSeed])] {
        let buckets = Dictionary(grouping: seeds) { seed -> String in
            let trimmed = (seed.customType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untyped" : trimmed
        }
        return buckets
            .map { (title: $0.key, seeds: $0.value) }
            .sorted { lhs, rhs in
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

// MARK: - Specimen card

private struct SpecimenCard: View {
    let seed: LocalSeed
    let romanNumber: Int

    var body: some View {
        ZStack(alignment: .top) {
            HerbColor.vellumHi
                .shadow(color: HerbColor.ink.opacity(0.12), radius: 2, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 0) {
                Text("NO. \(HerbRomanNumeral.string(for: romanNumber, lowercase: false))")
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(1.6)
                    .foregroundStyle(HerbColor.sepia)
                    .textCase(.uppercase)
                    .padding(.top, 10)
                    .padding(.leading, 8)

                HStack {
                    Spacer()
                    PressedPlant(kind: PressedPlant.Kind.from(seed.customType), size: 90)
                    Spacer()
                }
                .padding(.top, 4)
                .padding(.bottom, 6)

                Text(scientificName)
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkSoft)
                    .padding(.horizontal, 8)
                Text(displayName)
                    .font(HerbFont.bodyEmph(size: 14))
                    .foregroundStyle(HerbColor.ink)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.top, 1)

                Rectangle()
                    .fill(HerbColor.inkFaint)
                    .frame(height: 0.5)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                HStack(spacing: 4) {
                    Circle()
                        .fill(verdictColor)
                        .frame(width: 7, height: 7)
                    Text(provenance)
                        .font(HerbFont.bodyItalic(size: 10))
                        .foregroundStyle(HerbColor.inkSoft)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.top, 5)
                .padding(.bottom, 8)
            }

            // Corner tape strips — visual "specimen attached to herbarium sheet"
            TapeStrip(width: 28, height: 10, rotation: -10)
                .offset(x: -56, y: -4)
            TapeStrip(width: 28, height: 10, rotation: 9)
                .offset(x: 56, y: -4)
        }
        .frame(minHeight: 210)
    }

    private var displayName: String {
        seed.customName ?? "Untitled"
    }

    private var scientificName: String {
        let raw = (seed.customType ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "—" : raw
    }

    private var provenance: String {
        let company = seed.customCompany ?? ""
        let year = seed.yearPacked.map { HerbRomanNumeral.string(for: $0, lowercase: false) } ?? ""
        switch (company.isEmpty, year.isEmpty) {
        case (false, false): return "\(company) · \(year)"
        case (false, true):  return company
        case (true, false):  return year
        case (true, true):   return "—"
        }
    }

    private var verdictColor: Color {
        // Without the recommendation engine pulling here, use a static
        // sage indicator. The recommendation store updates these on the
        // detail screen.
        HerbColor.verdictNow
    }
}
