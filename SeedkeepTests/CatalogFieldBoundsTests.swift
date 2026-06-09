import Testing
import Foundation
import CryptoKit
@testable import Seedkeep

/// Phase 4D — iOS-side parity tests for `CatalogFieldBounds`.
///
/// Two layers:
///
/// 1. **SHA-256 parity** vs the canonical JSON fixture shipped in
///    `Seedkeep/Resources/fieldBounds.canonical.json`. The server has the
///    matching parity test on its side (`fieldBounds.test.ts`); if both
///    sides hash to the same value the constants are guaranteed to be in
///    lockstep. The hash is computed over JSON re-encoded in the
///    server's canonical key order (per `fieldBoundsSnapshot()` in
///    `src/lib/catalog/fieldBounds.ts`):
///    `correctableFields` → `autoApplyFields` → `sanityBounds`
///    → `suspectThresholds` → `enumValues`, with every nested object's
///    keys sorted alphabetically, no whitespace, double-quoted strings.
///    On divergence, the failure message renders both hashes so the
///    direction of drift is obvious.
///
/// 2. **`validateDraft` per-field cases** mirroring the server's
///    `fieldBounds.test.ts`: in-range / out-of-range numeric, enum
///    match / mismatch, suspect-threshold flips `requiresHuman=true` but
///    still validates.
@Suite("CatalogFieldBounds — Phase 4D parity + validate")
struct CatalogFieldBoundsTests {

    // MARK: - SHA-256 parity

