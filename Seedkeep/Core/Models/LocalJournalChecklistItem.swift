import Foundation
import SwiftData

@Model
final class LocalJournalChecklistItem {
    @Attribute(.unique) var id: String
    var entryID: String
    var text: String
    var completed: Bool
    var sortOrder: Int
    var updatedAt: Int64

    init(id: String, entryID: String, text: String, completed: Bool,
         sortOrder: Int, updatedAt: Int64) {
        self.id = id
        self.entryID = entryID
        self.text = text
        self.completed = completed
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}
