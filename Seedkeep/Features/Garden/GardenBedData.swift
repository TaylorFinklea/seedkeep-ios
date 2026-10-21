import Foundation
import SwiftUI
import SeedkeepKit

/// A bed's live events as the grid, details and list read them: grid events with their frost flags,
/// frost outcomes, seed names and notes, all keyed by id.
struct GardenBedData {
    let bedID: String
    let size: GridSize?
    let events: [GridEvent]
    let frost: [String: FrostCheck.Outcome]
    let seedNames: [String: String]
    let notes: [String: String]
    let spacingInches: [String: Int]

    /// `events` and `seeds` may include other beds and deleted rows; only the bed's live events count.
    init(bed: LocalBed, events: [LocalPlantingEvent], seeds: [LocalSeed], climate: HomeClimate?) {
        bedID = bed.id
        size = GardenGrid.size(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet)
        let liveSeeds = seeds.filter { $0.deletedAt == nil && $0.householdID == bed.householdID }
        let seedsByID = Dictionary(liveSeeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = events.filter {
            $0.bedID == bed.id && $0.deletedAt == nil && $0.householdID == bed.householdID
        }
        var frost: [String: FrostCheck.Outcome] = [:]
        var notes: [String: String] = [:]
        var gridEvents: [GridEvent] = []
        for event in live {
            let outcome = FrostCheck.check(event, seed: event.seedID.flatMap { seedsByID[$0] }, climate: climate)
            frost[event.id] = outcome
            if let text = event.notes { notes[event.id] = text }
            gridEvents.append(GridEvent(event, isFrostFlagged: outcome.isFlagged))
        }
        self.frost = frost
        self.notes = notes
        self.events = gridEvents
        seedNames = seedsByID.mapValues(\.displayName)
        spacingInches = seedsByID.compactMapValues { $0.growingInfo?.plant_spacing_inches }
    }

    func seedName(_ event: GridEvent) -> String? {
        event.seedID.flatMap { seedNames[$0] }
    }

    func event(_ id: String?) -> GridEvent? {
        guard let id else { return nil }
        return events.first { $0.id == id }
    }

    /// `GardenGrid.squares` for the bed; empty without a grid.
    var squares: [GridSquare: SquareContents] {
        guard let size else { return [:] }
        return GardenGrid.squares(events: events, bedID: bedID, size: size)
    }

    func rows(today: CalendarDay) -> [BedEventRow] {
        BedEventRow.rows(
            events: events, bedID: bedID, size: size, seedNames: seedNames,
            notes: notes, frost: frost, today: today
        )
    }
}

/// Speaks a Garden message to VoiceOver.
enum GardenAnnouncer {
    @MainActor
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
