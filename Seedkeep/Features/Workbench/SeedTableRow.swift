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
    ///
    /// Deleted seeds, locations and tags are skipped. Tag ids that no longer resolve keep their
    /// place in `tagIDs` (writes must not drop them) but are left out of `tagNames`.
    @MainActor
    static func rows(
        seeds: [LocalSeed],
        locations: [LocalLocation],
        tags: [LocalTag],
        recommendations: [String: LocalRecommendation]
    ) -> [SeedTableRow] {
        var locationNames: [String: String] = [:]
        for location in locations where location.deletedAt == nil {
            locationNames[location.id] = location.name
        }
        var tagNames: [String: String] = [:]
        for tag in tags where tag.deletedAt == nil {
            tagNames[tag.id] = tag.name
        }

        var rows: [SeedTableRow] = []
        rows.reserveCapacity(seeds.count)
        for seed in seeds where seed.deletedAt == nil {
            let verdict = seed.catalogID.flatMap { recommendations[$0] }?.verdict
            let verdictText: String
            if let verdict {
                verdictText = Self.verdictLabel(for: verdict)
            } else {
                verdictText = ""
            }
            let tagIDs = seed.tagIDs
            rows.append(SeedTableRow(
                id: seed.id,
                name: seed.displayName,
                variety: seed.customVariety?.trimmedNonEmpty ?? "",
                type: seed.customType?.trimmedNonEmpty ?? "",
                company: seed.customCompany?.trimmedNonEmpty ?? "",
                year: seed.yearPacked,
                packets: seed.packetCount,
                state: seed.stateRaw,
                locationID: seed.locationID,
                locationName: seed.locationID.flatMap { locationNames[$0] } ?? "",
                tagIDs: tagIDs,
                tagNames: tagIDs.compactMap { tagNames[$0] },
                notes: seed.notes ?? "",
                verdict: verdict,
                verdictLabel: verdictText,
                catalogID: seed.catalogID,
                updatedAt: seed.updatedAt
            ))
        }
        return rows
    }

    /// The verdict wording the app already uses (`RecommendationPanel`'s `VerdictInfo`), so the
    /// Library and the Workbench agree during the transition.
    static func verdictLabel(for raw: String) -> String {
        switch raw {
        case "plant_now": return "Plant now"
        case "plant_soon": return "Plant soon"
        case "too_early": return "Too early"
        case "late": return "Window closing"
        case "too_late": return "Missed this year"
        default: return "Checking…"
        }
    }

    /// Tag names joined the way the Tags column and the CSV show them.
    var tagsText: String {
        tagNames.joined(separator: "; ")
    }

    /// `year` as a non-optional sort key (Optional is not Comparable, which `TableColumn` needs).
    /// Blank years still sort last: the sort checks `year` itself for blankness.
    var yearSortKey: Int {
        year ?? 0
    }
}
