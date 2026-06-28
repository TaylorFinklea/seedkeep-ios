import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// R1 — client-side soft-delete cascade parity (G5), mirroring the server's DELETE cascade.
@MainActor
struct HouseholdCascadeTests {

    private func ctx() -> ModelContext {
        ModelContext(makeTestContainer(name: "cascade-\(UUID().uuidString)"))
    }
    private func pe(_ id: String, hid: String, seedID: String? = nil, bedID: String? = nil, updatedAt: Int64 = 1) -> LocalPlantingEvent {
        let m = LocalPlantingEvent(id: id, householdID: hid, kindRaw: "sowing", plannedFor: "2026-01-01", createdAt: 1, updatedAt: updatedAt)
        m.seedID = seedID; m.bedID = bedID
        return m
    }
    private func je(_ id: String, hid: String, seedID: String? = nil, bedID: String? = nil, peID: String? = nil) -> LocalJournalEntry {
        LocalJournalEntry(id: id, householdID: hid, occurredOn: "2026-01-01", body: "x",
                          seedID: seedID, bedID: bedID, plantingEventID: peID, createdAt: 1, updatedAt: 1, deletedAt: nil)
    }

    @Test("a soft-deleted Seed cascades to its PlantingEvents + JournalEntries; unrelated rows untouched")
    func seedCascade() throws {
        let c = ctx(); let hid = "hh1"
        let seed = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1)
        seed.deletedAt = 9_000
        c.insert(seed)
        c.insert(pe("pe1", hid: hid, seedID: "s1"))           // child → cascades
        c.insert(pe("pe2", hid: hid, seedID: "other"))        // unrelated → stays
        c.insert(je("je1", hid: hid, seedID: "s1"))           // child → cascades
        c.insert(je("je2", hid: hid, seedID: "other"))        // unrelated → stays
        try c.save()

        #expect(try HouseholdCascade.apply(in: c, now: 10_000) == true)
        #expect(fetchPE(c, "pe1")?.deletedAt == 10_000)
        #expect(fetchPE(c, "pe2")?.deletedAt == nil)
        #expect(fetchJE(c, "je1")?.deletedAt == 10_000)
        #expect(fetchJE(c, "je2")?.deletedAt == nil)
        #expect(fetchPE(c, "pe1")?.updatedAt == 10_000, "cascaded child gets a bumped clock so it pushes")
    }

    @Test("a soft-deleted Bed cascades to its PlantingEvents + JournalEntries")
    func bedCascade() throws {
        let c = ctx(); let hid = "hh1"
        let bed = LocalBed(id: "b1", householdID: hid, name: "North", createdAt: 1, updatedAt: 1)
        bed.deletedAt = 9_000
        c.insert(bed)
        c.insert(pe("pe1", hid: hid, bedID: "b1"))
        c.insert(je("je1", hid: hid, bedID: "b1"))
        try c.save()
        #expect(try HouseholdCascade.apply(in: c, now: 10_000) == true)
        #expect(fetchPE(c, "pe1")?.deletedAt == 10_000)
        #expect(fetchJE(c, "je1")?.deletedAt == 10_000)
    }

    @Test("transitive: deleting a Seed cascades to its PE, then to a JournalEntry referencing that PE")
    func transitiveCascade() throws {
        let c = ctx(); let hid = "hh1"
        let seed = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1)
        seed.deletedAt = 9_000
        c.insert(seed)
        c.insert(pe("pe1", hid: hid, seedID: "s1"))          // cascaded from the seed
        c.insert(je("je1", hid: hid, peID: "pe1"))           // references the PE → must also cascade
        try c.save()
        #expect(try HouseholdCascade.apply(in: c, now: 10_000) == true)
        #expect(fetchPE(c, "pe1")?.deletedAt == 10_000)
        #expect(fetchJE(c, "je1")?.deletedAt == 10_000, "a JournalEntry on a transitively-deleted PE must cascade")
    }

    @Test("idempotent: a second apply changes nothing")
    func idempotent() throws {
        let c = ctx(); let hid = "hh1"
        let seed = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1)
        seed.deletedAt = 9_000
        c.insert(seed)
        c.insert(pe("pe1", hid: hid, seedID: "s1"))
        try c.save()
        #expect(try HouseholdCascade.apply(in: c, now: 10_000) == true)
        #expect(try HouseholdCascade.apply(in: c, now: 20_000) == false, "nothing left to cascade")
        #expect(fetchPE(c, "pe1")?.deletedAt == 10_000, "the tombstone clock is not re-stamped")
    }

    private func fetchPE(_ c: ModelContext, _ id: String) -> LocalPlantingEvent? {
        try? c.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })).first
    }
    private func fetchJE(_ c: ModelContext, _ id: String) -> LocalJournalEntry? {
        try? c.fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })).first
    }
}
