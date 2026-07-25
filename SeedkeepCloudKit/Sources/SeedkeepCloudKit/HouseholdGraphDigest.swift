#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

// Canonical household-graph digest — the verification primitive for transfer-by-copy account
// deletion (.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md §Verification).
//
// Before the owner may delete the source zone, the owner and the successor each hash THEIR OWN
// copy of the garden and the server compares the two. Two properties make that safe.
//
// 1. ZONE-INDEPENDENT, BUT ONLY AFTER PROVING THE ZONE. The canonical bytes carry record NAMES,
//    never zone-qualified record IDs, so the successor's differently-owned zone hashes the same.
//    That erasure is only sound if every record and every in-zone reference is first proven to
//    belong to the zone being hashed — otherwise a destination reference still pointing back into
//    the owner's zone would hash identically to a correctly retargeted one, and the transfer would
//    verify a broken graph as equal.
//
// 2. FAIL CLOSED. This digest is the sole gate on an irreversible zone deletion. Anything it
//    cannot describe — an unrecognised record type, an undeclared key, a value whose CloudKit type
//    contradicts the manifest — throws. Silently skipping unknown app data would truncate the
//    owner's and the successor's digests IDENTICALLY, so the two lossy copies would compare equal
//    and authorise deleting the only complete one. Only CloudKit's own reserved record types
//    (CKShare and friends) are excluded, because those are per-owner by construction.
//
// Everything the manifest declares is included and order-independent: records sort by
// (record type, record name) and fields sort by name, so two devices that fetched the same zone in
// different batch orders agree byte-for-byte. CloudKit system metadata — change tags, modification
// stamps, the `parent` pointer — is never read and never appears in `allKeys()`.
//
// The encoding is injective: `\`, tab, newline, and carriage return are escaped inside every
// variable component, so no field value can forge an extra canonical line.

// MARK: - System records

/// CloudKit's own records inside a custom zone. They live in reserved namespaces (`cloudkit.share`
/// and the `_`-prefixed internals) that the app can never write, so excluding them cannot hide
/// application data. Every OTHER record in a household zone is app data and must be accounted for.
public enum CloudKitSystemRecords {
    public static func isSystemType(_ recordType: String) -> Bool {
        recordType.hasPrefix("cloudkit.") || recordType.hasPrefix("_")
    }
}

// MARK: - Result

/// A canonical hash of a household garden graph plus the per-type counts both parties compare.
/// `Codable` because the server stores it verbatim as the transfer's digest document — it never
/// receives any record contents, only this.
public struct HouseholdGraphDigest: Equatable, Codable, Sendable {
    /// Lowercase hex SHA-256 of the canonical document's UTF-8 bytes.
    public let sha256: String
    /// CloudKit record type name → number of records of that type in the graph.
    /// Types absent from the graph are absent from the dictionary.
    public let counts: [String: Int]

    public var recordCount: Int { counts.values.reduce(0, +) }

    public init(sha256: String, counts: [String: Int]) {
        self.sha256 = sha256
        self.counts = counts
    }
}

public enum HouseholdGraphDigestError: Error, Equatable, CustomStringConvertible {
    /// Two records share a record name. A zone cannot contain both, so the input is not a faithful
    /// snapshot and the digest would be ambiguous.
    case duplicateRecordName(String)
    /// A non-system record type this build's manifest does not declare — almost certainly schema
    /// skew with a newer build. Hashing around it would verify a truncated copy as complete.
    case unknownRecordType(recordType: String, recordName: String)
    /// A key on a manifest record that the manifest does not declare. Same skew hazard, one level
    /// down (a newer build added a field).
    case undeclaredField(recordType: String, recordName: String, field: String)
    /// A manifest-declared field holds a value the manifest cannot describe (wrong CloudKit type).
    case unsupportedValue(recordType: String, recordName: String, field: String)
    /// A record that does not belong to the zone being hashed.
    case recordOutsideZone(recordName: String, zoneName: String)
    /// An in-zone reference targeting some other zone. Its zone cannot be erased from the canonical
    /// bytes without hiding a mis-retargeted copy.
    case referenceOutsideZone(recordName: String, field: String, zoneName: String)

    public var description: String {
        switch self {
        case .duplicateRecordName(let name):
            return "duplicate record name \(name) in the graph snapshot"
        case .unknownRecordType(let type, let name):
            return "record \(name) has unknown record type \(type); this build cannot verify it"
        case .undeclaredField(let type, let name, let field):
            return "\(type) \(name) carries undeclared field \(field); this build cannot verify it"
        case .unsupportedValue(let type, let name, let field):
            return "\(type) \(name) field \(field) holds a value the manifest cannot describe"
        case .recordOutsideZone(let name, let zone):
            return "record \(name) belongs to zone \(zone), not the zone being hashed"
        case .referenceOutsideZone(let name, let field, let zone):
            return "record \(name) field \(field) references zone \(zone), not the zone being hashed"
        }
    }
}

// MARK: - Digester

