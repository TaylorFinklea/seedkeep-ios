// One Seeds-table row (redesign R1). The SHAPE is a parent-owned contract; slice B owns the
// mapping (`rows(...)`) and may extend it, but keeps these fields and their meaning.
import Foundation

/// A value snapshot of a seed for display, sorting, filtering, search, CSV and the palette.
/// Built from SwiftData rows; never edited directly (edits go through `SyncEngine`).
struct SeedTableRow: Identifiable, Hashable, Sendable {
    let id: String
    /// What the Library shows today (`LocalSeed.displayName`).
    var name: String
    var variety: String
    var type: String
    var company: String
    var year: Int?
    var packets: Int
    /// `SeedState` raw value: active, wishlist, saved, archived.
    var state: String
    var locationID: String?
    var locationName: String
    var tagIDs: [String]
    var tagNames: [String]
    var notes: String
    /// `LocalRecommendation.verdict` raw value, or nil when there is no recommendation.
    var verdict: String?
    /// Human verdict label as the app already words it, or "" when none.
    var verdictLabel: String
    var catalogID: String?
    var updatedAt: Int64
}

extension SeedTableRow {
    /// Maps live models to rows. SLICE B owns this body (replace the placeholder); the shell
    /// (slice A) calls it once per data change to feed the table, sidebar count and palette.
    /// `recommendations` is keyed by catalog id: fetch them once, never per row.
    @MainActor
    static func rows(
        seeds: [LocalSeed],
        locations: [LocalLocation],
        tags: [LocalTag],
        recommendations: [String: LocalRecommendation]
    ) -> [SeedTableRow] {
        []
    }
}
