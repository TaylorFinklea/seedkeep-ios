import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Tests for `PetStateEngine` — the orchestrator that runs per-pet
/// day-ticks, materializes mood snapshots, advances streak counters,
/// and detects lifecycle transitions. Tests are deterministic: every
/// `tick` call passes an explicit `now` and the per-pet inputs are
/// shaped by the surrounding SwiftData rows.
///
/// Mood control strategy: with no `LocalJournalEntry` rows, the
/// resolver's loneliness + attention signals fall back to
/// `(now - event.createdAt)`. The watered-checklist signal stays nil
/// (neutral 60) unless we explicitly insert a `LocalJournalChecklistItem`
/// with text "watered" + completed. By tuning `createdAt` and the
/// watered item we can pin the pet at `.content`, `.wilted`, or
/// `.departingImminent` per the spec-locked anchors.
@MainActor
@Suite("PetStateEngine — Phase 5.1.1 lifecycle orchestrator")
struct PetStateEngineTests {

    // MARK: - Test fixture

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "petStateEngineTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static let householdID = "hh_test"

    private static func msFor(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Build a planting event whose `createdAt` is `daysAgo` days before
    /// `now` (used to drive the loneliness + attention fallback path).
    @MainActor
    private static func insertEvent(
        id: String,
        daysAgo: Int,
        now: Date,
        context: ModelContext,
        completedAt: Int64? = nil
    ) -> LocalPlantingEvent {
        let createdMs = msFor(now.addingTimeInterval(TimeInterval(-daysAgo * 86_400)))
        let event = LocalPlantingEvent(
            id: id,
            householdID: householdID,
            kindRaw: "sowing",
            plannedFor: "2026-01-01",
            completedAt: completedAt,
            createdAt: createdMs,
            updatedAt: createdMs,
            petSeed: "seed_\(id)",
            petRarity: "common",
            petCreatureKind: "garden_worm",
            petName: "Pip",
            petSpawnedAt: createdMs
        )
        context.insert(event)
        try? context.save()
        return event
    }

    /// Insert a "watered" checklist item attached to a journal entry on
    /// the planting, with the completion timestamp `wateredDaysAgo`
    /// days before `now` and the journal entry's `createdAt`
    /// `entryDaysAgo` days before `now`. Separating the two lets a
    /// fixture pin loneliness (driven by latest-journal-entry) and
    /// thirst (driven by latest watered-item) independently — which
    /// matters because the resolver's loneliness fallback uses the
    /// event's `createdAt` when no entry exists, but uses the entry's
    /// `createdAt` once one does.
    @MainActor
    private static func insertWateredItem(
        plantingEventID: String,
        wateredDaysAgo: Int,
        entryDaysAgo: Int? = nil,
        now: Date,
        context: ModelContext
    ) {
        let wateredMs = msFor(now.addingTimeInterval(TimeInterval(-wateredDaysAgo * 86_400)))
        let entryMs = msFor(now.addingTimeInterval(
            TimeInterval(-(entryDaysAgo ?? wateredDaysAgo) * 86_400)
        ))
        let entryID = "je_\(plantingEventID)"
        let entry = LocalJournalEntry(
            id: entryID,
            householdID: householdID,
            occurredOn: "2026-01-01",
            body: "",
            seedID: nil,
            bedID: nil,
            plantingEventID: plantingEventID,
            createdAt: entryMs,
            updatedAt: entryMs,
            deletedAt: nil
        )
        let item = LocalJournalChecklistItem(
            id: "ci_\(plantingEventID)",
            entryID: entryID,
            text: "Watered",
            completed: true,
            sortOrder: 0,
            updatedAt: wateredMs
        )
        context.insert(entry)
        context.insert(item)
        try? context.save()
    }

    /// Sanity check the fixtures resolve to the expected mood label.
    @MainActor
    private static func currentMood(
        event: LocalPlantingEvent,
        now: Date,
        context: ModelContext
    ) -> PetMoodLabel {
        let inputs = PetMoodResolver.resolveInputs(
            event: event,
            now: now,
            context: context
        )
        return MoodEngine.compute(inputs).label
    }

    // MARK: - Mood-fixture sanity tests

    @Test("fixture: 30d-old event + watered-10d-ago + stale journal resolves to .departingImminent")
    func fixtureDepartingImminent() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_di",
            daysAgo: 30,
            now: now,
            context: context
        )
        // Watered 10d ago (thirst=0) + journal entry created 60d ago
        // (loneliness=0) + no photos (attention falls back to
        // event.createdAt=30d → ~25) → composite ≈ 22 → `.departingImminent`.
        Self.insertWateredItem(
            plantingEventID: "pe_di",
            wateredDaysAgo: 10,
            entryDaysAgo: 60,
            now: now,
            context: context
        )
        #expect(Self.currentMood(event: event, now: now, context: context) == .departingImminent)
    }

    @Test("fixture: 21d-old event no watered resolves to .wilted")
    func fixtureWilted() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_w",
            daysAgo: 21,
            now: now,
            context: context
        )
        let mood = Self.currentMood(event: event, now: now, context: context)
        // 21-day-old fallback: loneliness=15, attention=40, thirst
        // neutral 60, impatience/companionship neutral 60. Weighted
        // ≈ 46 → `.wilted` (30-49 inclusive).
        #expect(mood == .wilted)
    }

    @Test("fixture: 0d-old event resolves to .content (no `.alive` mood enum — alive is a phase)")
    func fixtureContent() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_c",
            daysAgo: 0,
            now: now,
            context: context
        )
        let mood = Self.currentMood(event: event, now: now, context: context)
        // 0-day-old fallback: loneliness=100, attention=100, others
        // neutral 60. Weighted ≈ 76. `.content` (75-89).
        #expect(mood == .content)
    }

    // MARK: - Transition: alive → wilted

    @Test("alive → wilted emits .aliveToWilted on first .wilted tick")
    func aliveToWiltedTransition() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_atw",
            daysAgo: 21,
            now: now,
            context: context
        )
        // First tick — the engine's `priorPhase` defaults to `.alive`
        // (no prior snapshot exists) and the resolved mood is
        // `.wilted` per the fixture.
        let result = PetStateEngine.tick(event: event, context: context, now: now)
        try? context.save()
        #expect(result == .aliveToWilted(eventID: "pe_atw"))
        // Streak does NOT advance for wilted — only `.departingImminent`.
        #expect(event.petWiltedStreakDays == 0)
    }

    // MARK: - Transition: wilted → departing

    @Test("wilted → departing emits .wiltedToDeparting on first .departingImminent tick")
    func wiltedToDepartingTransition() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Day-1 (yesterday): pet was wilted.
        let day1 = now.addingTimeInterval(-86_400)
        let event = Self.insertEvent(
            id: "pe_wtd",
            daysAgo: 30,
            now: now,
            context: context
        )
        // Pre-seed a wilted snapshot for "yesterday" so the engine sees
        // .wilted as the prior phase.
        let yesterdayKey = ymdString(for: day1)
        context.insert(LocalPetMoodSnapshot(
            plantingEventID: "pe_wtd",
            dayYMD: yesterdayKey,
            moodLabel: PetMoodLabel.wilted.rawValue,
            compositeScore: 40,
            createdAt: Self.msFor(day1)
        ))
        try? context.save()
        // Add watered-10d-ago + stale-journal so today's mood is
        // `.departingImminent`.
        Self.insertWateredItem(
            plantingEventID: "pe_wtd",
            wateredDaysAgo: 10,
            entryDaysAgo: 60,
            now: now,
            context: context
        )

        let result = PetStateEngine.tick(event: event, context: context, now: now)
        try? context.save()
        #expect(result == .wiltedToDeparting(eventID: "pe_wtd"))
        // First day-tick at .departingImminent — streak should now be 1.
        #expect(event.petWiltedStreakDays == 1)
    }

    // MARK: - Transition: departing → departed (5 day streak)

    @Test("departing → departed fires only after 5 cross-midnight day-ticks")
    func departingToDepartedAfterFiveStreak() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_dep",
            daysAgo: 60,
            now: baseDate,
            context: context
        )
        Self.insertWateredItem(
            plantingEventID: "pe_dep",
            wateredDaysAgo: 20,
            entryDaysAgo: 60,
            now: baseDate,
            context: context
        )

        // Tick across 5 consecutive calendar days. The first 4 should
        // either emit `.wiltedToDeparting` (day 1) or nothing
        // (departing→departing is a no-op transition); the 5th should
        // emit `.departingToDeparted` once the streak hits 5.
        var transitions: [PetStateEngine.Transition?] = []
        for dayOffset in 0..<5 {
            let tickAt = baseDate.addingTimeInterval(TimeInterval(dayOffset * 86_400))
            let t = PetStateEngine.tick(event: event, context: context, now: tickAt)
            transitions.append(t)
        }
        try? context.save()

        #expect(event.petWiltedStreakDays == 5)
        #expect(transitions[4] == .departingToDeparted(eventID: "pe_dep"))
        // The first tick has no prior snapshot → prior phase defaults
        // to `.alive`, so the engine's transition is alive→departing
        // (mapped to nil by the default arm — see PetStateEngine
        // `transition(from:to:eventID:)`). Ticks 2-4 are
        // departing→departing (nil).
        #expect(transitions[1] == nil)
        #expect(transitions[2] == nil)
        #expect(transitions[3] == nil)
    }

    // MARK: - Same-day re-tick must NOT advance streak

    @Test("same-day re-tick at .departingImminent does NOT advance streak")
    func sameDayNoIncrement() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_sd",
            daysAgo: 30,
            now: now,
            context: context
        )
        Self.insertWateredItem(
            plantingEventID: "pe_sd",
            wateredDaysAgo: 10,
            entryDaysAgo: 60,
            now: now,
            context: context
        )

        // First tick: streak 0 → 1.
        _ = PetStateEngine.tick(event: event, context: context, now: now)
        #expect(event.petWiltedStreakDays == 1)
        // 100 same-calendar-day re-ticks (foregrounding the app).
        for offsetSec in stride(from: 60, through: 6000, by: 60) {
            let later = now.addingTimeInterval(TimeInterval(offsetSec))
            _ = PetStateEngine.tick(event: event, context: context, now: later)
        }
        try? context.save()
        #expect(event.petWiltedStreakDays == 1)
    }

    // MARK: - Cross-midnight advances exactly once per day

    @Test("cross-midnight tick at .departingImminent advances streak by 1")
    func crossMidnightIncrement() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_cm",
            daysAgo: 60,
            now: baseDate,
            context: context
        )
        Self.insertWateredItem(
            plantingEventID: "pe_cm",
            wateredDaysAgo: 20,
            entryDaysAgo: 60,
            now: baseDate,
            context: context
        )

        // Day 1: streak 0 → 1.
        _ = PetStateEngine.tick(event: event, context: context, now: baseDate)
        #expect(event.petWiltedStreakDays == 1)
        // Day 2 (24h later): streak 1 → 2.
        let day2 = baseDate.addingTimeInterval(86_400)
        _ = PetStateEngine.tick(event: event, context: context, now: day2)
        #expect(event.petWiltedStreakDays == 2)
        // Day 3: streak 2 → 3.
        let day3 = baseDate.addingTimeInterval(2 * 86_400)
        _ = PetStateEngine.tick(event: event, context: context, now: day3)
        #expect(event.petWiltedStreakDays == 3)
        try? context.save()
    }

    // MARK: - Recovery is silent

    @Test("departing → alive (recovery) emits .recoveredToAlive, resets streak, no notification side-effect needed")
    func recoveryFromDeparting() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_rec",
            daysAgo: 60,
            now: baseDate,
            context: context
        )
        Self.insertWateredItem(
            plantingEventID: "pe_rec",
            wateredDaysAgo: 20,
            entryDaysAgo: 60,
            now: baseDate,
            context: context
        )

        // Build up to streak=2 via 2 day-ticks at .departingImminent.
        _ = PetStateEngine.tick(event: event, context: context, now: baseDate)
        let day2 = baseDate.addingTimeInterval(86_400)
        _ = PetStateEngine.tick(event: event, context: context, now: day2)
        #expect(event.petWiltedStreakDays == 2)

        // Now the user waters the plant TODAY (day3). Delete the old
        // watered item and insert a fresh one to drop daysSinceWatered
        // back to 0 and recover toward `.content`.
        let day3 = baseDate.addingTimeInterval(2 * 86_400)
        // Wipe the existing watered checklist + journal entry first.
        let entryDescriptor = FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.plantingEventID == "pe_rec" }
        )
        for entry in (try? context.fetch(entryDescriptor)) ?? [] {
            context.delete(entry)
        }
        let itemDescriptor = FetchDescriptor<LocalJournalChecklistItem>(
            predicate: #Predicate { $0.entryID == "je_pe_rec" }
        )
        for item in (try? context.fetch(itemDescriptor)) ?? [] {
            context.delete(item)
        }
        try? context.save()
        // Insert a fresh watered+journal for "today" (day3) so
        // daysSinceWatered=0 → thirst=100, AND the journal entry's
        // createdAt is day3 → loneliness=0. The pet recovers from
        // `.departingImminent` to `.quiet` (composite ~73) — phase
        // `.alive`.
        Self.insertWateredItem(
            plantingEventID: "pe_rec",
            wateredDaysAgo: 0,
            entryDaysAgo: 0,
            now: day3,
            context: context
        )

        let result = PetStateEngine.tick(event: event, context: context, now: day3)
        try? context.save()
        #expect(result == .recoveredToAlive(eventID: "pe_rec"))
        #expect(event.petWiltedStreakDays == 0)
    }

    // MARK: - Terminal-state guards

    @Test("graduated pets (completedAt != nil) never tick — returns nil, streak unchanged")
    func graduatedPetNeverTicks() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = Self.msFor(now)
        let event = Self.insertEvent(
            id: "pe_grad",
            daysAgo: 30,
            now: now,
            context: context,
            completedAt: nowMs
        )
        Self.insertWateredItem(
            plantingEventID: "pe_grad",
            wateredDaysAgo: 10,
            entryDaysAgo: 60,
            now: now,
            context: context
        )

        // 20 day-ticks across 20 calendar days. None should advance
        // the streak; no transition should fire; no snapshot row
        // should be written.
        for dayOffset in 0..<20 {
            let tickAt = now.addingTimeInterval(TimeInterval(dayOffset * 86_400))
            let t = PetStateEngine.tick(event: event, context: context, now: tickAt)
            #expect(t == nil)
        }
        try? context.save()
        #expect(event.petWiltedStreakDays == 0)
        let snapDescriptor = FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { $0.plantingEventID == "pe_grad" }
        )
        let snapshots = (try? context.fetch(snapDescriptor)) ?? []
        #expect(snapshots.isEmpty)
    }

    @Test("deleted pets (deletedAt != nil) never tick")
    func deletedPetNeverTicks() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_del",
            daysAgo: 30,
            now: now,
            context: context
        )
        event.deletedAt = Self.msFor(now)
        try? context.save()

        let t = PetStateEngine.tick(event: event, context: context, now: now)
        #expect(t == nil)
        #expect(event.petWiltedStreakDays == 0)
    }

    @Test("non-pet plantings (petSeed == nil) never tick")
    func nonPetEventsNeverTick() {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = LocalPlantingEvent(
            id: "pe_nopet",
            householdID: Self.householdID,
            kindRaw: "sowing",
            plannedFor: "2026-01-01",
            createdAt: Self.msFor(now),
            updatedAt: Self.msFor(now),
            petSeed: nil
        )
        context.insert(event)
        try? context.save()

        let t = PetStateEngine.tick(event: event, context: context, now: now)
        #expect(t == nil)
    }

    // MARK: - performSideEffects: departing → departed fires the depart RPC

    @Test("performSideEffects(departingToDeparted:) POSTs /depart and upserts LocalPetDeparture")
    func departingToDepartedFiresRPC() async throws {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        // Seed the parent planting so the upsert path can find it and
        // apply the bumped `updated_at`.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.insertEvent(
            id: "pe_rpc",
            daysAgo: 60,
            now: now,
            context: context
        )

        // Canned server response. Mirrors the `WireResponses.PetDepartureOne`
        // envelope shape — `planting_event` + `departure`, snake_case
        // throughout, wrapped in the standard `{ ok: true, data: ... }`
        // envelope `SeedkeepClient.perform` expects.
        let bumpedUpdatedAt = event.updatedAt + 1
        let departedAt = Self.msFor(now)
        let goodbyeJSON = #"{"note_text":"It was a fine ride.","signoff":"— Pip","fallback":false,"fallback_attempts":0,"last_attempt_at":1800000000000}"#
        // Encode the goodbye_note as a JSON-string field (the server
        // stores it as TEXT, so it round-trips as an escaped string).
        let escapedGoodbye = goodbyeJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let responseJSON = """
        {
          "ok": true,
          "data": {
            "planting_event": {
              "id": "pe_rpc",
              "household_id": "\(Self.householdID)",
              "bed_id": null,
              "seed_id": null,
              "catalog_seed_id": null,
              "kind": "sowing",
              "planned_for": "2026-01-01",
              "completed_at": null,
              "notes": null,
              "x_feet": null,
              "y_feet": null,
              "created_at": \(event.createdAt),
              "updated_at": \(bumpedUpdatedAt),
              "deleted_at": null,
              "pet_seed": "seed_pe_rpc",
              "pet_rarity": "common",
              "pet_creature_kind": "garden_worm",
              "pet_name": "Pip",
              "pet_personality": null,
              "pet_spawned_at": \(event.petSpawnedAt ?? 0)
            },
            "departure": {
              "planting_event_id": "pe_rpc",
              "household_id": "\(Self.householdID)",
              "goodbye_note": "\(escapedGoodbye)",
              "reason": "wilted_too_long",
              "departed_at": \(departedAt),
              "created_at": \(departedAt),
              "updated_at": \(departedAt),
              "deleted_at": null
            }
          }
        }
        """

        // Spin up a mocked URLSession that intercepts the depart POST and
        // returns the canned envelope. Mirrors how `SeedkeepClient` says
        // tests should stub the network (file-top doc comment).
        let session = MockURLProtocol.makeSession(
            responseBody: Data(responseJSON.utf8),
            statusCode: 200
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            )
        )

        await PetStateEngine.performSideEffects(
            for: [.departingToDeparted(eventID: "pe_rpc")],
            client: client,
            container: container
        )

        // Assert the depart row landed.
        let depDescriptor = FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { $0.plantingEventID == "pe_rpc" }
        )
        let rows = (try? context.fetch(depDescriptor)) ?? []
        #expect(rows.count == 1)
        let dep = try #require(rows.first)
        #expect(dep.reason == "wilted_too_long")
        #expect(dep.fallback == false)
        #expect(dep.departedAt == departedAt)
        #expect(dep.goodbyeNote?.noteText == "It was a fine ride.")
        #expect(dep.goodbyeNote?.signoff == "— Pip")

        // Assert the URL hit matches the documented route.
        let captured = MockURLProtocol.lastRequest()
        let path = try #require(captured?.url?.path)
        #expect(path == "/api/pets/pe_rpc/depart")
        #expect(captured?.httpMethod == "POST")
    }

    // MARK: - Helpers

    /// Match `PetStateEngine.dayYMDString(for:)` — local calendar
    /// `YYYY-MM-DD`. Test-local helper since the engine version is
    /// private.
    private func ymdString(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 1970,
                      comps.month ?? 1,
                      comps.day ?? 1)
    }
}

// MARK: - URLProtocol-based network stub
//
// `SeedkeepClient.perform` reads through whatever `URLSession` its
// `Configuration` carries. Injecting a custom session backed by this
// `URLProtocol` lets the test deliver canned responses without spinning
// up a real server, and captures the issued request for assertions.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var captured: URLRequest?
    static let lock = NSLock()

    static func makeSession(responseBody: Data, statusCode: Int) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        MockURLProtocol.responseBody = responseBody
        MockURLProtocol.statusCode = statusCode
        MockURLProtocol.captured = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured = request
        let body = Self.responseBody
        let status = Self.statusCode
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
