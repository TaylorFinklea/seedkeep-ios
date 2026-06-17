import Foundation

// Seedkeep CloudKit data layer (R1) — record type manifest.
//
// Adapted from SimmerSmith's HouseholdRecordType + HouseholdRecordValue DSL, but the
// roster + field shapes + reference graph + merge rules are Seedkeep's own — validated
// independently against the iOS SwiftData models (the source of truth for what flows
// through sync) and the server's delete-cascade behaviour. SimmerSmith is a reference,
// not a template.
//
// Field provenance: every scalar/ref below mirrors a column on the corresponding
// `Local*` SwiftData model (Seedkeep/Core/Models/Local*.swift). `householdID` is NOT a
// field on any record — the zone IS the household boundary (zone name `seedkeep-<id>`),
// so a per-record householdID would only invite zone/field disagreement.
//
// Reference-graph derivation (server delete handlers, grep-verified 2026-06-17):
//   - Seed delete   → soft-cascades planting_events + journal_entries (seed_id); hard-deletes seed_photos.
//   - Bed delete    → soft-cascades planting_events + journal_entries (bed_id).
//   - PlantingEvent delete → soft-cascades journal_entries (planting_event_id); pet_departures ON DELETE CASCADE.
//   - JournalEntry delete  → soft-deletes the entry; photos + checklist items hard-deleted via their own routes.
// Hence:
//   - `.deleteSelf` cascadeParent (single-parent, hard-deleted leaves OR true cascade):
//       SeedPhoto→Seed, JournalEntryPhoto→JournalEntry, JournalChecklistItem→JournalEntry, PetDeparture→PlantingEvent.
//   - `.none` setNullInZone (soft-deletable records with ≥1 parent; the soft-delete cascade
//      runs client-side, NOT via CloudKit's hard `.deleteSelf`):
//       Seed→Location, PlantingEvent→{Bed,Seed}, JournalEntry→{Seed,Bed,PlantingEvent}.
//   - crossDBString (target lives outside the household zone — the global catalog, R2/R3):
//       Seed.catalogID, PlantingEvent.catalogSeedID.
//   The spec listed `Bed→PlantingEvent` under BOTH cascadeParent and setNull; resolved to
//   setNull because PlantingEvent is soft-deletable AND has two possible parents — it cannot
//   be a single `.deleteSelf` hard-cascade child.

// MARK: - Scalar field types

/// CloudKit scalar field types. `bool` is stored as INT64 0/1 (G3: Bool→INT64).
public enum CKFieldType: Equatable {
    case string, int, double, date, bool
}

public struct FieldSpec: Equatable {
    public let name: String
    public let type: CKFieldType
    public let queryable: Bool
    public let sortable: Bool
    public init(_ name: String, _ type: CKFieldType, queryable: Bool = false, sortable: Bool = false) {
        self.name = name; self.type = type; self.queryable = queryable; self.sortable = sortable
    }
}

// MARK: - Reference types

/// How a foreign key encodes onto CloudKit (mirrors SimmerSmith RefKind — validated for Seedkeep).
public enum RefKind: Equatable {
    /// In-zone CKReference with action `.deleteSelf` — deleting the target cascades to this record.
    case cascadeParent
    /// In-zone CKReference with action `.none` — a dangling target nulls locally.
    case setNullInZone
    /// Plain STRING recordName key, NOT a CKReference. Target may live in a different DB
    /// (G4: cross-DB refs as String, never CKReference).
    case crossDBString
}

public struct RefSpec: Equatable {
    public let name: String
    public let kind: RefKind
    /// Target record type name (documentation; the codec encodes the concrete recordName from the value).
    public let target: String
    public init(_ name: String, _ kind: RefKind, target: String) {
        self.name = name; self.kind = kind; self.target = target
    }
}

// MARK: - recordName policy

public enum RecordNamePolicy: Equatable {
    /// recordName == the legacy String primary key, verbatim (preserve-id for migration).
    case pk
    /// recordName is a deterministic key built from known fields.
    case det
}

// MARK: - Scalar transport value

/// Pure Swift scalar (no CloudKit dependency). Used in CloudKitRecordValue and the merger.
public enum ScalarValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case date(Date)
    case bool(Bool)
}

