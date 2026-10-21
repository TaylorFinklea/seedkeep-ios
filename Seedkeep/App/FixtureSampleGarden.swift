// Sample garden for `-SeedkeepFixture` (DEBUG builds only, see FixtureMode.swift). Deterministic
// content for screenshots: 20 seeds across all four states, each with growing info so planting
// windows show; two beds with plantings; journal entries with checklists; tags; locations; and a
// home ZIP. Dates are relative to the launch day, so the timeline reads as current.
#if DEBUG
import Foundation
import SeedkeepKit
import SwiftData

enum FixtureSampleGarden {
    static let homeZip = "55401"

    /// Writes the sample garden into `context` and caches the home climate in `preferences`.
    @MainActor
    static func seed(
        into context: ModelContext,
        householdID: String,
        preferences: AppPreferences,
        now: Date = Date()
    ) throws {
        guard let climate = ClimateLookup.climate(forZip: homeZip) else {
            preconditionFailure("The sample ZIP \(homeZip) is missing from the climate table")
        }
        preferences.saveHomeClimate(climate)

        let clock = SampleClock(now: now)
        for (index, name) in locationNames.enumerated() {
            context.insert(LocalLocation(
                id: id(5, index + 1), householdID: householdID, name: name, sortOrder: index,
                createdAt: clock.ms(-90), updatedAt: clock.ms(-90)))
        }
        for (index, tag) in tagSpecs.enumerated() {
            context.insert(LocalTag(
                id: id(4, index + 1), householdID: householdID, name: tag.name, color: tag.color,
                createdAt: clock.ms(-90), updatedAt: clock.ms(-90)))
        }
        for (index, spec) in seedSpecs.enumerated() {
            let stamp = clock.ms(-(80 - index * 2))
            context.insert(LocalSeed(
                id: id(1, index + 1), householdID: householdID, state: spec.state,
                packetCount: spec.packets, locationID: id(5, spec.location + 1),
                yearPacked: spec.year, source: spec.source, customName: spec.name,
                customCompany: spec.company, customType: spec.type, notes: spec.notes,
                tagIDs: spec.tags.map { id(4, $0 + 1) }, growingInfo: spec.info,
                createdAt: stamp, updatedAt: stamp))
        }
        for (index, bed) in bedSpecs.enumerated() {
            context.insert(LocalBed(
                id: id(2, index + 1), householdID: householdID, name: bed.name,
                bedDescription: bed.note, widthFeet: bed.width, lengthFeet: bed.length,
                sortOrder: index, createdAt: clock.ms(-70), updatedAt: clock.ms(-70)))
        }
        for (index, event) in plantingSpecs.enumerated() {
            let stamp = clock.ms(event.planned)
            context.insert(LocalPlantingEvent(
                id: id(3, index + 1), householdID: householdID,
                bedID: id(2, event.bed + 1), seedID: event.seed.map { id(1, $0 + 1) },
                kindRaw: event.kind.rawValue, plannedFor: clock.day(event.planned),
                completedAt: event.done ? stamp : nil, notes: event.notes,
                xFeet: event.position?.x, yFeet: event.position?.y,
                createdAt: clock.ms(-40), updatedAt: stamp))
        }
        for (index, entry) in journalSpecs.enumerated() {
            let entryID = id(6, index + 1)
            context.insert(LocalJournalEntry(
                id: entryID, householdID: householdID, occurredOn: clock.day(entry.age),
                body: entry.body, seedID: entry.seed.map { id(1, $0 + 1) },
                bedID: entry.bed.map { id(2, $0 + 1) }, plantingEventID: nil,
                createdAt: clock.ms(entry.age), updatedAt: clock.ms(entry.age), deletedAt: nil))
            for (itemIndex, item) in entry.checklist.enumerated() {
                context.insert(LocalJournalChecklistItem(
                    id: id(7, index * 10 + itemIndex + 1), entryID: entryID, text: item.text,
                    completed: item.done, sortOrder: itemIndex, updatedAt: clock.ms(entry.age)))
            }
        }
        try context.save()
    }

    // MARK: - Identifiers

    /// Deterministic UUID-shaped identifiers: `kind` is the model (1 seed, 2 bed, 3 planting event,
    /// 4 tag, 5 location, 6 journal entry, 7 checklist item) and `n` is 1-based.
    private static func id(_ kind: Int, _ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%04ld%08ld", kind, n)
    }

