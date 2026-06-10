import Foundation
import SwiftData

/// Single-row record (per household) tracking the last successful pull
/// cursor for each table. We key on `householdID` + `kind` so multi-
/// household scenarios in a future phase don't require a migration.
@Model
public final class LocalSyncCursor {
    @Attribute(.unique) public var id: String   // "<householdID>:<kind>"
    public var householdID: String
    public var kind: String                     // "locations" | "tags" | "seeds"
    public var cursor: Int64                    // updated_at watermark
    /// Tiebreaker id of the last item at the watermark (stabilization
    /// contract decision 9). Echoed back as `since_id` so rows sharing
    /// one `updated_at` millisecond can't be skipped across pages.
    /// `nil` for legacy servers that don't emit `cursor_id` — the pull
    /// then falls back to the strict `updated_at > since` behavior.
    public var cursorID: String?
    public var lastSyncedAt: Int64

    public init(
        householdID: String,
        kind: String,
        cursor: Int64,
        cursorID: String? = nil,
        lastSyncedAt: Int64
    ) {
        self.id = "\(householdID):\(kind)"
        self.householdID = householdID
        self.kind = kind
        self.cursor = cursor
        self.cursorID = cursorID
        self.lastSyncedAt = lastSyncedAt
    }

    public static func key(householdID: String, kind: String) -> String {
        "\(householdID):\(kind)"
    }
}