// MARK: - Generic record value (transport bag)

/// Pure transport value for a Seedkeep household record — what the codec encodes
/// to / decodes from a CKRecord, driven by the SeedkeepRecordType manifest.
/// Generic field-bag: keeps the codec testable without bespoke structs per type.
public struct CloudKitRecordValue: Equatable {
    public let type: SeedkeepRecordType
    public let recordName: String
    /// Scalar field name → value. Omitted fields = absent (optional columns stay absent).
    public var scalars: [String: ScalarValue]
    /// Reference field name → target recordName. Absent key = null on the record.
    public var refs: [String: String]

    public init(type: SeedkeepRecordType, recordName: String,
                scalars: [String: ScalarValue] = [:], refs: [String: String] = [:]) {
        self.type = type
        self.recordName = recordName
        self.scalars = scalars
        self.refs = refs
    }
}

// MARK: - Seedkeep record type manifest (full R1 roster: 11 garden types + 1 infra record)

/// Seedkeep's CloudKit shared-zone record types: the full household garden graph (11 types)
/// plus `migrationReceipt`, the one-time idempotency record the upgrade migration writes (G12).
public enum SeedkeepRecordType: String, CaseIterable, Equatable {
    case household
    case location
    case tag
    case seed
    case seedPhoto
    case bed
    case plantingEvent
    case journalEntry
    case journalEntryPhoto
    case journalChecklistItem
    case petDeparture
    /// Infrastructure record (NOT garden data): the per-household migration idempotency receipt
    /// (G12 / AC3). Included so `allCKDSL()` emits its schema and the deployed container can store it.
    case migrationReceipt

    /// CloudKit record type name (PascalCase, matches the deployed schema).
    public var recordTypeName: String {
        switch self {
        case .household:            return "Household"
        case .location:             return "Location"
        case .tag:                  return "Tag"
        case .seed:                 return "Seed"
        case .seedPhoto:            return "SeedPhoto"
        case .bed:                  return "Bed"
        case .plantingEvent:        return "PlantingEvent"
        case .journalEntry:         return "JournalEntry"
        case .journalEntryPhoto:    return "JournalEntryPhoto"
        case .journalChecklistItem: return "JournalChecklistItem"
        case .petDeparture:         return "PetDeparture"
        case .migrationReceipt:     return "MigrationReceipt"
        }
    }

    /// recordName policy. Every garden type preserves its existing id (migration invariant D5);
    /// `PetDeparture` preserves its `plantingEventID` (1:1 with the parent planting). The
    /// `migrationReceipt` is the lone deterministic-key record (keyed on householdID, no row id).
    public var namePolicy: RecordNamePolicy {
        self == .migrationReceipt ? .det : .pk
    }