    @Test("Swift snapshot SHA-256 matches the canonical JSON fixture")
    func sha256MatchesCanonicalFixture() throws {
        let swiftJSON = Self.serializeSwiftSnapshot()
        let canonicalJSON = try Self.loadAndCanonicalizeFixture()

        let swiftHash = Self.sha256Hex(swiftJSON)
        let canonicalHash = Self.sha256Hex(canonicalJSON)

        #expect(
            swiftHash == canonicalHash,
            """
            SHA-256 drift between Swift CatalogFieldBounds and canonical JSON.
              swift     = \(swiftHash)
              canonical = \(canonicalHash)
            Swift JSON:
            \(String(data: swiftJSON, encoding: .utf8) ?? "<non-utf8>")
            Canonical JSON:
            \(String(data: canonicalJSON, encoding: .utf8) ?? "<non-utf8>")
            """
        )
    }

    // MARK: - validateDraft — numeric in-bounds

    @Test("days_to_maturity_min: 65 (in-bounds) → valid integer, not suspect")
    func numericIntegerInBounds() {
        let r = CatalogFieldBounds.validateDraft(field: "days_to_maturity_min", value: "65")
        guard case let .valid(normalized, requiresHuman) = r else {
            Issue.record("expected .valid, got \(r)"); return
        }
        #expect(normalized == .number(65))
        #expect(requiresHuman == false)
    }

    @Test("days_to_maturity_max: 4 (below min=5) → out_of_bounds")
    func numericBelowMin() {
        let r = CatalogFieldBounds.validateDraft(field: "days_to_maturity_max", value: "4")
        guard case let .invalid(reason, hint) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "out_of_bounds")
        #expect(hint.contains("5"))
    }

    @Test("days_to_maturity_max: 366 (above max=365) → out_of_bounds")
    func numericAboveMax() {
        let r = CatalogFieldBounds.validateDraft(field: "days_to_maturity_max", value: "366")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "out_of_bounds")
    }

    @Test("seed_depth_inches: 10.0 (above 9.99 cap) → out_of_bounds")
    func seedDepthAboveColumnCap() {
        let r = CatalogFieldBounds.validateDraft(field: "seed_depth_inches", value: "10.0")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "out_of_bounds")
    }

    @Test("seed_depth_inches: 0.25 (in-bounds, below suspect=3) → valid, not suspect")
    func seedDepthInBoundsNotSuspect() {
        let r = CatalogFieldBounds.validateDraft(field: "seed_depth_inches", value: "0.25")
        guard case let .valid(_, requiresHuman) = r else {
            Issue.record("expected .valid"); return
        }
        #expect(requiresHuman == false)
    }

    // MARK: - validateDraft — suspect-threshold trigger

    @Test("seed_depth_inches: 3.5 → in-bounds but suspect (requiresHuman=true)")
    func seedDepthAboveSuspectThreshold() {
        let r = CatalogFieldBounds.validateDraft(field: "seed_depth_inches", value: "3.5")
        guard case let .valid(normalized, requiresHuman) = r else {
            Issue.record("expected .valid, got \(r)"); return
        }
        #expect(normalized == .number(3.5))
        #expect(requiresHuman == true, "values above suspect threshold must flip requiresHuman")
    }

    @Test("plant_spacing_inches: 120 → in-bounds but suspect (cm-vs-in)")
    func plantSpacingAboveSuspectThreshold() {
        let r = CatalogFieldBounds.validateDraft(field: "plant_spacing_inches", value: "120")
        guard case let .valid(_, requiresHuman) = r else {
            Issue.record("expected .valid"); return
        }
        #expect(requiresHuman == true)
    }

    @Test("row_spacing_inches: 24 → in-bounds, not suspect (≤96)")
    func rowSpacingBelowSuspectThreshold() {
        let r = CatalogFieldBounds.validateDraft(field: "row_spacing_inches", value: "24")
        guard case let .valid(_, requiresHuman) = r else {
            Issue.record("expected .valid"); return
        }
        #expect(requiresHuman == false)
    }

    // MARK: - validateDraft — integer enforcement

    @Test("integer field (days_to_germinate_min) rejects decimal input")
    func integerRejectsDecimal() {
        let r = CatalogFieldBounds.validateDraft(field: "days_to_germinate_min", value: "5.5")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "not_an_integer")
    }

    @Test("non-numeric string → not_a_number")
    func nonNumericString() {
        let r = CatalogFieldBounds.validateDraft(field: "soil_temp_min_f", value: "warm")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "not_a_number")
    }

    @Test("numeric with trailing prose rejected (regex anchored)")
    func numericWithTrailingProse() {
        let r = CatalogFieldBounds.validateDraft(
            field: "days_to_maturity_min",
            value: "60; DROP TABLE"
        )
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid, got \(r)"); return
        }
        #expect(reason == "not_a_number")
    }

    // MARK: - validateDraft — enum match / mismatch

    @Test("sun_requirement enum: 'full' (canonical) → valid")
    func enumCanonicalMatch() {
        let r = CatalogFieldBounds.validateDraft(field: "sun_requirement", value: "full")
        guard case let .valid(normalized, requiresHuman) = r else {
            Issue.record("expected .valid"); return
        }
        #expect(normalized == .text("full"))
        #expect(requiresHuman == false)
    }

    @Test("sun_requirement enum: 'FULL' → normalized to lowercase")
    func enumCaseInsensitive() {
        let r = CatalogFieldBounds.validateDraft(field: "sun_requirement", value: "FULL")
        guard case let .valid(normalized, _) = r else {
            Issue.record("expected .valid"); return
        }
        #expect(normalized == .text("full"))
    }

    @Test("sun_requirement enum: 'half-day' (unknown) → invalid_enum with hint")
    func enumMismatch() {
        let r = CatalogFieldBounds.validateDraft(field: "sun_requirement", value: "half-day")
        guard case let .invalid(reason, hint) = r else {
            Issue.record("expected .invalid"); return
        }
        #expect(reason == "invalid_enum")
        // Hint should list every valid option so the user can pick one.
        #expect(hint.contains("full"))
        #expect(hint.contains("partial"))
        #expect(hint.contains("shade"))
    }

    // MARK: - validateDraft — free-text

    @Test("free-text scientific_name: 'Solanum lycopersicum' → valid, requiresHuman=true")
    func freeTextAlwaysRequiresHuman() {
        let r = CatalogFieldBounds.validateDraft(
            field: "scientific_name",
            value: "Solanum lycopersicum"
        )
        guard case let .valid(_, requiresHuman) = r else {
            Issue.record("expected .valid"); return
        }
        // Free-text fields always queue for a human regardless of content.
        #expect(requiresHuman == true)
    }

    @Test("free-text empty string → empty reason")
    func freeTextEmpty() {
        let r = CatalogFieldBounds.validateDraft(field: "scientific_name", value: "   ")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid"); return
        }
        #expect(reason == "empty")
    }

    // MARK: - validateDraft — unknown field (default-deny allowlist)

    @Test("unknown field (not in correctableFields) → unknown_field")
    func unknownFieldRejected() {
        let r = CatalogFieldBounds.validateDraft(field: "secret_field", value: "hello")
        guard case .invalid(let reason, _) = r else {
            Issue.record("expected .invalid"); return
        }
        #expect(reason == "unknown_field")
    }

    // MARK: - SHA-256 helpers
    //
    // Server's `fieldBoundsSnapshot()` builds an object with keys in
    // insertion order: correctableFields → autoApplyFields → sanityBounds
    // → suspectThresholds → enumValues. Within each nested object,
    // entries are .sort()ed by key. JSON.stringify emits no whitespace
    // and double-quotes strings; numbers are emitted in shortest-round-trip
    // form ("3" not "3.0", "0.05" preserved).
    //
    // We reproduce the same shape in Swift using JSONSerialization with
    // .sortedKeys turned off (we control order explicitly via an array
    // of (key, value) pairs encoded as Data fragments). Numbers go
    // through JSONSerialization so 1.0 → "1" and 0.05 → "0.05" matches
    // V8/Bun's JSON.stringify output.

    /// Serialize Swift's CatalogFieldBounds constants in the server's
    /// canonical key order so the resulting bytes hash identically.
    static func serializeSwiftSnapshot() -> Data {
        let sortedCorrectable = CatalogFieldBounds.correctableFields.sorted()
        let sortedAutoApply = CatalogFieldBounds.autoApplyFields.sorted()

        let sortedSanityBoundsKeys = CatalogFieldBounds.sanityBounds.keys.sorted()
        var sanityBoundsParts: [String] = []
        for key in sortedSanityBoundsKeys {
            // swiftlint:disable:next force_unwrapping
            let v = CatalogFieldBounds.sanityBounds[key]!
            sanityBoundsParts.append(
                "\(jsonString(key)):{\"min\":\(jsonNumber(v.min)),\"max\":\(jsonNumber(v.max))}"
            )
        }
        let sanityBoundsBody = "{\(sanityBoundsParts.joined(separator: ","))}"

        let sortedSuspectKeys = CatalogFieldBounds.suspectThresholds.keys.sorted()
        var suspectParts: [String] = []
        for key in sortedSuspectKeys {
            // swiftlint:disable:next force_unwrapping
            let v = CatalogFieldBounds.suspectThresholds[key]!
            suspectParts.append("\(jsonString(key)):\(jsonNumber(v))")
        }
        let suspectBody = "{\(suspectParts.joined(separator: ","))}"

        let sortedEnumKeys = CatalogFieldBounds.enumValues.keys.sorted()
        var enumParts: [String] = []
        for key in sortedEnumKeys {
            // swiftlint:disable:next force_unwrapping
            let values = CatalogFieldBounds.enumValues[key]!
            let arr = "[\(values.map(jsonString).joined(separator: ","))]"
            enumParts.append("\(jsonString(key)):\(arr)")
        }
        let enumBody = "{\(enumParts.joined(separator: ","))}"

        let correctableArr =
            "[\(sortedCorrectable.map(jsonString).joined(separator: ","))]"
        let autoApplyArr =
            "[\(sortedAutoApply.map(jsonString).joined(separator: ","))]"

        // Top-level key order matches server's fieldBoundsSnapshot().
        let body = [
            "\"correctableFields\":\(correctableArr)",
            "\"autoApplyFields\":\(autoApplyArr)",
            "\"sanityBounds\":\(sanityBoundsBody)",
            "\"suspectThresholds\":\(suspectBody)",
            "\"enumValues\":\(enumBody)",
        ].joined(separator: ",")

        return Data("{\(body)}".utf8)
    }

    /// Load the fixture, parse to Foundation objects, then re-serialize
    /// in the same canonical shape — same fan-out the server-side parity
    /// test does via `JSON.parse(file)` → `JSON.stringify(parsed)`. Any
    /// drift in the *fixture file* (e.g. an editor added trailing
    /// whitespace or alphabetized differently) is normalized out.
    static func loadAndCanonicalizeFixture() throws -> Data {
        let url = try fixtureURL()
        let raw = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: raw, options: [])
        guard let root = json as? [String: Any] else {
            throw FixtureError.notAnObject
        }

        // Mirror the same nested re-serialization the Swift snapshot does.
        // The fixture file MUST contain the same five top-level keys.
        let correctableArr: String = {
            let raw = (root["correctableFields"] as? [String]) ?? []
            return "[\(raw.sorted().map(jsonString).joined(separator: ","))]"
        }()
        let autoApplyArr: String = {
            let raw = (root["autoApplyFields"] as? [String]) ?? []
            return "[\(raw.sorted().map(jsonString).joined(separator: ","))]"
        }()

        let sanityBoundsBody: String = {
            let raw = (root["sanityBounds"] as? [String: [String: Any]]) ?? [:]
            var parts: [String] = []
            for key in raw.keys.sorted() {
                // swiftlint:disable:next force_unwrapping
                let entry = raw[key]!
                let minV = numericFromAny(entry["min"])
                let maxV = numericFromAny(entry["max"])
                parts.append(
                    "\(jsonString(key)):{\"min\":\(jsonNumber(minV)),\"max\":\(jsonNumber(maxV))}"
                )
            }
            return "{\(parts.joined(separator: ","))}"
        }()

        let suspectBody: String = {
            let raw = (root["suspectThresholds"] as? [String: Any]) ?? [:]
            var parts: [String] = []
            for key in raw.keys.sorted() {
                let v = numericFromAny(raw[key])
                parts.append("\(jsonString(key)):\(jsonNumber(v))")
            }
            return "{\(parts.joined(separator: ","))}"
        }()

        let enumBody: String = {
            let raw = (root["enumValues"] as? [String: [String]]) ?? [:]
            var parts: [String] = []
            for key in raw.keys.sorted() {
                // swiftlint:disable:next force_unwrapping
                let values = raw[key]!
                parts.append(
                    "\(jsonString(key)):[\(values.map(jsonString).joined(separator: ","))]"
                )
            }
            return "{\(parts.joined(separator: ","))}"
        }()

        let body = [
            "\"correctableFields\":\(correctableArr)",
            "\"autoApplyFields\":\(autoApplyArr)",
            "\"sanityBounds\":\(sanityBoundsBody)",
            "\"suspectThresholds\":\(suspectBody)",
            "\"enumValues\":\(enumBody)",
        ].joined(separator: ",")

        return Data("{\(body)}".utf8)
    }

    enum FixtureError: Error {
        case notAnObject
        case fixtureMissing
    }

    /// Look up the bundled `fieldBounds.canonical.json`. Falls back to
    /// the repo-relative path when the resource isn't bundled into the
    /// test target (xcodegen-rendered resource bundling can drift across
    /// project regens).
    static func fixtureURL() throws -> URL {
        // Try every bundle the test runner has access to — Bundle.main
        // is the .xctest bundle, but the host app bundle may also be
        // loaded with its resources.
        let candidates: [Bundle] = [Bundle.main] + Bundle.allBundles
        for bundle in candidates {
            if let url = bundle.url(
                forResource: "fieldBounds.canonical",
                withExtension: "json"
            ) {
                return url
            }
        }
        // Fall back to walking up from the test source file location
        // to the Seedkeep/Resources directory. `#filePath` resolves at
        // compile-time so the simulator can reach the host file system
        // via the same path.
        let here = URL(fileURLWithPath: #filePath)
        // .../SeedkeepTests/CatalogFieldBoundsTests.swift
        //   → .../SeedkeepTests
        //   → .../  (repo root)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repoRoot
            .appendingPathComponent("Seedkeep")
            .appendingPathComponent("Resources")
            .appendingPathComponent("fieldBounds.canonical.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw FixtureError.fixtureMissing
    }

    /// SHA-256 hex digest of arbitrary bytes.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// JSON-encode a string the same way V8 / Bun's JSON.stringify does
    /// — wrap in double quotes, escape the small set of required
    /// characters. All field names in fieldBounds are ASCII-safe so the
    /// minimal escape set is sufficient.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for char in s.unicodeScalars {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        out += "\""
        return out
    }

    /// Number serialization that mirrors JS JSON.stringify: integers
    /// render without a decimal point ("3"), and Doubles render in
    /// shortest-round-trip form ("0.05" not "0.0500000…").
    static func jsonNumber(_ value: Double) -> String {
        // Integer-valued doubles → no decimal point.
        if value.isFinite && value == value.rounded() && abs(value) < 1e16 {
            return String(Int64(value))
        }
        // Use Swift's shortest-round-trip Double description, which
        // matches JS for the small set of finite decimals in the
        // canonical JSON (0.05, 9.99).
        return String(value)
    }

    /// Coerce JSON-parsed numeric leaf nodes back to Double. Foundation
    /// returns NSNumber-bridged values; bridging through `Double` covers
    /// both integer and decimal literals.
    static func numericFromAny(_ any: Any?) -> Double {
        if let dbl = any as? Double { return dbl }
        if let int = any as? Int { return Double(int) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }
}
