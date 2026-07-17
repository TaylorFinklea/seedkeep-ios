import Foundation
import SwiftData

/// R1 27d.18 — durable review-inbox registry for ambiguous participant journal rows. Every
/// stranded journal entry with no trustworthy FK evidence is quarantined here (left untouched,
/// already hidden by the active-garden filter) instead of being silently re-homed or discarded.
///
/// Deliberately NOT wiped by `HouseholdCloudCoordinator.wipeHouseholdSwiftData` (the 10 garden
/// types only) — it survives a future adopt wipe so `snapshotJSON` can still recreate the entry
/// via "Share to garden" after the live row is gone.
@Model
final class LocalJournalRecoveryItem {
    @Attribute(.unique) var id: String
    var scopeKey: String
    var snapshotJSON: String
    var detectedAt: Int64
    var status: String

    init(id: String, scopeKey: String, snapshotJSON: String, detectedAt: Int64, status: String) {
        self.id = id
        self.scopeKey = scopeKey
        self.snapshotJSON = snapshotJSON
        self.detectedAt = detectedAt
        self.status = status
    }
}
