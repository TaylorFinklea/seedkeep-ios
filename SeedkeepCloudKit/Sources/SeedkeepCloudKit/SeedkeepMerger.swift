#if canImport(CloudKit)
import CloudKit
import Foundation

// Seedkeep field-merge resolver — the spike's highest-value unit-test target.
//
// Adapted from SimmerSmith's GroceryMerge/FieldMergeResolver.swift pattern, but
// Seedkeep's merge rules differ substantially. SimmerSmith patterns reused:
//   - Resolver as a pure-Swift enum with static merge functions
//   - CheckState pair-by-timestamp pattern (from GroceryItem.check)
//   - "sticky wins over stale LWW" as the framing for tombstone/pin semantics
//
// Seedkeep-specific adaptations (pave-own-path findings):
//   1. packetCount → min(local, remote): SimmerSmith has no consume-counter.
//      A naive LWW would pick the record with the latest updatedAt and lose a
//      concurrent decrement. min() correctly represents "both writes happened".
//   2. deletedAt → sticky-once-set: SimmerSmith's tombstone is isUserRemoved (Bool).
//      Seedkeep uses a nullable Int64 timestamp. The sticky rule: if either side
//      has a non-nil deletedAt, the result keeps it — even if the other side has
//      a newer updatedAt. A naive LWW would resurrect the row if the concurrent
//      edit's updatedAt is newer than the deletion's updatedAt.
//   3. tagIDs → set-union: SimmerSmith has no set-field merge. Tags are stored as
//      a JSON-encoded [String] array. Union merge preserves independent adds from
//      both writers; a naive LWW would drop one writer's additions entirely.
//   4. JournalChecklistItem (completed, updatedAt) as a UNIT: mirrors SimmerSmith's
//      CheckState triple-as-unit exactly, just without the `by` field.

// MARK: - RecordMerger protocol (CloudKit-bound)

/// Plugs into HouseholdSyncEngine's merger seam: consulted at the fetch-with-pending-edit
/// seam AND at serverRecordChanged. Mirrors SimmerSmith's RecordMerger exactly.
public protocol RecordMerger {
    func handles(_ recordType: String) -> Bool
    /// Merge local edit with server/remote version.
    /// `remote` carries the authoritative change tag; result writes merged fields onto a copy of it.
    func resolve(local: CKRecord, remote: CKRecord) -> MergeResult
}

// MARK: - SeedkeepRecordMerger

/// The Seedkeep field-merge resolver. Handles EVERY shared-zone record type:
/// Seed and JournalChecklistItem get custom rules; all others take an honest
/// LWW-by-`updatedAt` path (spec: "even records that are LWW-safe take the
/// resolver's default LWW path"). Routing all conflicts through the resolver
/// makes LWW deterministic-by-timestamp instead of the engine's blind
/// local-always-wins copy.
public struct SeedkeepRecordMerger: RecordMerger {
    public init() {}

    /// Handles any record type in the Seedkeep manifest.
    public func handles(_ recordType: String) -> Bool {
        SeedkeepRecordType.allCases.contains { $0.recordTypeName == recordType }
    }

    /// Dispatch is EXHAUSTIVE over `SeedkeepRecordType` (CaseIterable), not a string match ending
    /// in `default:` — a future record type is then a compile error here, not a silently-defaulted
    /// table entry (Photos-on-CloudKit D5).
    public func resolve(local: CKRecord, remote: CKRecord) -> MergeResult {
        guard let type = SeedkeepRecordType.type(forRecordTypeName: remote.recordType) else {
            // Unreachable in practice: DispatchingMerger only calls resolve() after `handles()`
            // confirmed the type is in the manifest. Never alias remote (see DispatchingMerger).
            return MergeResult(record: remote.copy() as! CKRecord, needsResave: false)
        }
        switch type {
        case .seed:
            return mergeSeed(local: local, remote: remote)
        case .journalChecklistItem:
            return mergeChecklistItem(local: local, remote: remote)
        case .seedPhoto, .journalEntryPhoto:
            return mergePhoto(local: local, remote: remote)
        case .household, .location, .tag, .bed, .plantingEvent, .journalEntry,
             .petDeparture, .migrationReceipt:
            // All other shared-zone types: honest whole-record LWW by updatedAt.
            return mergeDefaultLWW(local: local, remote: remote)
        }
    }

    // MARK: - Default LWW

