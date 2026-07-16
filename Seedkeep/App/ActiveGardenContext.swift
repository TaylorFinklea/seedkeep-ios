import Foundation
import SeedkeepCloudKit

enum ActiveGardenContext {
    static let participantZoneNameDefaultsKey = "seedkeep.sharing.participant.zoneName"

    static func householdID(
        signedInHouseholdID: String,
        participantZoneName: String?,
        cloudKitSyncEnabled: Bool
    ) -> String {
        guard cloudKitSyncEnabled, let participantZoneName, !participantZoneName.isEmpty else {
            return signedInHouseholdID
        }
        return SeedkeepRecordNames.householdID(fromZoneName: participantZoneName)
    }

    static func participantZoneName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: participantZoneNameDefaultsKey)
    }
}
