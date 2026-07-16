import Foundation
import SwiftData

/// Durable CloudKit hard-delete intent. The intent is committed in the same
/// SwiftData transaction that removes the local row, then cleared only after
/// the household coordinator confirms that its pending changes drained.
@Model
final class LocalCloudKitDeletion {
    @Attribute(.unique) var id: String
    var scopeID: String
    var householdID: String
    var recordName: String
    var createdAt: Int64

    init(scopeID: String, householdID: String, recordName: String, createdAt: Int64) {
        self.id = "\(scopeID)|\(recordName)"
        self.scopeID = scopeID
        self.householdID = householdID
        self.recordName = recordName
        self.createdAt = createdAt
    }
}