public enum HouseholdGraphDigester {
    /// Canonical-format tag. Bump it when the encoding changes; a mixed-version pair of devices
    /// must disagree loudly rather than compare two differently-built hashes.
    public static let formatVersion = "seedkeep-graph-digest/1"

    /// SHA-256 over `canonicalDocument`, plus exact per-type counts.
    ///
    /// `zoneID` is the zone the caller believes these records came from: the owner passes the
    /// source zone, the successor passes their destination zone. Every app record and every in-zone
    /// reference must live there, which is what licenses leaving zone identity out of the hash.
    public static func digest(of records: [CKRecord],
                              in zoneID: CKRecordZone.ID) throws -> HouseholdGraphDigest {
        let entries = try canonicalEntries(of: records, in: zoneID)
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.recordType, default: 0] += 1 }
        let hash = SHA256.hash(data: Data(document(from: entries).utf8))
        return HouseholdGraphDigest(sha256: hash.map { String(format: "%02x", $0) }.joined(),
                                    counts: counts)
    }

    /// The exact bytes that get hashed. Public so a mismatch can be diffed on-device instead of
    /// being reported as two opaque hashes.
    public static func canonicalDocument(of records: [CKRecord],
                                         in zoneID: CKRecordZone.ID) throws -> String {
        document(from: try canonicalEntries(of: records, in: zoneID))
    }

    // MARK: Internals

    private struct Entry {
        let recordType: String
        let recordName: String
        let fieldLines: [String]
    }

    private static func canonicalEntries(of records: [CKRecord],
                                         in zoneID: CKRecordZone.ID) throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for record in records {
            // CloudKit's own reserved records are per-owner state, not garden data.
            guard !CloudKitSystemRecords.isSystemType(record.recordType) else { continue }
            let recordName = record.recordID.recordName
            guard let type = SeedkeepRecordType.type(forRecordTypeName: record.recordType) else {
                throw HouseholdGraphDigestError.unknownRecordType(
                    recordType: record.recordType, recordName: recordName)
            }
            guard record.recordID.zoneID == zoneID else {
                throw HouseholdGraphDigestError.recordOutsideZone(
                    recordName: recordName, zoneName: record.recordID.zoneID.zoneName)
            }
            if let undeclared = CanonicalRecordEncoder.undeclaredKeys(of: record, as: type).first {
                throw HouseholdGraphDigestError.undeclaredField(
                    recordType: type.recordTypeName, recordName: recordName, field: undeclared)
            }
            guard seen.insert(recordName).inserted else {
                throw HouseholdGraphDigestError.duplicateRecordName(recordName)
            }
            switch CanonicalRecordEncoder.fieldLines(of: record, as: type, in: zoneID) {
            case .success(let lines):
                entries.append(Entry(recordType: type.recordTypeName,
                                     recordName: recordName,
                                     fieldLines: lines))
            case .failure(.unsupportedValue(let field)):
                throw HouseholdGraphDigestError.unsupportedValue(
                    recordType: type.recordTypeName, recordName: recordName, field: field)
            case .failure(.referenceOutsideZone(let field, let zoneName)):
                throw HouseholdGraphDigestError.referenceOutsideZone(
                    recordName: recordName, field: field, zoneName: zoneName)
            }
        }
        entries.sort { ($0.recordType, $0.recordName) < ($1.recordType, $1.recordName) }
        return entries
    }

    private static func document(from entries: [Entry]) -> String {
        var lines = [formatVersion]
        for entry in entries {
            lines.append("R\t\(CanonicalRecordEncoder.escaped(entry.recordType))"
                         + "\t\(CanonicalRecordEncoder.escaped(entry.recordName))")
            lines.append(contentsOf: entry.fieldLines)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Manifest-typed field value

/// A raw CKRecord field value read through the manifest. Both the digest and the copier go through
/// this one accessor, so a value either canonicalises AND copies, or is rejected by both — the two
/// can never disagree about what the graph contains.
enum CanonicalFieldValue {
    case string(String)
    case int(Int)
    case double(Double)
    case date(Date)
    /// Bool fields are stored as INT64 (G3). The raw storage integer is kept so a copy is lossless,
    /// while the canonical encoding compares them as booleans.
    case bool(Int)

    static func read(_ raw: Any, as fieldType: CKFieldType) -> CanonicalFieldValue? {
        switch fieldType {
        case .string: return (raw as? String).map(CanonicalFieldValue.string)
        case .int:    return (raw as? Int).map(CanonicalFieldValue.int)
        case .double: return (raw as? Double).map(CanonicalFieldValue.double)
        case .date:   return (raw as? Date).map(CanonicalFieldValue.date)
        case .bool:   return (raw as? Int).map(CanonicalFieldValue.bool)
        }
    }

    var canonicalEncoding: String {
        switch self {
        case .string(let value):
            return "s:" + CanonicalRecordEncoder.escaped(value)
        case .int(let value):
            return "i:\(value)"
        case .double(let value):
            // Exact bit pattern: the digest reports what CloudKit stores, with no lossy formatting.
            return "d:" + CanonicalRecordEncoder.hex(value.bitPattern)
        case .date(let value):
            // Exact bit pattern too. Rounding to whole milliseconds would be INJECTIVE-BREAKING:
            // two distinct instants would share a token, so a destination that lost the fractional
            // part could pass digest equality and authorise deleting the source. No manifest field
            // is `.date` today, but CKFieldType supports it and this must be right when one is.
            return "t:" + CanonicalRecordEncoder.hex(value.timeIntervalSinceReferenceDate.bitPattern)
        case .bool(let value):
            return "b:\(value != 0 ? 1 : 0)"
        }
    }

    /// The value to write onto a copied record — byte-identical to what was read.
    var ckValue: CKRecordValue {
        switch self {
        case .string(let value): return value as CKRecordValue
        case .int(let value):    return value as CKRecordValue
        case .double(let value): return value as CKRecordValue
        case .date(let value):   return value as CKRecordValue
        case .bool(let value):   return value as CKRecordValue
        }
    }
}

// MARK: - Canonical encoder

/// Why a manifest-declared field could not be canonicalised.
enum CanonicalFieldFailure: Error, Equatable {
    case unsupportedValue(field: String)
    case referenceOutsideZone(field: String, zoneName: String)
}

enum CanonicalRecordEncoder {
    /// `F<tab><field><tab><value>` lines for the manifest fields present on `record`, sorted by
    /// field name. Failure names the first field that could not be encoded (deterministic:
    /// manifest order, scalars before references).
    static func fieldLines(of record: CKRecord,
                           as type: SeedkeepRecordType,
                           in expectedZoneID: CKRecordZone.ID) -> Result<[String], CanonicalFieldFailure> {
        var encoded: [(name: String, value: String)] = []

        for field in type.fields {
            guard let raw = record[field.name] else { continue }
            guard let value = CanonicalFieldValue.read(raw, as: field.type) else {
                return .failure(.unsupportedValue(field: field.name))
            }
            encoded.append((field.name, value.canonicalEncoding))
        }

        for spec in type.refs {
            guard let raw = record[spec.name] else { continue }
            // The reference's zone is erased from the canonical bytes, so it must be proven first.
            if spec.kind != .crossDBString,
               let reference = raw as? CKRecord.Reference,
               reference.recordID.zoneID != expectedZoneID {
                return .failure(.referenceOutsideZone(
                    field: spec.name, zoneName: reference.recordID.zoneID.zoneName))
            }
            guard let value = encodeReference(raw, kind: spec.kind) else {
                return .failure(.unsupportedValue(field: spec.name))
            }
            encoded.append((spec.name, value))
        }

        encoded.sort { $0.name < $1.name }
        return .success(encoded.map { "F\t\(escaped($0.name))\t\($0.value)" })
    }

    /// Application keys present on the record that the manifest does not declare, sorted so the
    /// reported offender is deterministic. CloudKit system metadata (change tag, `parent`, `share`)
    /// is NOT part of `allKeys()`, so it never trips this.
    static func undeclaredKeys(of record: CKRecord, as type: SeedkeepRecordType) -> [String] {
        var declared = Set(type.fields.map(\.name))
        declared.formUnion(type.refs.map(\.name))
        return record.allKeys().filter { !declared.contains($0) }.sorted()
    }

    /// Test/diagnostic seam over `CanonicalFieldValue` — nil for a value the manifest rejects.
    static func encodeScalar(_ raw: Any, as fieldType: CKFieldType) -> String? {
        CanonicalFieldValue.read(raw, as: fieldType)?.canonicalEncoding
    }

    /// References hash their TARGET RECORD NAME and action, never a zone-qualified record ID — that
    /// is what makes the owner's and the successor's digests comparable, once the caller has proven
    /// the target zone. Cross-DB refs are plain strings (G4) and stay verbatim.
    static func encodeReference(_ raw: Any, kind: RefKind) -> String? {
        switch kind {
        case .crossDBString:
            guard let value = raw as? String else { return nil }
            return "x:" + escaped(value)
        case .setNullInZone, .cascadeParent:
            guard let reference = raw as? CKRecord.Reference else { return nil }
            return "r:\(actionTag(reference.action)):" + escaped(reference.recordID.recordName)
        }
    }

    /// The action is part of the digest: a `.none` → `.deleteSelf` drift would silently rewire the
    /// cascade in the successor's garden without changing a single field value.
    static func actionTag(_ action: CKRecord.ReferenceAction) -> String {
        switch action {
        case .none: return "none"
        case .deleteSelf: return "deleteSelf"
        @unknown default: return "action\(action.rawValue)"
        }
    }

    static func hex(_ bits: UInt64) -> String { String(format: "%016llx", bits) }

    /// Injective escape of the separators the canonical document uses. Without it a field value
    /// containing a newline and a tab could forge additional canonical lines and let two different
    /// graphs hash the same.
    static func escaped(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        else { return value }
        var out = String()
        out.reserveCapacity(value.unicodeScalars.count + 8)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += #"\\"#
            case "\n": out += #"\n"#
            case "\r": out += #"\r"#
            case "\t": out += #"\t"#
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
#endif
