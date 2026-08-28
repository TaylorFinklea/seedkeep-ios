#if canImport(CloudKit)
import CloudKit
import Foundation

// Household graph copy planning — the pure half of transfer-by-copy account deletion
// (.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md §Verification).
//
// The deleting owner fetches every record in the source zone and hands them here with the
// successor-owned destination zone ID. The planner returns save batches that reproduce the garden
// exactly: same record type, same record NAME (the deterministic `type:id` key), same application
// fields, with every in-zone reference retargeted into the destination zone and its action
// preserved. Cross-DB ids (G4) point outside the household and stay untouched.
//
// Three contracts this file owns:
//
// ORDERING. CloudKit rejects a `.deleteSelf` reference to a record that does not exist yet, so
// records are batched by cascade generation — batch `i` must be fully saved before batch `i+1`.
// Within a batch the order is (record type, record name), so two runs produce the same wire order.
//
// UPSERT. Destination records are freshly constructed and therefore carry NO destination change
// tag. Under CloudKit's default save policy that is a `serverRecordChanged` conflict against any
// record ID that already exists — and one always does: the successor must create and share the
// destination Household root before the copy starts, and a resumed copy re-saves everything the
// interrupted attempt already landed. So the plan carries `.allKeys` and `execute` applies it;
// deterministic record names only give idempotency in combination with that policy.
//
// FAIL CLOSED. An unrecognised record type or an undeclared key throws instead of being skipped.
// Skipping would drop the same data from the copy AND from both digests, so a truncated
// destination would verify as equal to a truncated source and authorise deleting the original.
// Only CloudKit's reserved record types (CKShare and friends) are excluded.
//
// Planning is pure: nothing here touches CloudKit and nothing mutates a source CKRecord.

// MARK: - Plan

public struct HouseholdGraphCopyPlan {
    public let destinationZoneID: CKRecordZone.ID
    /// Cascade generations. Save batch `i` to completion before starting batch `i+1`.
    public let batches: [[CKRecord]]
    /// Every planned record, flattened in batch order.
    public let records: [CKRecord]
    /// CloudKit record type name → planned record count, matching `HouseholdGraphDigest.counts`.
    public let counts: [String: Int]
    /// REQUIRED, not advisory: the copy is only idempotent when every batch is saved with this
    /// policy. See the UPSERT note above.
    public let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys
}

