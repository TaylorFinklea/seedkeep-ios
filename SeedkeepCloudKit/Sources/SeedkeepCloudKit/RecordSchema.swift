import Foundation

// Generates the CKDSL (CloudKit schema language) for Seedkeep record types FROM the manifest,
// so the deployed schema and the codec can't drift.
// Mirrors SimmerSmith's HouseholdRecordSchema.swift ckdsl() extension — validated correct.

public extension SeedkeepRecordType {
    /// CKDSL `RECORD TYPE` block for this type.
    func ckdsl() -> String {
        var lines: [String] = ["    RECORD TYPE \(recordTypeName) ("]
        var body: [String] = []
        for f in fields {
            var decl = "        \(f.name) \(Self.dslType(f.type))"
            if f.queryable { decl += " QUERYABLE" }
            if f.sortable  { decl += " SORTABLE" }
            body.append(decl)
        }
        for r in refs {
            switch r.kind {
            case .cascadeParent, .setNullInZone:
                body.append("        \(r.name) REFERENCE")
            case .crossDBString:
                body.append("        \(r.name) STRING")
            }
        }
        body.append("        GRANT WRITE TO \"_creator\"")
        body.append("        GRANT READ, CREATE TO \"_icloud\"")
        lines.append(body.joined(separator: ",\n"))
        lines.append("    );")
        return lines.joined(separator: "\n")
    }

    /// Complete schema document in manifest order, ready to import as a .ckdb file.
    static func allCKDSL() -> String {
        "DEFINE SCHEMA\n\n" + allCases.map { $0.ckdsl() }.joined(separator: "\n\n")
    }

    private static func dslType(_ t: CKFieldType) -> String {
        switch t {
        case .string: return "STRING"
        case .int, .bool: return "INT64"  // G3: Bool → INT64
        case .double: return "DOUBLE"
        case .date: return "TIMESTAMP"
        }
    }
}
