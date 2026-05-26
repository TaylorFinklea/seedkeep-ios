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
                VellumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FolioStrip(section: "Hortus", folio: max(beds.count, 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Abbey grounds")
                                .font(HerbFont.display(size: 38))
                                .foregroundStyle(HerbColor.ink)
                            Text("\(HerbRomanNumeral.string(for: beds.count)) plots in the household garden")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                        .padding(.horizontal, 26)
                        ScholarRule(verticalMargin: 12)
                            .padding(.horizontal, 22)
                        if beds.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(beds.enumerated()), id: \.element.id) { (idx, bed) in
                                    NavigationLink(value: bed.id) {
                                        BedRow(bed: bed, romanIndex: idx + 1, openEvents: openEventsFor(bedID: bed.id))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.bottom, 96)
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .publishesAssistantContext(pageType: "garden")
            .navigationDestination(for: String.self) { bedID in
                BedDetailView(bedID: bedID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showWhatToPlant = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("What to plant")
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .overlay(alignment: .bottomTrailing) { SproutFAB() }
        }
    }

    private func openEventsFor(bedID: String) -> [LocalPlantingEvent] {
        openEvents.filter { $0.bedID == bedID }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 32))
                .foregroundStyle(HerbColor.sepia.opacity(0.6))
            Text("No plots yet")
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
            Text("Beds are the spaces you plant in — 'south wall', 'dooryard', 'cloister herb plot'. Each one carries its own timeline.")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showAddBed = true
            } label: {
                Text("Lay out your first plot")
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(2)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerbColor.sepia)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct BedRow: View {
    let bed: LocalBed
    let romanIndex: Int
    let openEvents: [LocalPlantingEvent]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(HerbRomanNumeral.string(for: romanIndex, lowercase: false))
                .font(HerbFont.smallCaps(size: 14))
                .foregroundStyle(HerbColor.sepia)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(bed.name)
                    .font(HerbFont.bodyEmph(size: 14))
                    .foregroundStyle(HerbColor.ink)
                HStack(spacing: 6) {
                    if let dimensions = formattedDimensions {
                        Text(dimensions)
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkSoft)
                        Text("·")
                            .foregroundStyle(HerbColor.inkFaint)
                    }
                    if let next = nextEvent {
                        Text("\(PlantingEventKind(rawValue: next.kindRaw)?.displayName ?? next.kindRaw) · \(humanDate(next.plannedFor))")
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkSoft)
                    } else {
                        Text("no upcoming events")
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkFaint)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HerbColor.inkFaint)
                .frame(height: 0.5)
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

func humanDate(_ ymd: String) -> String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = parser.date(from: ymd) else { return ymd }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}
