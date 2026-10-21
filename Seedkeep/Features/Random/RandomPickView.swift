import SwiftUI
import SwiftData

struct RandomPickView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    // Sorted by id so a fixed random source (sample-garden mode) always picks the same seed.
    @Query(sort: \LocalSeed.id) private var allSeeds: [LocalSeed]

    /// True when presented in a sheet (the Workbench), which needs its own Close action.
    var showsClose = false

    /// The pick's random number in [0, 1). Sample-garden mode passes a fixed one (see `RandomPickSource`).
    var randomSource: () -> Double = RandomPickSource.make(isSampleGarden: DevicePreferences.isSampleGarden)

    @State private var pickedSeedID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Centred when it fits; scrolls when large text makes the card taller than the sheet,
                // so the card never runs under the title or pushes the button off screen.
                ViewThatFits(in: .vertical) {
                    VStack {
                        Spacer()
                        pickedContent
                        Spacer()
                    }
                    ScrollView {
                        pickedContent
                            .padding(.vertical, 24)
                    }
                }
                Button {
                    pick()
                } label: {
                    Label(pickedSeed == nil ? "Pick a seed" : "Pick another", systemImage: "shuffle")
                        .font(.wbHeadline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: WBMetrics.minTouchTarget)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(WBColor.bg.ignoresSafeArea())
            .accessibilityIdentifier("screen.randomPick")
            .navigationTitle("Random")
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            // `.task` runs again when the view returns from the seed's detail. Pick only when nothing
            // is picked or the pick is gone, so the card the user opened is still there.
            .task {
                pickIfNeeded()
            }
            .onChange(of: appEnv.activeGardenHouseholdID) { _, _ in
                pick()
            }
            .onChange(of: eligibleSeeds.map(\.id)) { _, _ in
                pickIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var pickedContent: some View {
        if let seed = pickedSeed {
            NavigationLink {
                SeedDetailView(seedID: seed.id)
            } label: {
                SeedCard(seed: seed)
            }
            .buttonStyle(.plain)
        } else {
            WBEmptyState(title: "No active seeds to pick from.", systemImage: "leaf")
        }
    }

    private var eligibleSeeds: [LocalSeed] {
        let eligibleIDs = Set(RandomSeedPicker.candidates(
            from: allSeeds.map(RandomSeedCandidate.init(seed:)),
            householdID: appEnv.activeGardenHouseholdID
        ).map(\.id))
        return allSeeds.filter { eligibleIDs.contains($0.id) }
    }

    private var pickedSeed: LocalSeed? {
        guard let pickedSeedID else { return nil }
        return eligibleSeeds.first { $0.id == pickedSeedID }
    }

    private func pickIfNeeded() {
        guard RandomSeedPicker.needsPick(pickedID: pickedSeedID, candidateIDs: eligibleSeeds.map(\.id)) else { return }
        pick()
    }

    private func pick() {
        let candidates = eligibleSeeds.map(RandomSeedCandidate.init(seed:))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let currentYear = calendar.component(.year, from: .now)
        pickedSeedID = RandomSeedPicker.pick(
            from: candidates,
            currentYear: currentYear,
            rng: randomSource
        )?.id
    }
}

/// The source of a pick's random number. Sample-garden mode always returns 0, so the pick is the first
/// eligible seed on every launch. Other builds use the system generator.
enum RandomPickSource {
    static func make(isSampleGarden: Bool) -> () -> Double {
        if isSampleGarden {
            return { 0 }
        }
        return { Double.random(in: 0..<1) }
    }
}

private extension RandomSeedCandidate {
    init(seed: LocalSeed) {
        self.init(
            id: seed.id,
            householdID: seed.householdID,
            stateRaw: seed.stateRaw,
            yearPacked: seed.yearPacked,
            isDeleted: seed.deletedAt != nil
        )
    }
}

private struct SeedCard: View {
    let seed: LocalSeed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(seed.displayName)
                .font(.wbTitle)
                .multilineTextAlignment(.leading)
                // Full height: between the sheet's spacers, large text would otherwise truncate.
                .fixedSize(horizontal: false, vertical: true)
            if let company = seed.customCompany?.trimmedNonEmpty {
                Text(company)
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.muted)
            }
            let packets = "\(seed.packetCount) packet\(seed.packetCount == 1 ? "" : "s")"
            let packed = seed.yearPacked.map { "packed \($0)" } ?? "Year unknown"
            // Side by side when they fit; stacked at large text sizes rather than truncated.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Tag(text: packets)
                    Tag(text: packed)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Tag(text: packets)
                    Tag(text: packed)
                }
            }
            Text(seed.notes?.trimmedNonEmpty.map { "Notes: \($0)" } ?? "No notes")
                .font(.wbBody)
                .foregroundStyle(WBColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WBColor.panel, in: .rect(cornerRadius: WBMetrics.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: WBMetrics.radiusPanel).strokeBorder(WBColor.line, lineWidth: 1))
        .padding(.horizontal)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.wbCaption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(WBColor.accentSoft, in: .capsule)
            .foregroundStyle(WBColor.ink)
    }
}
