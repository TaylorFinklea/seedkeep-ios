import Foundation
import SwiftData

/// Write-ahead log entry. Every optimistic local mutation enqueues one of
/// these in the same SwiftData transaction, so a crash between local
/// commit and server push doesn't lose data.
///
/// `payloadJSON` shape varies by `entityType` + `operation`:
///   - seed.create → `CreateSeedInput` JSON
///   - seed.update → `UpdateSeedInput` JSON
///   - seed.delete → `{ "id": "..." }` (id is on the row anyway)
///   - location.create → `{ "name": "...", "sort_order": Int }`
///   - location.update → `{ "name"?: "...", "sort_order"?: Int }`
///   - location.delete → `{ "id": "..." }`
///   - tag.create → `{ "name": "...", "color"?: "..." }`
///   - tag.update → `{ "name"?: "...", "color"?: nullable string }`
///   - tag.delete → `{ "id": "..." }`
@Model
public final class LocalPendingWrite {
    @Attribute(.unique) public var id: String
    public var entityType: String   // "seed" | "location" | "tag"
    public var entityID: String
    public var operation: String    // "create" | "update" | "delete"
    public var payloadJSON: String
    public var createdAt: Int64
    public var attemptCount: Int
    public var lastError: String?

    public init(
        id: String,
        entityType: String,
        entityID: String,
        operation: String,
        payloadJSON: String,
        createdAt: Int64,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}