    /// Whole-record last-write-wins by `updatedAt` (the product's existing sync contract),
    /// PLUS a universal sticky-tombstone re-assertion: a soft-delete (`deletedAt`) must never
    /// be resurrected by a concurrent stale edit, for ANY type that carries the field — not
    /// just Seed. Without this, a gardener deleting a bed on one device sees it reappear when
    /// their partner edits it concurrently on another.
    /// `result` is a COPY of remote (carries the change tag; leaves remote pristine for reads).
    /// Types with no `updatedAt`/`deletedAt` (the immutable photo types) take the plain LWW tie.
    /// Internal (not `private`) so the bulk-copy asset guard can be unit-tested directly: no
    /// manifest type routes through this path AND carries an asset field today (both photo types
    /// go through `mergePhoto`), so the guard needs a seam to prove it holds independent of dispatch.
    func mergeDefaultLWW(local: CKRecord, remote: CKRecord) -> MergeResult {
        let localUpdatedAt  = (local["updatedAt"]  as? Int) ?? 0
        let remoteUpdatedAt = (remote["updatedAt"] as? Int) ?? 0
        let localWasNewer   = localUpdatedAt > remoteUpdatedAt

        let result = remote.copy() as! CKRecord
        if localWasNewer {
            // General guard, for every type: never let the local-wins bulk copy carry a manifest
            // asset key. Photos route through `mergePhoto` today, but this neutralizes the
            // landmine even if some future asset-carrying type forgets its own merge case
            // (Photos-on-CloudKit D5).
            let assetKeys = Self.assetFieldNames(for: remote.recordType)
            for key in local.allKeys() where !assetKeys.contains(key) { result[key] = local[key] }
        }

        let remoteDeletedAt = remote["deletedAt"] as? Int
        let sticky = Self.stickyDeletedAt(local: local, remote: remote)
        if let d = sticky { result["deletedAt"] = d as CKRecordValue } else { result["deletedAt"] = nil }
        let didChangeDeleted = sticky != remoteDeletedAt

        return MergeResult(record: result, needsResave: localWasNewer || didChangeDeleted)
    }

    // MARK: - Photo merge (create + delete only; "replace" is delete-then-create)

    /// Photos are immutable once created (D5): `mergePhoto` always adopts remote verbatim, never
    /// marks the asset key changed (nothing here ever touches it), never resaves, and never writes
    /// `deletedAt` — hard delete via the parent cascade is the only removal path for either photo
    /// type.
    private func mergePhoto(local: CKRecord, remote: CKRecord) -> MergeResult {
        MergeResult(record: remote.copy() as! CKRecord, needsResave: false)
    }

    /// Manifest asset field names for a CloudKit record type name — used to keep bulk field copies
    /// (LWW's local-wins path) from ever carrying a CKAsset key.
    static func assetFieldNames(for recordTypeName: String) -> Set<String> {
        guard let type = SeedkeepRecordType.type(forRecordTypeName: recordTypeName) else { return [] }
        return Set(type.fields.filter { $0.type == .asset }.map(\.name))
    }

    // MARK: - Seed merge

    /// Merge two concurrent Seed record versions.
    ///
    /// Rules (spec §merge-semantics):
    ///   - packetCount → min(local, remote): consume-counter; two concurrent decrements must both stick.
    ///   - deletedAt → sticky: non-nil deletedAt wins even against a newer updatedAt (no resurrection).
    ///   - tagIDs → set union: concurrent independent adds from both writers are preserved.
    ///   - Everything else → LWW by updatedAt.
    private func mergeSeed(local: CKRecord, remote: CKRecord) -> MergeResult {
        let localUpdatedAt  = (local["updatedAt"]  as? Int) ?? 0
        let remoteUpdatedAt = (remote["updatedAt"] as? Int) ?? 0
        let localWasNewer   = localUpdatedAt > remoteUpdatedAt

        // The merged record is a COPY of `remote` so it carries the server's change tag while
        // leaving `remote` pristine. CKRecord is a reference type: mutating `remote` directly
        // (as `let result = remote` would) corrupts the field values BEFORE the custom-merge
        // reads run, degenerating min/union into "local wins" and silently dropping the other
        // device's writes. Copying lets us read remote's ORIGINAL values throughout.
        let result = remote.copy() as! CKRecord
        if localWasNewer {
            for key in local.allKeys() { result[key] = local[key] }
        }
        // Re-assert custom fields AFTER the LWW bulk copy, reading from the pristine `remote`.

        // 1. packetCount → min(local, remote) — consume-counter; two concurrent decrements
        //    must both stick. min() picks the smaller; a naive LWW would lose the older
        //    device's decrement. If only one side carries the field, use that side (never
        //    floor a missing field to 0 — that would zero a full packet).
        let localCount  = local["packetCount"]  as? Int
        let remoteCount = remote["packetCount"] as? Int
        let mergedCount = Self.minOptional(localCount, remoteCount)
        if let mergedCount { result["packetCount"] = mergedCount as CKRecordValue }

        // 2. deletedAt → sticky (once set on EITHER side, never resurrected by a concurrent
        //    stale edit). Commutative max so two devices converge on the same tombstone value.
        let remoteDeletedAt = remote["deletedAt"] as? Int
        let stickyDeletedAt = Self.stickyDeletedAt(local: local, remote: remote)
        if let d = stickyDeletedAt {
            result["deletedAt"] = d as CKRecordValue
        } else {
            result["deletedAt"] = nil
        }

        // 3. tagIDs → set union (JSON [String]). A naive LWW drops one writer's adds entirely;
        //    union preserves independent adds from both. NOTE: union is ADD-ONLY — a tag removed
        //    on one device is re-added if the other device holds it (no OR-Set tombstones). This
        //    is the spec's locked choice (never lose an add); removals must be re-applied if they
        //    race a concurrent edit. See tagRemovalIsAddOnly test.
        let localTags = local["tagIDs"] as? String
        let originalRemoteTags = remote["tagIDs"] as? String
        let mergedTags = Self.mergeTagIDs(local: localTags, remote: originalRemoteTags)
        // Only MATERIALIZE the field when a side actually had tags — don't write a spurious "[]"
        // onto a record neither side tagged (keeps the absent-optional invariant).
        if localTags != nil || originalRemoteTags != nil {
            result["tagIDs"] = mergedTags as CKRecordValue
        }

        // needsResave: true when local was newer (LWW pushed local fields) OR a custom rule
        // produced a value the server (the ORIGINAL remote) did not already hold — so the merged
        // state is pushed back. Compare against pristine-remote snapshots, by VALUE (tags as a
        // set, so re-sorted-but-equal JSON does not trigger a spurious resave).
        let didChangeCount   = mergedCount != remoteCount
        let didChangeDeleted = stickyDeletedAt != remoteDeletedAt
        let didChangeTags    = Self.decodeTagSet(mergedTags) != Self.decodeTagSet(originalRemoteTags)
        let needsResave = localWasNewer || didChangeCount || didChangeDeleted || didChangeTags

        return MergeResult(record: result, needsResave: needsResave)
    }