    // MARK: - Locations, tags, beds

    private static let locationNames = ["Seed box", "Garage shelf", "Kitchen drawer"]

    private static let tagSpecs: [(name: String, color: String)] = [
        ("Heirloom", "#7d5e3c"),
        ("Pollinator", "#7d9e3d"),
        ("Trial", "#295c8a"),
        ("Cut flower", "#c93f2c"),
    ]

    private struct BedSpec {
        let name: String
        let note: String
        let width: Double
        let length: Double
    }

    private static let bedSpecs = [
        BedSpec(name: "North bed", note: "Raised, full sun", width: 4, length: 8),
        BedSpec(name: "Herb bed", note: "By the back door", width: 3, length: 6),
    ]

    // MARK: - Seeds

    private struct SeedSpec {
        let name: String
        let type: String
        let company: String?
        let state: SeedState
        let source: SeedSource
        let packets: Int
        /// Index into `locationNames`.
        let location: Int
        let year: Int?
        /// Indexes into `tagSpecs`.
        let tags: [Int]
        let notes: String?
        let info: GrowingInfoSnapshot
    }

    private static let seedSpecs: [SeedSpec] = [
        // Active
        SeedSpec(name: "Brandywine", type: "Tomato", company: "Baker Creek", state: .active, source: .store,
                 packets: 1, location: 0, year: 2025, tags: [0], notes: "Save seed from the best fruit.",
                 info: growing("tender", "transplant", maturity: 75...90, germination: 6...14,
                               soil: 60...95, depth: 0.25, spacing: 24)),
        SeedSpec(name: "Genovese", type: "Basil", company: "Johnny's", state: .active, source: .store,
                 packets: 2, location: 1, year: 2026, tags: [], notes: nil,
                 info: growing("tender", "direct", maturity: 60...75, germination: 5...10,
                               soil: 70...90, depth: 0.25, spacing: 10)),
        SeedSpec(name: "Black Seeded Simpson", type: "Lettuce", company: nil, state: .active, source: .store,
                 packets: 1, location: 0, year: 2026, tags: [], notes: nil,
                 info: growing("hardy", "direct", maturity: 45...50, germination: 7...10,
                               soil: 40...75, depth: 0.125, spacing: 8)),
        SeedSpec(name: "Danvers 126", type: "Carrot", company: "Seed Savers", state: .active, source: .store,
                 packets: 1, location: 0, year: 2025, tags: [0], notes: nil,
                 info: growing("hardy", "direct", maturity: 70...75, germination: 10...17,
                               soil: 45...85, depth: 0.25, spacing: 2)),
        SeedSpec(name: "Cherry Belle", type: "Radish", company: nil, state: .active, source: .store,
                 packets: 1, location: 2, year: 2026, tags: [2], notes: "Trying it in the shade of the fence.",
                 info: growing("hardy", "direct", maturity: 22...30, germination: 3...10,
                               soil: 45...85, depth: 0.5, spacing: 2)),
        SeedSpec(name: "Bloomsdale", type: "Spinach", company: nil, state: .active, source: .store,
                 packets: 1, location: 2, year: 2025, tags: [], notes: nil,
                 info: growing("hardy", "direct", maturity: 42...46, germination: 7...14,
                               soil: 40...75, depth: 0.5, spacing: 3, sun: "partial")),
        SeedSpec(name: "Sugar Snap", type: "Pea", company: "Burpee", state: .active, source: .store,
                 packets: 1, location: 1, year: 2026, tags: [], notes: nil,
                 info: growing("hardy", "direct", maturity: 60...70, germination: 7...14,
                               soil: 40...75, depth: 1, spacing: 3)),
        SeedSpec(name: "Black Beauty", type: "Zucchini", company: nil, state: .active, source: .store,
                 packets: 1, location: 1, year: 2025, tags: [], notes: nil,
                 info: growing("tender", "direct", maturity: 50...60, germination: 5...10,
                               soil: 60...95, depth: 1, spacing: 36)),
        SeedSpec(name: "Marketmore 76", type: "Cucumber", company: nil, state: .active, source: .store,
                 packets: 1, location: 1, year: 2026, tags: [], notes: nil,
                 info: growing("tender", "direct", maturity: 55...65, germination: 3...10,
                               soil: 60...95, depth: 0.75, spacing: 12)),
        SeedSpec(name: "California Wonder", type: "Bell pepper", company: "Burpee", state: .active, source: .store,
                 packets: 1, location: 0, year: 2026, tags: [], notes: "Start indoors eight weeks ahead.",
                 info: growing("tender", "transplant", maturity: 70...90, germination: 8...21,
                               soil: 65...95, depth: 0.25, spacing: 18)),
        SeedSpec(name: "Lacinato", type: "Kale", company: nil, state: .active, source: .store,
                 packets: 1, location: 2, year: 2025, tags: [], notes: nil,
                 info: growing("hardy", "either", maturity: 60...70, germination: 4...7,
                               soil: 45...85, depth: 0.5, spacing: 12)),
        SeedSpec(name: "French Single Mix", type: "Marigold", company: nil, state: .active, source: .store,
                 packets: 1, location: 2, year: 2025, tags: [1], notes: "Good for the pollinators.",
                 info: growing("tender", "direct", maturity: 50...60, germination: 5...7,
                               soil: 60...85, depth: 0.25, spacing: 8)),
        // Wishlist
        SeedSpec(name: "Mammoth Russian", type: "Sunflower", company: "Baker Creek", state: .wishlist, source: .store,
                 packets: 0, location: 0, year: nil, tags: [3], notes: "For the fence line.",
                 info: growing("tender", "direct", maturity: 80...95, germination: 7...10,
                               soil: 55...85, depth: 1, spacing: 12)),
        SeedSpec(name: "Walla Walla", type: "Onion", company: nil, state: .wishlist, source: .store,
                 packets: 0, location: 0, year: nil, tags: [], notes: nil,
                 info: growing("hardy", "transplant", maturity: 105...120, germination: 7...10,
                               soil: 50...80, depth: 0.25, spacing: 4)),
        SeedSpec(name: "Santo", type: "Cilantro", company: nil, state: .wishlist, source: .store,
                 packets: 0, location: 2, year: nil, tags: [], notes: nil,
                 info: growing("hardy", "direct", maturity: 45...70, germination: 7...10,
                               soil: 50...75, depth: 0.25, spacing: 4)),
        // Saved from this garden
        SeedSpec(name: "Rattlesnake", type: "Pole bean", company: nil, state: .saved, source: .saved,
                 packets: 1, location: 1, year: 2026, tags: [0], notes: "Saved from the best pods last August.",
                 info: growing("tender", "direct", maturity: 60...70, germination: 7...10,
                               soil: 60...90, depth: 1, spacing: 6)),
        SeedSpec(name: "Empress of India", type: "Nasturtium", company: nil, state: .saved, source: .saved,
                 packets: 1, location: 0, year: 2025, tags: [1], notes: nil,
                 info: growing("tender", "direct", maturity: 50...60, germination: 7...12,
                               soil: 60...80, depth: 0.5, spacing: 10)),
        SeedSpec(name: "Mammoth", type: "Dill", company: nil, state: .saved, source: .saved,
                 packets: 1, location: 2, year: 2025, tags: [1], notes: nil,
                 info: growing("hardy", "direct", maturity: 40...60, germination: 7...14,
                               soil: 50...70, depth: 0.25, spacing: 12)),
        // Archived
        SeedSpec(name: "Detroit Dark Red", type: "Beet", company: "Burpee", state: .archived, source: .store,
                 packets: 0, location: 0, year: 2023, tags: [], notes: "Used up in 2024.",
                 info: growing("hardy", "direct", maturity: 50...60, germination: 5...10,
                               soil: 50...80, depth: 0.5, spacing: 3)),
        SeedSpec(name: "Purple Top White Globe", type: "Turnip", company: nil, state: .archived, source: .gift,
                 packets: 0, location: 2, year: 2023, tags: [], notes: nil,
                 info: growing("hardy", "direct", maturity: 50...60, germination: 4...7,
                               soil: 45...80, depth: 0.5, spacing: 4)),
    ]

