import SwiftUI
import SwiftData
import SeedkeepKit

/// Phase 2 entry point. Lists every active bed in the household, with
/// a sense of upcoming work — the next planned event per bed — surfaced
/// inline so the user sees "what's overdue?" at a glance.
struct GardenView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]

    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil && $0.completedAt == nil })
    private var openEvents: [LocalPlantingEvent]

    @State private var showAddBed = false
    @State private var showWhatToPlant = false

    var body: some View {
        NavigationStack {
            ZStack {
                WBScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WBScreenTitle(
                            "Garden",
                            subtitle: "\(activeBeds.count) \(activeBeds.count == 1 ? "bed" : "beds") in the household garden"
                        )
                        .padding(.top, WBMetrics.gapLarge)
                        .padding(.bottom, WBMetrics.gapLarge)
                        if FeatureFlags.plantPetsEnabled {
                            NavigationLink(value: MenagerieDestination()) {
                                HStack {
                                    Image(systemName: "pawprint")
                                        .foregroundStyle(WBColor.muted)
                                    Text("Menagerie")
                                        .font(.wbCallout.weight(.semibold))
                                        .foregroundStyle(WBColor.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(WBColor.faint)
                                }
                                .padding(.horizontal, WBMetrics.screenGutter)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                        if activeBeds.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 0) {
                                ForEach(activeBeds, id: \.id) { bed in
                                    NavigationLink(value: bed.id) {
                                        BedRow(bed: bed, openEvents: openEventsFor(bedID: bed.id))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, WBMetrics.screenGutter)
                            .padding(.bottom, HerbSpace.fabClearance)
                        }
                    }
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .publishesAssistantContext(pageType: "garden")
            .navigationDestination(for: String.self) { bedID in
                BedDetailView(bedID: bedID)
            }
            .navigationDestination(for: MenagerieDestination.self) { _ in
                MenagerieView()
            }
            .navigationDestination(for: PetDetailDestination.self) { dest in
                PetDetailView(plantingEventID: dest.plantingEventID)
            }
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Button {
                        showWhatToPlant = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("What to plant")
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button {
                        showAddBed = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add bed")
                }
            }
            .sheet(isPresented: $showAddBed) {
                AddBedView()
            }
            .sheet(isPresented: $showWhatToPlant) {
                NavigationStack {
                    WhatToPlantView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showWhatToPlant = false }
                            }
                        }
                }
            }
            .refreshable {
                await appEnv.syncIfPossible()
            }
        }
    }

    private var activeBeds: [LocalBed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return beds.filter { $0.householdID == householdID }
    }

    private var activeOpenEvents: [LocalPlantingEvent] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return openEvents.filter { $0.householdID == householdID }
    }

    private func openEventsFor(bedID: String) -> [LocalPlantingEvent] {
        activeOpenEvents.filter { $0.bedID == bedID }
    }

    @ViewBuilder
    private var emptyState: some View {
        WBEmptyState(
            title: "No beds yet",
            message: "Beds are the spaces you plant in, such as 'Herb bed' or 'South wall'. Each one carries its own timeline.",
            systemImage: "square.grid.3x3.topleft.filled",
            action: (label: "Add your first bed", handler: { showAddBed = true })
        )
    }
}

private struct BedRow: View {
    let bed: LocalBed
    let openEvents: [LocalPlantingEvent]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bed.name)
                    .font(.wbHeadline)
                    .foregroundStyle(WBColor.ink)
                HStack(spacing: 6) {
                    if let dimensions = formattedDimensions {
                        Text(dimensions)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                        Text("·")
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.faint)
                    }
                    if let next = nextEvent {
                        Text("\(PlantingEventKind(rawValue: next.kindRaw)?.displayName ?? next.kindRaw) · \(humanDate(next.plannedFor))")
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    } else {
                        Text("no upcoming events")
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WBColor.line)
                .frame(height: 1)
        }
    }

    private var nextEvent: LocalPlantingEvent? {
        openEvents.sorted { $0.plannedFor < $1.plannedFor }.first
    }

    private var formattedDimensions: String? {
        switch (bed.widthFeet, bed.lengthFeet) {
        case let (w?, l?): return "\(formatFt(w))×\(formatFt(l))′"
        case let (w?, nil): return "\(formatFt(w))′ wide"
        case let (nil, l?): return "\(formatFt(l))′ long"
        default: return nil
        }
    }

    private func formatFt(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

func humanDate(_ ymd: String, timeZone: TimeZone = .current) -> String {
    guard ymd.range(
        of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
        options: .regularExpression
    ) != nil else { return ymd }

    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = timeZone
    guard let date = parser.date(from: ymd) else { return ymd }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

// MARK: - Navigation destinations (Phase 5.1.2)

/// Marker value used to push `MenagerieView` onto the Garden navigation
/// stack. Hashable so SwiftUI's typed navigation accepts it.
struct MenagerieDestination: Hashable {}

/// Push value for `PetDetailView`. Hashable because SwiftUI's typed
/// navigation depends on `==`/`hash` for state restoration + back-stack.
struct PetDetailDestination: Hashable {
    let plantingEventID: String
}
