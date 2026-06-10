import Foundation
import SwiftData

/// Phase 4D · SwiftData mirror of `CatalogCorrectionDTO`. One row per
/// catalog correction the user has filed (or that has flowed back from
/// the household via the `/api/catalog/corrections/mine` delta feed —
/// own + shared in v1).
///
/// Status lifecycle (server-authored, mirrored verbatim here):
///
///   `open` → `applied`     auto-approved by the moderation worker
///   `open` → `reviewed`    queued for the admin triage page
///   `open` → `dismissed`   bounds violation / low AI confidence / user-withdrawn
///   `reviewed` → `applied` admin approved via `/admin/corrections/:id/approve`
///   `reviewed` → `dismissed` admin dismissed via `/admin/corrections/:id/dismiss`
///   `dismissed` → `reviewed` user tapped "I'm sure — escalate to a human"
///                              (only when `dismissedReason == 'ai_low_confidence'`)
///
/// Lives in the app target so SwiftData doesn't bleed into `SeedkeepKit`
/// (which we want testable on macOS via `swift test`, no SwiftData
/// dependency). The DTO it mirrors lives in
/// `SeedkeepKit/Sources/SeedkeepKit/Models/CatalogCorrectionDTO.swift`
/// (created in the next Phase 4D iOS batch).
///
/// Soft-delete via `deletedAt` — corrections can be tombstoned by the
/// server-side household-membership-revoke trigger or by the admin
/// surface (Phase 5+). The local row stays put with `deletedAt`
/// populated so YouView's "your contributions" history can omit it
/// without needing a hard delete from disk.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §3 (file layout) and §4 (`CatalogCorrectionDTO`).
@Model
public final class LocalCatalogCorrection {
    /// Server-generated correction ID. Stable across devices; the
    /// notification scheduler keys deterministic identifiers off this
    /// (`seedkeep.notif.catalog.<id>`) so the cross-device dedup ledger
    /// works.
    @Attribute(.unique) public var id: String

    /// Parent catalog seed. `nil` after the server-side FK cascades
    /// `SET NULL` (catalog row removed but the audit history survives).
    /// `LocalCatalogCorrection` predates the catalog row deletion so we
    /// keep the row visible in YouView with a "catalog entry removed"
    /// fallback rather than orphan-deleting.
    public var catalogSeedID: String?

    /// Denormalized catalog entry name at submission time. Lets
    /// notification copy (`"Your fix to <name>'s germination range
    /// landed."`) work even when the user is offline and the local
    /// `CatalogSeedDTO` cache hasn't been hydrated yet, AND survives
    /// `catalog_seeds` deletion via the `SET NULL` cascade above.
    public var catalogSeedName: String?

    /// Which `catalog_seeds` column the correction targets. Must be a
    /// member of `CatalogFieldBounds.correctableFields`; the server
    /// enforces this in the migration 0020 CHECK constraint. `nil` for
    /// free-form ("Something else") submissions and legacy pre-4D
    /// feedback rows — UI surfaces those with a "Something else"
    /// fallback label.
    public var fieldName: String?

    /// One of `integer`, `numeric`, `enum`, `text`, `free_form`. Mirrors
    /// the server's `value_type` column. iOS uses this to pick the right
    /// editor shape (stepper, picker, single-line, multi-line) when
    /// surfacing the row in `ContributionDetailSheet` and the legacy
    /// `CatalogFeedbackSheet`. `nil` for free-form / legacy rows.
    public var valueType: String?

    /// The value the user proposed, as a string. The server stores the
    /// post-validation normalized form; iOS displays this verbatim.
    /// `nil` for free-form / legacy rows (the note lives in `body`).
    public var suggestedValue: String?

    /// The value the user *believed* was current at submission time —
    /// drives the optimistic-concurrency check in `decideCorrectionOutcome`.
    /// `nil` for legacy free-form submissions filed before Phase 4D.
    public var clientSeenValue: String?

    /// Free-text body. Optional in the structured flow; the server NEVER
    /// passes this to the AI moderator (it is logged only for the admin
    /// triage page and the post-hoc audit trail).
    public var body: String?

    /// Server-authored status. One of `open`, `reviewed`, `applied`,
    /// `dismissed`. Surfaced via the dedicated `CorrectionStatusPill`
    /// (Phase 4D iOS UI tier) with a palette distinct from
    /// `RecommendationVerdict`'s tokens.
    public var status: String

    /// AI rubric reviewer's score, 0..1. `nil` until the moderation
    /// worker has run. Only load-bearing AI signal in
    /// `decideCorrectionOutcome` (≥ 0.85 to clear auto-apply).
    public var aiReviewScore: Double?