    // MARK: - Plantings

    private struct PlantingSpec {
        let kind: PlantingEventKind
        /// Index into `bedSpecs`.
        let bed: Int
        /// Index into `seedSpecs`.
        let seed: Int?
        /// Days from today.
        let planned: Int
        let done: Bool
        let position: (x: Double, y: Double)?
        let notes: String?
    }

    private static let plantingSpecs: [PlantingSpec] = [
        PlantingSpec(kind: .sowing, bed: 0, seed: 2, planned: -30, done: true, position: (0.5, 0.5), notes: nil),
        PlantingSpec(kind: .sowing, bed: 0, seed: 3, planned: -21, done: true, position: (2.0, 0.5), notes: nil),
        PlantingSpec(kind: .transplant, bed: 0, seed: 0, planned: -7, done: true, position: (1.0, 4.0),
                     notes: "Two plants, staked."),
        PlantingSpec(kind: .sowing, bed: 0, seed: 6, planned: 3, done: false, position: (3.0, 6.5), notes: nil),
        PlantingSpec(kind: .note, bed: 0, seed: nil, planned: -3, done: true, position: nil,
                     notes: "Mulched the paths with straw."),
        PlantingSpec(kind: .transplant, bed: 1, seed: 1, planned: -10, done: true, position: (1.0, 1.0), notes: nil),
        PlantingSpec(kind: .sowing, bed: 1, seed: 17, planned: -2, done: true, position: (2.0, 3.0), notes: nil),
        PlantingSpec(kind: .harvest, bed: 1, seed: 1, planned: 14, done: false, position: (1.0, 1.0), notes: nil),
        PlantingSpec(kind: .sowing, bed: 1, seed: 11, planned: 7, done: false, position: (2.5, 5.0), notes: nil),
    ]

