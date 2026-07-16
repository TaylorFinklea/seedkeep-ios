import Testing
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
}