    /// AI moderator's short note (≤ 240 chars server-side CHECK).
    /// Surfaced verbatim in `ContributionDetailSheet` so the user sees
    /// the reasoning when a correction is dismissed for
    /// `ai_low_confidence`.
    public var aiNotes: String?

    /// Machine-readable code populated when `status == 'dismissed'`.
    /// Stable values: `ai_low_confidence`, `out_of_bounds`,
    /// `invalid_enum`, `concurrent_conflict`, `recent_change`,
    /// `catalog_entry_unavailable`, `user_withdrawn`,
    /// `household_membership_revoked`, `ai_unauthorized_persistent`,
    /// `ai_max_attempts`, `user_escalated`. iOS branches on this for
    /// status-pill copy + the "escalate to a human" button visibility.
    public var dismissedReason: String?

    /// When two open corrections collide for the same `(catalogSeedID,
    /// fieldName)` with different values, the worker sets
    /// `conflictWithID` on both rows pointing at each other and flips
    /// both to `reviewed` with `dismissedReason='concurrent_conflict'`.
    public var conflictWithID: String?

    /// `true` when the user tapped "File anyway" on a bounds-violation
    /// warning. Short-circuits `decideCorrectionOutcome` to
    /// `queue_for_review` regardless of all other signals — the user has
    /// explicitly opted in for human review of an out-of-typical-range
    /// value.
    public var userAcknowledgedBounds: Bool

    /// Epoch ms — immutable after insert. Used as the secondary sort
    /// key in YouView (`updatedAt DESC, createdAt DESC`).
    public var createdAt: Int64

    /// Epoch ms — set when the worker (or admin) transitions the row
    /// out of `open`. `nil` for open rows.
    public var reviewedAt: Int64?

    /// Epoch ms — set when the catalog row was mutated. Only populated
    /// on `status == 'applied'` rows.
    public var appliedAt: Int64?

    /// Epoch ms — set when the user tapped "I'm sure — escalate to a
    /// human" on a `dismissed/ai_low_confidence` row. Drives the
    /// audit-trail timeline in `ContributionDetailSheet`.
    public var escalatedAt: Int64?

    /// Epoch ms — bumped on every server-side state change. Drives the
    /// `since=` cursor of `/api/catalog/corrections/mine` and the
    /// `CatalogCorrectionsChanged` notification's debounce window.
    public var updatedAt: Int64

    /// Epoch ms — set when the row has been tombstoned server-side
    /// (household-membership-revoke trigger, or admin hard-delete in a
    /// later phase). YouView omits rows with `deletedAt != nil` from
    /// the list view.
    public var deletedAt: Int64?

    /// Captured from `applied_patch.field_name` on the server response
    /// when the row transitions to `applied`. Identifies which
    /// `catalog_seeds` column changed so `SyncEngine` can invalidate the
    /// cached `CatalogSeedDTO` and `SeedDetailView` shows the new value
    /// immediately. `nil` until the applied transition lands.
    public var appliedFieldName: String?

    /// Captured from `applied_patch.new_value`. The post-apply value
    /// (already normalized) that the cached `CatalogSeedDTO` should be
    /// patched to. `nil` until the applied transition lands.
    public var appliedNewValue: String?

    public init(
        id: String,
        catalogSeedID: String? = nil,
        catalogSeedName: String? = nil,
        fieldName: String? = nil,
        valueType: String? = nil,
        suggestedValue: String? = nil,
        clientSeenValue: String? = nil,
        body: String? = nil,
        status: String,
        aiReviewScore: Double? = nil,
        aiNotes: String? = nil,
        dismissedReason: String? = nil,
        conflictWithID: String? = nil,
        userAcknowledgedBounds: Bool = false,
        createdAt: Int64,
        reviewedAt: Int64? = nil,
        appliedAt: Int64? = nil,
        escalatedAt: Int64? = nil,
        updatedAt: Int64,
        deletedAt: Int64? = nil,
        appliedFieldName: String? = nil,
        appliedNewValue: String? = nil
    ) {
        self.id = id
        self.catalogSeedID = catalogSeedID
        self.catalogSeedName = catalogSeedName
        self.fieldName = fieldName
        self.valueType = valueType
        self.suggestedValue = suggestedValue
        self.clientSeenValue = clientSeenValue
        self.body = body
        self.status = status
        self.aiReviewScore = aiReviewScore
        self.aiNotes = aiNotes
        self.dismissedReason = dismissedReason
        self.conflictWithID = conflictWithID
        self.userAcknowledgedBounds = userAcknowledgedBounds
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
        self.appliedAt = appliedAt
        self.escalatedAt = escalatedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.appliedFieldName = appliedFieldName
        self.appliedNewValue = appliedNewValue
    }
}
