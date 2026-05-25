import Foundation
import SwiftData

/// One Sprout chat thread. Multi-thread per household. Soft-delete via
/// `deletedAt`; the sync engine hard-deletes locally when the server soft-
/// deletes (cascading the local messages + tool calls via a cleanup helper).
@Model
final class LocalAssistantThread {
    @Attribute(.unique) var id: String
    var householdID: String
    var title: String
    var threadKind: String
    var createdAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?

    init(id: String, householdID: String, title: String, threadKind: String,
         createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) {
        self.id = id
        self.householdID = householdID
        self.title = title
        self.threadKind = threadKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