    // MARK: - JournalChecklistItem merge

    /// Resolve (completed, updatedAt) as a UNIT by latest updatedAt.
    ///
    /// Rule: take whichever side's updatedAt is newer as the authoritative
    /// (completed, updatedAt) pair. Never mix completed from one side with
    /// updatedAt from the other — that produces a torn state (a check that
    /// "happened in the future" or an uncheck that predates its own timestamp).
    ///
    /// A naive LWW would do the same here IF it operates on whole records.
    /// The test cases cover the scenario where a field-level LWW would tear
    /// (e.g. if completed and updatedAt were merged field-by-field independently).
    private func mergeChecklistItem(local: CKRecord, remote: CKRecord) -> MergeResult {
        let localUpdatedAt  = (local["updatedAt"]  as? Int) ?? 0
        let remoteUpdatedAt = (remote["updatedAt"] as? Int) ?? 0

        let result = remote.copy() as! CKRecord  // copy preserves the change tag; leaves remote pristine
        if localUpdatedAt > remoteUpdatedAt {
            // Local is the later write: copy ALL local fields (including completed) onto result.
            for key in local.allKeys() { result[key] = local[key] }
        }
        // If remote is newer (or tied), `result` already holds remote's fields — no-op needed.

        let localWasNewer = localUpdatedAt > remoteUpdatedAt
        return MergeResult(record: result, needsResave: localWasNewer)
    }

    // MARK: - Helpers

    /// tagIDs JSON merge: decode both sides, union, re-encode.
    /// Input: JSON string of the form `["a","b"]` (or nil / empty).
    static func mergeTagIDs(local: String?, remote: String?) -> String {
        let localSet  = decodeTagSet(local)
        let remoteSet = decodeTagSet(remote)
        let union     = localSet.union(remoteSet)
        return encodeTagSet(union)
    }

    static func decodeTagSet(_ json: String?) -> Set<String> {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let arr  = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    static func encodeTagSet(_ set: Set<String>) -> String {
        let sorted = set.sorted()   // deterministic output
        let data   = try? JSONEncoder().encode(sorted)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// min of two optional counts: both present → min; one present → that one; neither → nil.
    /// Never floors a missing consume-counter to 0.
    static func minOptional(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (x?, y?): return Swift.min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil):    return nil
        }
    }

    /// Sticky tombstone: the surviving `deletedAt` for two concurrent versions — commutative
    /// max of whatever non-nil values are present (nil when neither side is deleted). Once set
    /// on either side, a soft-delete is never resurrected.
    static func stickyDeletedAt(local: CKRecord, remote: CKRecord) -> Int? {
        [local["deletedAt"] as? Int, remote["deletedAt"] as? Int].compactMap { $0 }.max()
    }
}

// MARK: - DispatchingMerger

/// Composes multiple type-specific mergers behind the engine's single `merger` seam.
/// Mirrors SimmerSmith's DispatchingMerger exactly.
public struct DispatchingMerger: RecordMerger {
    public let mergers: [RecordMerger]
    public init(_ mergers: [RecordMerger]) { self.mergers = mergers }
    public func handles(_ recordType: String) -> Bool { mergers.contains { $0.handles(recordType) } }
    public func resolve(local: CKRecord, remote: CKRecord) -> MergeResult {
        for merger in mergers where merger.handles(remote.recordType) {
            return merger.resolve(local: local, remote: remote)
        }
        // unreachable (gated by handles()); copy to keep the never-alias-remote invariant.
        return MergeResult(record: remote.copy() as! CKRecord, needsResave: false)
    }
}
#endif
