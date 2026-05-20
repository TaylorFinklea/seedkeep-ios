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
            Group {
                if beds.isEmpty {
                    ContentUnavailableView {
                        Label("No beds yet", systemImage: "square.grid.3x3.topleft.filled")
                    } description: {
                        Text("Beds are the spaces you plant in — \"Back garden\", \"Greenhouse shelf\", \"Front raised bed\". Each one gets its own planting timeline.")
                    } actions: {
                        Button("Add your first bed") { showAddBed = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(beds) { bed in
                            NavigationLink(value: bed.id) {
                                BedRow(bed: bed, openEvents: openEventsFor(bedID: bed.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Garden")
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
        }
    }

    private func openEventsFor(bedID: String) -> [LocalPlantingEvent] {
        openEvents.filter { $0.bedID == bedID }
    }
}

private struct BedRow: View {
    let bed: LocalBed
    let openEvents: [LocalPlantingEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bed.name)
                    .font(.body.weight(.medium))
                Spacer()
                if let dimensions = formattedDimensions {
                    Text(dimensions)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let next = nextEvent {
                HStack(spacing: 6) {
                    Image(systemName: PlantingEventKind(rawValue: next.kindRaw)?.systemImage ?? "calendar")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text("\(PlantingEventKind(rawValue: next.kindRaw)?.displayName ?? next.kindRaw) — \(humanDate(next.plannedFor))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if openEvents.count > 1 {
                        Text("+\(openEvents.count - 1)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
            } else {
                Text("No upcoming events")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
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
