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
}