    /// Scalar (non-reference) field declarations. Timestamps are INT64 unix-millis
    /// (matching the `Int64` columns on the SwiftData models); `updatedAt` is the merge clock.
    public var fields: [FieldSpec] {
        switch self {
        case .household:
            // Root record — the CKShare anchor. The household's geographic/home location
            // stays in AppPreferences (recommendations are R4), so the root is just identity.
            return [
                F("name", .string, queryable: true),
                F("createdAt", .int),
                F("updatedAt", .int),
            ]

        case .location:
            // Seed storage location (e.g. "Garage shelf") — NOT the household's geographic location.
            return [
                F("name", .string, queryable: true),
                F("sortOrder", .int),
                F("createdAt", .int),
                F("updatedAt", .int),
                // deletedAt: soft-delete tombstone. Sticky against resurrection via the merger's
                // universal sticky-deletedAt rule (mergeDefaultLWW), same as every other type.
                F("deletedAt", .int),
            ]

        case .tag:
            return [
                F("name", .string, queryable: true),
                F("color", .string),
                F("createdAt", .int),
                F("updatedAt", .int),
                F("deletedAt", .int),       // soft-delete tombstone (sticky via mergeDefaultLWW)
            ]

        case .seed:
            // Custom merge: packetCount (min), deletedAt (sticky), tagIDs (set-union); rest LWW.
            // NOTE vs server: customType + growingInfoJSON were iOS-local-only (never synced to
            // Postgres). In the CloudKit world they ride the household zone, so the long-standing
            // "customType doesn't sync across devices" gap closes for free.
            return [
                F("customName", .string, queryable: true),
                F("customVariety", .string),
                F("customCompany", .string),
                F("customType", .string),
                F("notes", .string),
                F("stateRaw", .string),        // SeedState.rawValue
                F("sourceRaw", .string),       // SeedSource.rawValue
                F("packetCount", .int),         // consume-counter → min-merge (not LWW)
                F("yearPacked", .int),
                // tagIDs: JSON [String] set (denormalized seed_tags); union-merge. The migration
                // mapper must source this from LocalSeed.tagIDsJSON (the storage column), NOT the
                // computed LocalSeed.tagIDs [String] accessor. CloudKit field name is "tagIDs".
                F("tagIDs", .string),
                F("growingInfoJSON", .string),  // JSON GrowingInfoSnapshot blob
                F("createdAt", .int),
                F("updatedAt", .int),           // merge clock
                F("deletedAt", .int),           // sticky tombstone, nil = not deleted
            ]

        case .seedPhoto:
            // Immutable + hard-deleted via the Seed cascade — no updatedAt/deletedAt columns.
            // (householdID omitted, like every type: the zone IS the household boundary.)
            return [
                F("r2Key", .string),
                F("roleRaw", .string),          // PhotoRole.rawValue
                F("width", .int),
                F("height", .int),
                F("byteSize", .int),
                F("capturedAt", .int),
            ]

        case .bed:
            return [
                F("name", .string, queryable: true),
                F("bedDescription", .string),
                F("widthFeet", .double),
                F("lengthFeet", .double),
                F("sortOrder", .int),
                F("createdAt", .int),
                F("updatedAt", .int),
                F("deletedAt", .int),
            ]

        case .plantingEvent:
            // Carries the SERVER-AUTHORED plant-pet identity fields (synced). The two iOS-local
            // streak columns (petWiltedStreakDays, petLastMoodTickAt) NEVER sync — excluded here.
            return [
                F("kindRaw", .string),          // PlantingEventKind.rawValue
                F("plannedFor", .string),       // YYYY-MM-DD
                F("completedAt", .int),
                F("notes", .string),
                F("xFeet", .double),
                F("yFeet", .double),
                F("createdAt", .int),
                F("updatedAt", .int),
                F("deletedAt", .int),
                // Phase 5 plant-pet identity (server-of-record, synced):
                F("petSeed", .string),
                F("petRarity", .string),
                F("petCreatureKind", .string),
                F("petName", .string),
                F("petPersonalityJSON", .string),
                F("petSpawnedAt", .int),
            ]

        case .journalEntry:
            return [
                F("occurredOn", .string),       // YYYY-MM-DD
                F("body", .string),
                F("createdAt", .int),
                F("updatedAt", .int),
                F("deletedAt", .int),
            ]

        case .journalEntryPhoto:
            // Hard-deleted via the JournalEntry cascade — has updatedAt but no deletedAt.
            return [
                F("storageKey", .string),
                F("sortOrder", .int),
                F("width", .int),
                F("height", .int),
                F("createdAt", .int),
                F("updatedAt", .int),
            ]

        case .journalChecklistItem:
            // Custom merge: (completed, updatedAt) resolved as a UNIT. Hard-deleted via cascade.
            return [
                F("text", .string),
                F("completed", .bool),          // Bool → INT64 (G3)
                F("sortOrder", .int),
                F("updatedAt", .int),           // merge clock for the (completed,updatedAt) pair
            ]

        case .petDeparture:
            return [
                F("goodbyeNoteJSON", .string),
                F("reason", .string),
                F("fallback", .bool),           // Bool → INT64 (G3)
                F("createdAt", .int),
                F("updatedAt", .int),
                F("departedAt", .int),
                // deletedAt: client-managed in the CloudKit model (the soft-cascade from a
                // deleted PlantingEvent sets it). The legacy server never wrote pet_departures.deleted_at.
                F("deletedAt", .int),
            ]

        case .migrationReceipt:
            // Written once when a household's Postgres data finishes importing (G12). Presence
            // (by recordName `migrated:<householdID>`) is the idempotency signal; fields are detail.
            return [
                F("completedAt", .int),
                F("schemaVersion", .int),
            ]
        }
    }