    // MARK: - Journal

    private struct ChecklistSpec {
        let text: String
        let done: Bool
    }

    private struct JournalSpec {
        /// Days from today.
        let age: Int
        let body: String
        let seed: Int?
        let bed: Int?
        let checklist: [ChecklistSpec]
    }

    private static let journalSpecs: [JournalSpec] = [
        JournalSpec(age: -2, body: "Dill is up along the back edge. Thinned to one plant every twelve inches.",
                    seed: 17, bed: 1, checklist: []),
        JournalSpec(age: -7, body: "Tomatoes went in after a week of hardening off. Watered in with diluted fish emulsion.",
                    seed: 0, bed: 0, checklist: [
                        ChecklistSpec(text: "Water in after planting", done: true),
                        ChecklistSpec(text: "Stake the leader", done: true),
                        ChecklistSpec(text: "Check for cutworms this week", done: false),
                    ]),
        JournalSpec(age: -14, body: "Lettuce is coming up well. Thinning next week.",
                    seed: 2, bed: 0, checklist: []),
        JournalSpec(age: -21, body: "Plan for fall: garlic in October and a second round of kale in the herb bed.",
                    seed: nil, bed: nil, checklist: [
                        ChecklistSpec(text: "Order garlic", done: false),
                        ChecklistSpec(text: "Sow kale indoors", done: false),
                        ChecklistSpec(text: "Clean the cold frame", done: true),
                    ]),
        JournalSpec(age: -30, body: "Last frost for this ZIP is usually early May. Peppers started indoors.",
                    seed: 9, bed: nil, checklist: [
                        ChecklistSpec(text: "Sow peppers indoors", done: true),
                        ChecklistSpec(text: "Set up the grow light", done: true),
                    ]),
    ]

    // MARK: - Growing info

    /// Growing info in the shape a catalog match or AI extraction would save. Only the fields
    /// the planting window reads are set, plus spacing and depth for the detail view.
    private static func growing(
        _ frost: String,
        _ sow: String,
        maturity: ClosedRange<Int>,
        germination: ClosedRange<Int>,
        soil: ClosedRange<Int>,
        depth: Double,
        spacing: Int,
        sun: String = "full"
    ) -> GrowingInfoSnapshot {
        GrowingInfoSnapshot(
            life_cycle: "annual",
            sun_requirement: sun,
            frost_tolerance: frost,
            sow_method: sow,
            seed_depth_inches: depth,
            days_to_germinate_min: germination.lowerBound,
            days_to_germinate_max: germination.upperBound,
            days_to_maturity_min: maturity.lowerBound,
            days_to_maturity_max: maturity.upperBound,
            soil_temp_min_f: soil.lowerBound,
            soil_temp_max_f: soil.upperBound,
            plant_spacing_inches: spacing
        )
    }
}

/// Day arithmetic from one launch-day reference, in the device's calendar and time zone.
private struct SampleClock {
    let now: Date

    func date(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
    }

    func ms(_ days: Int) -> Int64 {
        Int64(date(days).timeIntervalSince1970 * 1000)
    }

    /// `yyyy-MM-dd`, the form the models store days in.
    func day(_ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date(days))
    }
}
#endif
