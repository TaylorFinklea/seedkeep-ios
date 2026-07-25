#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

// Canonical household-graph digest — the verification primitive for transfer-by-copy account
// deletion (.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md §Verification).
//
// Before the owner may delete the source zone, the owner and the successor each hash THEIR OWN
// copy of the garden and the server compares the two. That only works if the hash is a pure
// function of the application graph, so this file deliberately excludes everything that legitimately
// differs between two copies of the same garden:
//
//   - zone identity — the successor's zone has a different ownerName (and the digest is taken over
//     record NAMES, never record IDs, on both the record itself and its in-zone references);
//   - CloudKit system metadata — change tags, modification stamps, the `parent` pointer, and any
//     other framework state, none of which appear in `allKeys()` and none of which are read here;
//   - CKShare and any record type outside the manifest — a share is per-owner by construction;
//   - undeclared keys on a manifest record — debris, not application state.
//
// Everything the manifest DOES declare is included and is order-independent: records sort by
// (record type, record name) and fields sort by name, so two devices that fetched the same zone in
// different batch orders agree byte-for-byte.
//
// The encoding is injective: `\`, tab, newline, and carriage return are escaped inside every
// variable component, so no field value can forge an extra canonical line.

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
    /// A manifest-declared field holds a value the manifest cannot describe (wrong CloudKit type).
    case unsupportedValue(recordType: String, recordName: String, field: String)

    public var description: String {
        switch self {
        case .duplicateRecordName(let name):
            return "duplicate record name \(name) in the graph snapshot"
        case .unsupportedValue(let type, let name, let field):
            return "\(type) \(name) field \(field) holds a value the manifest cannot describe"
        }
    }
}

// MARK: - Digester

public enum HouseholdGraphDigester {
    /// Canonical-format tag. Bump it when the encoding changes; a mixed-version pair of devices
    /// must disagree loudly rather than compare two differently-built hashes.
    public static let formatVersion = "seedkeep-graph-digest/1"

    /// SHA-256 over `canonicalDocument`, plus exact per-type counts.
    public static func digest(of records: [CKRecord]) throws -> HouseholdGraphDigest {
        let entries = try canonicalEntries(of: records)
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.recordType, default: 0] += 1 }
        let hash = SHA256.hash(data: Data(document(from: entries).utf8))
        return HouseholdGraphDigest(sha256: hash.map { String(format: "%02x", $0) }.joined(),
                                    counts: counts)
    }

    /// The exact bytes that get hashed. Public so a mismatch can be diffed on-device instead of
    /// being reported as two opaque hashes.
    public static func canonicalDocument(of records: [CKRecord]) throws -> String {
        document(from: try canonicalEntries(of: records))
    }

    // MARK: Internals

    private struct Entry {
        let recordType: String
        let recordName: String
        let fieldLines: [String]
    }

    private static func canonicalEntries(of records: [CKRecord]) throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for record in records {
            // Non-manifest types (CKShare, anything the app does not own) are not garden data.
            guard let type = SeedkeepRecordType.type(forRecordTypeName: record.recordType) else { continue }
            let recordName = record.recordID.recordName
            guard seen.insert(recordName).inserted else {
                throw HouseholdGraphDigestError.duplicateRecordName(recordName)
            }
            switch CanonicalRecordEncoder.fieldLines(of: record, as: type) {
            case .success(let lines):
                entries.append(Entry(recordType: type.recordTypeName,
                                     recordName: recordName,
                                     fieldLines: lines))
            case .failure(let unsupported):
                throw HouseholdGraphDigestError.unsupportedValue(
                    recordType: type.recordTypeName, recordName: recordName, field: unsupported.field)
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
            return "d:" + String(format: "%016llx", value.bitPattern)
        case .date(let value):
            // Unix milliseconds — the granularity the app itself uses, so sub-millisecond drift
            // from a CloudKit round-trip cannot make two copies of one garden disagree.
            return "t:\(Int((value.timeIntervalSince1970 * 1000).rounded()))"
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

/// A manifest-declared field whose CloudKit value the manifest cannot describe.
struct UnsupportedFieldValue: Error, Equatable {
    let field: String
}

enum CanonicalRecordEncoder {
    /// `F<tab><field><tab><value>` lines for the manifest fields present on `record`, sorted by
    /// field name. Failure carries the name of the first field whose value the manifest cannot
    /// describe (deterministic: manifest order, fields before references).
    static func fieldLines(of record: CKRecord,
                           as type: SeedkeepRecordType) -> Result<[String], UnsupportedFieldValue> {
        var encoded: [(name: String, value: String)] = []

        for field in type.fields {
            guard let raw = record[field.name] else { continue }
            guard let value = CanonicalFieldValue.read(raw, as: field.type) else {
                return .failure(UnsupportedFieldValue(field: field.name))
            }
            encoded.append((field.name, value.canonicalEncoding))
        }

        for spec in type.refs {
            guard let raw = record[spec.name] else { continue }
            guard let value = encodeReference(raw, kind: spec.kind) else {
                return .failure(UnsupportedFieldValue(field: spec.name))
            }
            encoded.append((spec.name, value))
        }

        encoded.sort { $0.name < $1.name }
        return .success(encoded.map { "F\t\(escaped($0.name))\t\($0.value)" })
    }

    /// Test/diagnostic seam over `CanonicalFieldValue` — nil for a value the manifest rejects.
    static func encodeScalar(_ raw: Any, as fieldType: CKFieldType) -> String? {
        CanonicalFieldValue.read(raw, as: fieldType)?.canonicalEncoding
    }

    /// References hash their TARGET RECORD NAME and action, never a zone-qualified record ID — that
    /// is what makes the owner's and the successor's digests comparable. Cross-DB refs are plain
    /// strings (G4) and stay verbatim.
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
