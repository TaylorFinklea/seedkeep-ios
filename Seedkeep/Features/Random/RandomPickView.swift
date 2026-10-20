import SwiftUI
import SwiftData

struct RandomPickView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Query private var allSeeds: [LocalSeed]

    /// True when presented in a sheet (the Workbench), which needs its own Close action.
    var showsClose = false

    @State private var pickedSeedID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let seed = pickedSeed {
                    NavigationLink {
                        SeedDetailView(seedID: seed.id)
                    } label: {
                        SeedCard(seed: seed)
                    }
                    .buttonStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "No active seeds to pick from.",
                        systemImage: "leaf"
                    )
                }
                Spacer()
                Button {
                    pick()
                } label: {
                    Label(pickedSeed == nil ? "Pick a seed" : "Pick another", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
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
            rng: { Double.random(in: 0..<1) }
        )?.id
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
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.leading)
            if let company = seed.customCompany?.trimmedNonEmpty {
                Text(company)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Tag(text: "\(seed.packetCount) packet\(seed.packetCount == 1 ? "" : "s")")
                Tag(text: seed.yearPacked.map { "packed \($0)" } ?? "Year unknown")
            }
            Text(seed.notes?.trimmedNonEmpty.map { "Notes: \($0)" } ?? "No notes")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .padding(.horizontal)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.18), in: .capsule)
            .foregroundStyle(.tint)
    }
}
