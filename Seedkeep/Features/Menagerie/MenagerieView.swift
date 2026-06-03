import SwiftUI
import SwiftData
import SeedkeepKit

/// Phase 5.1.2 surface. Nested NavigationLink destination from `GardenView`
/// (NOT a new top-level tab, per the spec's open-question resolution on
/// 2026-06-02 — tab roster is already at 7).
///
/// Three Rubric'd sections: Alive · Departed · Graduated. Wilted/departing
/// pets sort to the top of Alive so attention surfaces first. Filter chips
/// at the top scope the visible set.
struct MenagerieView: View {

    @Query(filter: #Predicate<LocalPlantingEvent> {
        $0.deletedAt == nil && $0.petSeed != nil
    })
    private var petEvents: [LocalPlantingEvent]

    @Query private var departures: [LocalPetDeparture]

    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, alive, departed, graduated
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "all"
            case .alive: return "alive"
            case .departed: return "departed"
            case .graduated: return "graduated"
            }
        }
    }

    var body: some View {
        ZStack {
            VellumBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    filterChips
                    ScholarRule(verticalMargin: 12)
                        .padding(.horizontal, 22)
                    content
                        .padding(.bottom, 96)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Menagerie")
                .font(HerbFont.display(size: 38))
                .foregroundStyle(HerbColor.ink)
            Text("companions in the household garden")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
        }
        .padding(.horizontal, 26)
        .padding(.top, 8)
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.label)
                            .font(HerbFont.smallCaps(size: 10))
                            .tracking(1.5)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(filter == f
                                    ? HerbColor.ink.opacity(0.10)
                                    : Color.clear)
                            )
                            .overlay(
                                Capsule().stroke(HerbColor.inkFaint, lineWidth: 0.5)
                            )
                            .foregroundStyle(filter == f ? HerbColor.ink : HerbColor.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if petEvents.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if filter == .all || filter == .alive {
                    section(title: "Alive", events: aliveSorted, emptyHidden: filter == .all)
                }
                if filter == .all || filter == .departed {
                    section(title: "Departed", events: departedSorted, emptyHidden: true)
                }
                if filter == .all || filter == .graduated {
                    section(title: "Graduated", events: graduatedSorted, emptyHidden: true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
    }

    private func section(title: String, events: [LocalPlantingEvent], emptyHidden: Bool) -> some View {
        Group {
            if events.isEmpty {
                if !emptyHidden {
                    VStack(alignment: .leading, spacing: 10) {
                        Rubric(text: title)
                        Text("No companions yet. Plant a seed to meet your first.")
                            .font(HerbFont.bodyItalic(size: 13))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Rubric(text: title)
                    VStack(spacing: 12) {
                        ForEach(events) { event in
                            NavigationLink(value: PetDetailDestination(plantingEventID: event.id)) {
                                PetCard(pet: event, variant: .menagerie)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint")
                .font(.system(size: 40))
                .foregroundStyle(HerbColor.inkFaint)
            Text("No companions yet")
                .font(HerbFont.display(size: 20))
                .foregroundStyle(HerbColor.ink)
            Text("Plant a seed to meet your first companion.")
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 32)
    }

    // MARK: - Partitioning

    /// Set of plantingEventIDs that have a departure row. Computed once
    /// per view recompute rather than per-event so the O(N×M) becomes O(N+M).
    private var departedIDs: Set<String> {
        Set(departures.filter { $0.deletedAt == nil }.map { $0.plantingEventID })
    }

    private var aliveSorted: [LocalPlantingEvent] {
        let depIDs = departedIDs
        return petEvents.filter { event in
            event.completedAt == nil && !depIDs.contains(event.id)
        }.sorted { lhs, rhs in
            // Lowest mood first (departingImminent → wilted → quiet → content → thriving)
            moodRank(lhs.petMoodLabel) < moodRank(rhs.petMoodLabel)
        }
    }

    private var departedSorted: [LocalPlantingEvent] {
        let depIDs = departedIDs
        let depByID = Dictionary(uniqueKeysWithValues:
            departures.filter { $0.deletedAt == nil }.map { ($0.plantingEventID, $0) })
        return petEvents
            .filter { depIDs.contains($0.id) }
            .sorted { lhs, rhs in
                (depByID[lhs.id]?.departedAt ?? 0) > (depByID[rhs.id]?.departedAt ?? 0)
            }
    }

    private var graduatedSorted: [LocalPlantingEvent] {
        let depIDs = departedIDs
        return petEvents
            .filter { $0.completedAt != nil && !depIDs.contains($0.id) }
            .sorted { lhs, rhs in (lhs.completedAt ?? 0) > (rhs.completedAt ?? 0) }
    }

    private func moodRank(_ label: PetMoodLabel) -> Int {
        switch label {
        case .departingImminent: return 0
        case .wilted: return 1
        case .quiet: return 2
        case .content: return 3
        case .thriving: return 4
        }
    }
}