    /// Reference graph (in-zone CKReference + cross-DB String). Ref field names match the
    /// model's FK column names so the migration mapping is 1:1.
    public var refs: [RefSpec] {
        switch self {
        case .household, .location, .tag, .bed, .migrationReceipt:
            return []

        case .seed:
            return [
                R("locationID", .setNullInZone, target: "Location"),
                R("catalogID", .crossDBString, target: "catalog"),   // global catalog (R2/R3) — String, not CKReference
            ]

        case .seedPhoto:
            return [
                R("seedID", .cascadeParent, target: "Seed"),         // .deleteSelf: seed_photos hard-cascade
            ]

        case .plantingEvent:
            return [
                R("bedID", .setNullInZone, target: "Bed"),
                R("seedID", .setNullInZone, target: "Seed"),
                R("catalogSeedID", .crossDBString, target: "catalog"),
            ]

        case .journalEntry:
            // At-most-one parent (CHECK on the server); all three are soft set-null refs.
            // (The Postgres FKs are ON DELETE CASCADE, but the app only ever SOFT-deletes parents
            //  and soft-cascades children client-side, so .none correctly matches observable behaviour.)
            return [
                R("seedID", .setNullInZone, target: "Seed"),
                R("bedID", .setNullInZone, target: "Bed"),
                R("plantingEventID", .setNullInZone, target: "PlantingEvent"),
            ]

        case .journalEntryPhoto:
            return [
                R("entryID", .cascadeParent, target: "JournalEntry"),
            ]

        case .journalChecklistItem:
            return [
                R("entryID", .cascadeParent, target: "JournalEntry"),
            ]

        case .petDeparture:
            return [
                R("plantingEventID", .cascadeParent, target: "PlantingEvent"),
            ]
        }
    }

    // Convenience shorthands — keep field/ref lists readable.
    private func F(_ n: String, _ t: CKFieldType, queryable: Bool = false, sortable: Bool = false) -> FieldSpec {
        FieldSpec(n, t, queryable: queryable, sortable: sortable)
    }
    private func R(_ n: String, _ k: RefKind, target: String) -> RefSpec {
        RefSpec(n, k, target: target)
    }
}

// MARK: - recordName builders

/// Seedkeep recordName builders (spec: type-slug-prefixed, deterministic, zone-unique).
/// `seed:<id>`, `household:<id>`, etc. Migration invariant: the existing DB id is the id
/// portion — no remapping, so cross-references survive.
public enum SeedkeepRecordNames {
    public static func household(_ id: String) -> String { "household:\(id)" }
    public static func location(_ id: String) -> String { "location:\(id)" }
    public static func tag(_ id: String) -> String { "tag:\(id)" }
    public static func seed(_ id: String) -> String { "seed:\(id)" }
    public static func seedPhoto(_ id: String) -> String { "seedPhoto:\(id)" }
    public static func bed(_ id: String) -> String { "bed:\(id)" }
    public static func plantingEvent(_ id: String) -> String { "plantingEvent:\(id)" }
    public static func journalEntry(_ id: String) -> String { "journalEntry:\(id)" }
    public static func journalEntryPhoto(_ id: String) -> String { "journalEntryPhoto:\(id)" }
    public static func journalChecklistItem(_ id: String) -> String { "journalChecklistItem:\(id)" }
    /// 1:1 with the parent planting — keyed on the planting_event_id (spec §recordName policy).
    public static func petDeparture(_ plantingEventID: String) -> String { "petDeparture:\(plantingEventID)" }

    /// recordName for any type given its raw legacy id — the migration's single entry point.
    /// The migration receipt uses its own deterministic `migrated:<householdID>` name (G12).
    public static func recordName(for type: SeedkeepRecordType, id: String) -> String {
        type == .migrationReceipt ? migrationReceipt(id) : "\(type.rawValue):\(id)"
    }

    /// Idempotent migration receipt keyed by householdID (G12).
    public static func migrationReceipt(_ householdID: String) -> String { "migrated:\(householdID)" }

    /// Deterministic zone name: `seedkeep-<householdID>` (G10 — two devices racing converge).
    public static func zoneName(householdID: String) -> String { "seedkeep-\(householdID)" }
}
