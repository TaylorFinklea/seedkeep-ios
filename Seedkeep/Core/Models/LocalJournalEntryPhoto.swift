import Foundation
import SwiftData

@Model
final class LocalJournalEntryPhoto {
    @Attribute(.unique) var id: String
    var entryID: String
    var storageKey: String                 // S3 key — image URL is derived
    var sortOrder: Int
    var width: Int?
    var height: Int?
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, entryID: String, storageKey: String, sortOrder: Int,
         width: Int?, height: Int?, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.entryID = entryID
        self.storageKey = storageKey
        self.sortOrder = sortOrder
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