/// Saves one batch of destination records with the plan's required save policy. The live
/// implementation wraps `CKModifyRecordsOperation`; tests substitute an in-memory zone.
public typealias HouseholdGraphBatchSaver =
    (_ records: [CKRecord], _ savePolicy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> Void

public enum HouseholdGraphCopyError: Error, Equatable, CustomStringConvertible {
    /// The destination is the source zone — a "copy" would overwrite the original in place and the
    /// subsequent source deletion would take the only copy with it.
    case destinationIsSource(zoneName: String)
    /// A non-system record type this build's manifest does not declare. Copying around it would
    /// silently drop app data that both digests would then also omit.
    case unknownRecordType(recordType: String, recordName: String)
    /// A key on a manifest record that the manifest does not declare — the same hazard, one level
    /// down (a newer build added a field this build would drop).
    case undeclaredField(recordType: String, recordName: String, field: String)
    /// A record in the snapshot does not belong to the source zone. Copying it would import a
    /// foreign record into the successor's garden.
    case recordOutsideSourceZone(recordName: String, zoneName: String)
    /// An in-zone reference points outside the source zone, so it cannot be retargeted by
    /// substituting the destination zone.
    case referenceOutsideSourceZone(recordName: String, field: String, zoneName: String)
    /// Two records share a record name but not their content. One would silently overwrite the
    /// other in the destination zone.
    case conflictingDuplicate(recordName: String)
    /// A `.deleteSelf` child whose parent is missing from the snapshot. CloudKit would reject the
    /// save, and a partially-saved graph must never be mistaken for a complete transfer.
    case missingCascadeParent(recordName: String, field: String, parent: String)
    /// A manifest-declared field holds a value the manifest cannot describe.
    case unsupportedValue(recordType: String, recordName: String, field: String)
    /// `.deleteSelf` references form a cycle, so no parent-before-child order exists.
    case cascadeCycle([String])

    public var description: String {
        switch self {
        case .destinationIsSource(let zone):
            return "destination zone \(zone) is the source zone"
        case .unknownRecordType(let type, let name):
            return "record \(name) has unknown record type \(type); this build cannot copy it"
        case .undeclaredField(let type, let name, let field):
            return "\(type) \(name) carries undeclared field \(field); this build cannot copy it"
        case .recordOutsideSourceZone(let name, let zone):
            return "record \(name) lives in zone \(zone), not the source zone"
        case .referenceOutsideSourceZone(let name, let field, let zone):
            return "record \(name) field \(field) references zone \(zone), not the source zone"
        case .conflictingDuplicate(let name):
            return "record name \(name) appears twice with conflicting content"
        case .missingCascadeParent(let name, let field, let parent):
            return "record \(name) field \(field) cascades from missing parent \(parent)"
        case .unsupportedValue(let type, let name, let field):
            return "\(type) \(name) field \(field) holds a value the manifest cannot describe"
        case .cascadeCycle(let names):
            return "cascade cycle among \(names.joined(separator: ", "))"
        }
    }
}

// MARK: - Copier

public enum HouseholdGraphCopier {

    /// Plan the destination-zone writes that reproduce `records`. Pure: same input, same plan.
    ///
    /// `assetHashes` supplies the OBSERVED sha256 for every asset field (Photos-on-CloudKit D3),
    /// keyed by the SOURCE record's name+field. Defaults to `[:]`, so an asset-free graph plans
    /// exactly as before; a graph carrying an asset field with no matching entry fails closed (see
    /// `CanonicalFieldValue.read`) rather than silently copying an unobserved value.
    public static func plan(
        _ records: [CKRecord],
        from sourceZoneID: CKRecordZone.ID,
        to destinationZoneID: CKRecordZone.ID,
        assetHashes: [AssetRef: String] = [:]
    ) throws -> HouseholdGraphCopyPlan {
        guard sourceZoneID != destinationZoneID else {
            throw HouseholdGraphCopyError.destinationIsSource(zoneName: sourceZoneID.zoneName)
        }

        var planned: [String: PlannedRecord] = [:]
        var cascadeEdges: [CascadeEdge] = []

        for record in records {
            // CloudKit's own reserved records are per-owner state, not garden data.
            guard !CloudKitSystemRecords.isSystemType(record.recordType) else { continue }
            let recordName = record.recordID.recordName
            guard let type = SeedkeepRecordType.type(forRecordTypeName: record.recordType) else {
                throw HouseholdGraphCopyError.unknownRecordType(
                    recordType: record.recordType, recordName: recordName)
            }
            guard record.recordID.zoneID == sourceZoneID else {
                throw HouseholdGraphCopyError.recordOutsideSourceZone(
                    recordName: recordName, zoneName: record.recordID.zoneID.zoneName)
            }
            if let undeclared = CanonicalRecordEncoder.undeclaredKeys(of: record, as: type).first {
                throw HouseholdGraphCopyError.undeclaredField(
                    recordType: type.recordTypeName, recordName: recordName, field: undeclared)
            }

            let built = try copy(record, as: type, from: sourceZoneID, to: destinationZoneID,
                                 assetHashes: assetHashes)

            if let existing = planned[recordName] {
                // A retry can legitimately hand the same record twice; conflicting content cannot.
                guard existing.canonical == built.canonical else {
                    throw HouseholdGraphCopyError.conflictingDuplicate(recordName: recordName)
                }
                continue
            }
            planned[recordName] = built
            cascadeEdges.append(contentsOf: built.cascadeEdges)
        }

        // Deterministic regardless of snapshot order, so the reported failure is reproducible.
        cascadeEdges.sort { ($0.child, $0.field) < ($1.child, $1.field) }
        for edge in cascadeEdges where planned[edge.parent] == nil {
            throw HouseholdGraphCopyError.missingCascadeParent(
                recordName: edge.child, field: edge.field, parent: edge.parent)
        }

        let batches = try batched(planned, cascadeEdges: cascadeEdges)
        let flattened = batches.flatMap { $0 }
        var counts: [String: Int] = [:]
        for record in flattened { counts[record.recordType, default: 0] += 1 }

        return HouseholdGraphCopyPlan(destinationZoneID: destinationZoneID,
                                      batches: batches,
                                      records: flattened,
                                      counts: counts)
    }

    /// Save every batch in dependency order under the plan's required save policy. Re-running after
    /// a failure is safe and expected: the same record IDs are overwritten with the same content.
    public static func execute(_ plan: HouseholdGraphCopyPlan,
                               saving save: HouseholdGraphBatchSaver) async throws {
        for batch in plan.batches {
            try await save(batch, plan.savePolicy)
        }
    }

    // MARK: Record copy

    private struct CascadeEdge {
        let child: String
        let field: String
        let parent: String
    }

    private struct PlannedRecord {
        let record: CKRecord
        /// Zone-independent content fingerprint, used only to tell an exact duplicate apart from a
        /// conflicting one.
        let canonical: String
        let cascadeEdges: [CascadeEdge]
    }

    /// Build the destination record. The source CKRecord is only ever READ — the copy is a fresh
    /// object carrying nothing but manifest-declared application state, so CloudKit system metadata
    /// (change tags, the `parent` pointer, share references) never rides along.
    private static func copy(
        _ record: CKRecord,
        as type: SeedkeepRecordType,
        from sourceZoneID: CKRecordZone.ID,
        to destinationZoneID: CKRecordZone.ID,
        assetHashes: [AssetRef: String]
    ) throws -> PlannedRecord {
        let recordName = record.recordID.recordName
        let destination = CKRecord(
            recordType: record.recordType,
            recordID: CKRecord.ID(recordName: recordName, zoneID: destinationZoneID))

        var encoded: [(name: String, value: String)] = []
        var cascadeEdges: [CascadeEdge] = []

        for field in type.fields {
            guard let raw = record[field.name] else { continue }
            let assetHash = assetHashes[AssetRef(recordName: recordName, field: field.name)]
            guard let value = CanonicalFieldValue.read(raw, as: field.type, assetHash: assetHash) else {
                throw HouseholdGraphCopyError.unsupportedValue(
                    recordType: type.recordTypeName, recordName: recordName, field: field.name)
            }
            guard let copiedValue = value.copiedCKValue else {
                throw HouseholdGraphCopyError.unsupportedValue(
                    recordType: type.recordTypeName, recordName: recordName, field: field.name)
            }
            destination[field.name] = copiedValue
            encoded.append((field.name, value.canonicalEncoding))
        }

        for spec in type.refs {
            guard let raw = record[spec.name] else { continue }
            switch spec.kind {
            case .crossDBString:
                // Points outside the household zone entirely (the global catalog) — never rewritten.
                guard let value = raw as? String else {
                    throw HouseholdGraphCopyError.unsupportedValue(
                        recordType: type.recordTypeName, recordName: recordName, field: spec.name)
                }
                destination[spec.name] = value as CKRecordValue
            case .setNullInZone, .cascadeParent:
                guard let reference = raw as? CKRecord.Reference else {
                    throw HouseholdGraphCopyError.unsupportedValue(
                        recordType: type.recordTypeName, recordName: recordName, field: spec.name)
                }
                guard reference.recordID.zoneID == sourceZoneID else {
                    throw HouseholdGraphCopyError.referenceOutsideSourceZone(
                        recordName: recordName, field: spec.name,
                        zoneName: reference.recordID.zoneID.zoneName)
                }
                let target = reference.recordID.recordName
                // Same target name, destination zone, SAME ACTION: a soft link must not harden into
                // a cascade (or vice versa) or the successor's delete behaviour would silently change.
                destination[spec.name] = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: target, zoneID: destinationZoneID),
                    action: reference.action)
                // The runtime action, not the manifest kind, is what CloudKit enforces at save time.
                if reference.action == .deleteSelf {
                    cascadeEdges.append(CascadeEdge(child: recordName, field: spec.name, parent: target))
                }
            }
            guard let value = CanonicalRecordEncoder.encodeReference(raw, kind: spec.kind) else {
                throw HouseholdGraphCopyError.unsupportedValue(
                    recordType: type.recordTypeName, recordName: recordName, field: spec.name)
            }
            encoded.append((spec.name, value))
        }

        encoded.sort { $0.name < $1.name }
        let canonical = ([record.recordType] + encoded.map { "\($0.name)=\($0.value)" })
            .joined(separator: "\n")
        return PlannedRecord(record: destination, canonical: canonical, cascadeEdges: cascadeEdges)
    }

    // MARK: Cascade ordering

    /// Group records into cascade generations: a record lands one batch after its deepest
    /// `.deleteSelf` parent. Within a generation the order is (record type, record name).
    private static func batched(
        _ planned: [String: PlannedRecord],
        cascadeEdges: [CascadeEdge]
    ) throws -> [[CKRecord]] {
        guard !planned.isEmpty else { return [] }

        var parents: [String: [String]] = [:]
        for edge in cascadeEdges { parents[edge.child, default: []].append(edge.parent) }

        var generation: [String: Int] = [:]
        var pending = Set(planned.keys)
        while !pending.isEmpty {
            var resolved: [String: Int] = [:]
            for name in pending {
                var depth = 0
                var ready = true
                for parent in parents[name] ?? [] {
                    guard let parentDepth = generation[parent] else { ready = false; break }
                    depth = max(depth, parentDepth + 1)
                }
                if ready { resolved[name] = depth }
            }
            guard !resolved.isEmpty else {
                throw HouseholdGraphCopyError.cascadeCycle(pending.sorted())
            }
            for (name, depth) in resolved {
                generation[name] = depth
                pending.remove(name)
            }
        }

        var buckets: [[CKRecord]] = Array(repeating: [], count: (generation.values.max() ?? 0) + 1)
        for (name, depth) in generation {
            // `planned[name]` is present by construction: `generation` is keyed off `planned`.
            if let record = planned[name]?.record { buckets[depth].append(record) }
        }
        for index in buckets.indices {
            buckets[index].sort {
                ($0.recordType, $0.recordID.recordName) < ($1.recordType, $1.recordID.recordName)
            }
        }
        return buckets
    }
}
#endif
