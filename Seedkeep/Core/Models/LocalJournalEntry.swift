import Foundation
import SwiftData

/// One journal entry — text body, optional attached entity (at most one of
/// seed/bed/plantingEvent), optional photos + checklist items (children).
///
/// Children are not modeled as `@Relationship` arrays here — SwiftData's
/// inverse-relationship migrations cost more than they save us, and the
/// sync engine treats each entity type as its own delta-sync table anyway.
/// Children fetch on demand via `@Query` with a predicate on entryID.
@Model
final class LocalJournalEntry {
    @Attribute(.unique) var id: String
    var householdID: String
    var occurredOn: String                 // 'YYYY-MM-DD'
    var body: String
    var seedID: String?
    var bedID: String?
    var plantingEventID: String?
    var createdAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?

    init(id: String, householdID: String, occurredOn: String, body: String,
         seedID: String?, bedID: String?, plantingEventID: String?,
         createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) {
        self.id = id
        self.householdID = householdID
        self.occurredOn = occurredOn
        self.body = body
        self.seedID = seedID
        self.bedID = bedID
        self.plantingEventID = plantingEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Which entity this entry is attached to, derived from the FK columns.
    enum ParentKind: Equatable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
        case garden
    }

    var parentKind: ParentKind {
        if let id = seedID { return .seed(id) }
        if let id = bedID { return .bed(id) }
        if let id = plantingEventID { return .plantingEvent(id) }
        return .garden
    }
}
