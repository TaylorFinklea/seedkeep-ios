import Testing
import Foundation
@testable import Seedkeep

struct ActiveGardenContextTests {
    @Test("participant uses the owner household encoded in the shared zone")
    func participantUsesOwnerZoneHousehold() {
        #expect(
            ActiveGardenContext.householdID(
                signedInHouseholdID: "participant-household",
                participantZoneName: "seedkeep-owner-household",
                cloudKitSyncEnabled: true
            ) == "owner-household"
        )
    }

    @Test("owner keeps the signed-in server household")
    func ownerUsesSignedInHousehold() {
        #expect(
            ActiveGardenContext.householdID(
                signedInHouseholdID: "owner-household",
                participantZoneName: nil,
                cloudKitSyncEnabled: true
            ) == "owner-household"
        )
    }

    @Test("CloudKit rollback keeps the signed-in server household")
    func rollbackUsesSignedInHousehold() {
        #expect(
            ActiveGardenContext.householdID(
                signedInHouseholdID: "participant-household",
                participantZoneName: "seedkeep-owner-household",
                cloudKitSyncEnabled: false
            ) == "participant-household"
        )
    }

    @Test("a partial participant marker cannot redirect household work")
    func partialParticipantMarkerIsIgnored() {
        let suiteName = "ActiveGardenContextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            "seedkeep-owner-household",
            forKey: ActiveGardenContext.participantZoneNameDefaultsKey
        )
        #expect(ActiveGardenContext.participantZoneName(in: defaults) == nil)

        defaults.set(
            "_owner-record-name",
            forKey: ActiveGardenContext.participantOwnerNameDefaultsKey
        )
        #expect(
            ActiveGardenContext.participantZoneName(in: defaults)
                == "seedkeep-owner-household"
        )
    }

    @Test("participant and rollback scopes exclude parked Today data")
    func participantAndRollbackScopesExcludeParkedData() {
        let signedInHouseholdID = "signed-in-household"
        let ownerHouseholdID = "owner-household"
        let parkedHouseholdID = "parked-household"
        let participantZoneName = "seedkeep-owner-household"

        let participantActiveID = ActiveGardenContext.householdID(
            signedInHouseholdID: signedInHouseholdID,
            participantZoneName: participantZoneName,
            cloudKitSyncEnabled: true
        )
        let rollbackActiveID = ActiveGardenContext.householdID(
            signedInHouseholdID: signedInHouseholdID,
            participantZoneName: participantZoneName,
            cloudKitSyncEnabled: false
        )
        #expect(participantActiveID == ownerHouseholdID)
        #expect(rollbackActiveID == signedInHouseholdID)
        #expect(participantActiveID != rollbackActiveID)
        #expect(parkedHouseholdID != participantActiveID)
        #expect(parkedHouseholdID != rollbackActiveID)

        let activeEvent = makeTodayEvent(id: "active-event", householdID: participantActiveID)
        let parkedEvent = makeTodayEvent(id: "parked-event", householdID: parkedHouseholdID)
        let signedInEvent = makeTodayEvent(id: "signed-in-event", householdID: rollbackActiveID)
        let events = [activeEvent, parkedEvent, signedInEvent]

        let activeSeed = makeTodaySeed(id: "active-seed", householdID: participantActiveID)
        let parkedSeed = makeTodaySeed(id: "parked-seed", householdID: parkedHouseholdID)
        let signedInSeed = makeTodaySeed(id: "signed-in-seed", householdID: rollbackActiveID)
        let seeds = [activeSeed, parkedSeed, signedInSeed]

        let activeJournal = makeTodayJournal(id: "active-journal", householdID: participantActiveID)
        let parkedJournal = makeTodayJournal(id: "parked-journal", householdID: parkedHouseholdID)
        let signedInJournal = makeTodayJournal(id: "signed-in-journal", householdID: rollbackActiveID)
        let journals = [activeJournal, parkedJournal, signedInJournal]

        let activeDeparture = makeTodayDeparture(for: activeEvent.id)
        let parkedDeparture = makeTodayDeparture(for: parkedEvent.id)
        let signedInDeparture = makeTodayDeparture(for: signedInEvent.id)
        let departures = [activeDeparture, parkedDeparture, signedInDeparture]

        #expect(TodayHouseholdScope.events(events, householdID: participantActiveID).map(\.id) == [activeEvent.id])
        #expect(TodayHouseholdScope.seeds(seeds, householdID: participantActiveID).map(\.id) == [activeSeed.id])
        #expect(TodayHouseholdScope.journals(journals, householdID: participantActiveID).map(\.id) == [activeJournal.id])
        #expect(TodayHouseholdScope.departures(departures, belongingTo: events, householdID: participantActiveID).map(\.plantingEventID) == [activeEvent.id])

        #expect(TodayHouseholdScope.events(events, householdID: rollbackActiveID).map(\.id) == [signedInEvent.id])
        #expect(TodayHouseholdScope.seeds(seeds, householdID: rollbackActiveID).map(\.id) == [signedInSeed.id])
        #expect(TodayHouseholdScope.journals(journals, householdID: rollbackActiveID).map(\.id) == [signedInJournal.id])
        #expect(TodayHouseholdScope.departures(departures, belongingTo: events, householdID: rollbackActiveID).map(\.plantingEventID) == [signedInEvent.id])
    }

    private func makeTodayEvent(id: String, householdID: String) -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id,
            householdID: householdID,
            seedID: id.replacingOccurrences(of: "event", with: "seed"),
            kindRaw: "sowing",
            plannedFor: "2026-07-15",
            createdAt: 1,
            updatedAt: 1,
            petSeed: "pet-\(id)"
        )
    }

    private func makeTodaySeed(id: String, householdID: String) -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: householdID,
            state: .active,
            packetCount: 1,
            source: .store,
            customName: id,
            createdAt: 1,
            updatedAt: 1
        )
    }

    private func makeTodayJournal(id: String, householdID: String) -> LocalJournalEntry {
        LocalJournalEntry(
            id: id,
            householdID: householdID,
            occurredOn: "2026-07-15",
            body: id,
            seedID: nil,
            bedID: nil,
            plantingEventID: nil,
            createdAt: 1,
            updatedAt: 1,
            deletedAt: nil
        )
    }

    private func makeTodayDeparture(for eventID: String) -> LocalPetDeparture {
        LocalPetDeparture(
            plantingEventID: eventID,
            reason: "wilted_too_long",
            createdAt: 1,
            updatedAt: 1,
            departedAt: 1
        )
    }
}
