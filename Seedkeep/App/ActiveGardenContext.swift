import Foundation
import SeedkeepCloudKit

enum ActiveGardenContext {
    static let participantZoneNameDefaultsKey = "seedkeep.sharing.participant.zoneName"
    static let participantOwnerNameDefaultsKey = "seedkeep.sharing.participant.ownerName"

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
        guard let zoneName = defaults.string(forKey: participantZoneNameDefaultsKey),
              !zoneName.isEmpty,
              let ownerName = defaults.string(forKey: participantOwnerNameDefaultsKey),
              !ownerName.isEmpty else { return nil }
        return zoneName
    }
}
