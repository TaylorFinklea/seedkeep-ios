import Foundation
import SwiftData

/// Retired server write queue (N3). Nothing creates, sends or changes these
/// rows any more: rows older builds left in the store stay as they were, and
/// the model stays so existing stores open unchanged. The rest of this
/// comment describes the retired lifecycle.
///
/// Lifecycle:
/// 1. Insert with `attemptCount = 0`, `nextAttemptAt = createdAt`.
/// 2. Each `flushPending()` pass that touches this row bumps `attemptCount`
///    and sets `nextAttemptAt = now + backoff(attemptCount)` on failure.
/// 3. After `maxAttempts` failures the row is marked dead-lettered
///    (`isDeadLettered = true`) — it stops retrying until the user
///    manually triggers it from Settings → Pending writes.
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
    public var entityType: String
    public var entityID: String
    public var operation: String
    public var payloadJSON: String
    public var createdAt: Int64
    public var attemptCount: Int
    public var lastError: String?
    /// Earliest epoch-ms at which this row may be retried. Default = createdAt.
    public var nextAttemptAt: Int64
    /// Once true, `flushPending()` skips this row. The user can manually
    /// retry from Settings → Pending writes (resets backoff and clears flag).
    public var isDeadLettered: Bool

    /// Cap on automatic retries before dead-lettering. Phase 1 picks a
    /// gentle bound; tune if real-world data shows transient failures
    /// recovering past this.
    public static let maxAttempts: Int = 6

    public init(
        id: String,
        entityType: String,
        entityID: String,
        operation: String,
        payloadJSON: String,
        createdAt: Int64,
        attemptCount: Int = 0,
        lastError: String? = nil,
        nextAttemptAt: Int64? = nil,
        isDeadLettered: Bool = false
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.isDeadLettered = isDeadLettered
    }

    /// Exponential backoff: 0s, 2s, 4s, 8s, 16s, 32s, ... capped at 5 min.
    /// Pure function so tests can lock the curve.
    public static func backoffMillis(forAttempt attempt: Int) -> Int64 {
        if attempt <= 0 { return 0 }
        let base: Int64 = 2_000
        let raw = base << min(attempt - 1, 8)  // doubles up to attempt 9
        return min(raw, 300_000)
    }
}
