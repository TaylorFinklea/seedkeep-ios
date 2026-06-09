import Foundation

/// Phase 4D · Swift mirror of the server's `fieldBounds.canonical.json`.
///
/// This file is the iOS-side source of truth for catalog correction
/// policy and MUST stay byte-identical (in semantic content) with the
/// server's `src/lib/catalog/fieldBounds.ts`. The canonical JSON checked
/// into `Seedkeep/Resources/fieldBounds.canonical.json` is the
/// parity-test reference — `CatalogFieldBoundsTests` SHA-256-hashes a
/// snapshot built from these constants and compares it against the JSON.
/// CI fails on either side if drift is introduced.
///
/// Default-deny: any column added to `catalog_seeds` server-side is
/// **uncorrectable** from iOS until explicitly listed in
/// `correctableFields`. `autoApplyFields` is the strict subset whose
/// values may bypass human review when every gate in the worker's
/// `decideCorrectionOutcome` passes — numeric + enum only, never
/// free-text.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §4 (`src/lib/catalog/fieldBounds.ts`).
public enum CatalogFieldBounds {
    /// All fields a user is permitted to file a correction against.
    /// Default-deny: anything not in this set returns
    /// `.invalid(reason: "unknown_field", …)` from `validateDraft`.
    public static let correctableFields: Set<String> = [
        "days_to_germinate_min", "days_to_germinate_max",
        "days_to_maturity_min", "days_to_maturity_max",
        "soil_temp_min_f", "soil_temp_max_f",
        "seed_depth_inches", "plant_spacing_inches", "row_spacing_inches",
        "hardiness_zone_min", "hardiness_zone_max", "viability_years",
        "sun_requirement", "frost_tolerance", "sow_method", "life_cycle",
        "scientific_name", "common_name", "variety", "company", "instructions",
    ]

    /// Strict subset of `correctableFields` whose values MAY bypass
    /// human review on the server. Mirrors the server's
    /// `AUTO_APPLY_FIELDS`. Free-text fields (instructions, common_name,
    /// variety, scientific_name, company) are intentionally absent —
    /// they always queue for human review regardless of AI confidence.
    public static let autoApplyFields: Set<String> = [
        "days_to_germinate_min", "days_to_germinate_max",
        "days_to_maturity_min", "days_to_maturity_max",
        "soil_temp_min_f", "soil_temp_max_f",
        "seed_depth_inches", "plant_spacing_inches", "row_spacing_inches",
        "hardiness_zone_min", "hardiness_zone_max", "viability_years",
        "sun_requirement", "frost_tolerance", "sow_method", "life_cycle",
    ]

    /// Inclusive numeric sanity bounds per field. Values outside this
    /// range are `.invalid(reason: "out_of_bounds", …)` unless the user
    /// taps "File anyway" (which sets `userAcknowledgedBounds=true` on
    /// the submission). The `seed_depth_inches` ceiling (9.99) is the
    /// NUMERIC(3,2) column-level hard cap on the server.
    public static let sanityBounds: [String: (min: Double, max: Double)] = [
        "days_to_germinate_min": (min: 1, max: 60),
        "days_to_germinate_max": (min: 1, max: 90),
        "days_to_maturity_min": (min: 5, max: 365),
        "days_to_maturity_max": (min: 5, max: 365),
        "soil_temp_min_f": (min: 20, max: 110),
        "soil_temp_max_f": (min: 20, max: 110),
        "seed_depth_inches": (min: 0.05, max: 9.99),
        "plant_spacing_inches": (min: 1, max: 240),
        "row_spacing_inches": (min: 1, max: 240),
        "hardiness_zone_min": (min: 1, max: 13),
        "hardiness_zone_max": (min: 1, max: 13),
        "viability_years": (min: 1, max: 20),
    ]

    /// In-bounds-but-suspect thresholds. A value `> threshold` passes
    /// `validateDraft` (so the user can submit it) but flips
    /// `requiresHuman = true` on the result — the server's decision
    /// pipeline will route the row to `queue_for_review` instead of
    /// `auto_apply` even with a high AI score. Common shape: unit
    /// confusion (e.g. cm typed as inches).
    public static let suspectThresholds: [String: Double] = [
        "seed_depth_inches": 3,       // > 3 in is botanically rare; likely cm
        "plant_spacing_inches": 96,   // > 8 ft suspect for any vegetable
        "row_spacing_inches": 96,
    ]

    /// Allowed lowercase values for each enum-typed catalog column.
    /// Case-insensitive on input; `validateDraft` normalizes to the
    /// canonical lowercase form before returning.
    public static let enumValues: [String: [String]] = [
        "sun_requirement": ["full", "partial", "shade"],
        "frost_tolerance": ["tender", "half_hardy", "hardy"],
        "sow_method": ["direct", "transplant", "either"],
        "life_cycle": ["annual", "biennial", "perennial"],
    ]

    /// Fields whose values are stored as integers server-side. The
    /// difference matters at validation time: integer fields reject
    /// decimal input with `.invalid(reason: "not_an_integer", …)`.
    private static let integerFields: Set<String> = [
        "days_to_germinate_min", "days_to_germinate_max",
        "days_to_maturity_min", "days_to_maturity_max",
        "soil_temp_min_f", "soil_temp_max_f",
        "plant_spacing_inches", "row_spacing_inches",
        "hardiness_zone_min", "hardiness_zone_max", "viability_years",
    ]

    /// Free-text fields. `validateDraft` accepts any trimmed string of
    /// length 1..2000 and flags `requiresHuman = true` (free-text
    /// fields never auto-apply server-side).
    private static let freeTextFields: Set<String> = [
        "scientific_name", "common_name", "variety", "company", "instructions",
    ]

    /// Result of validating a single draft value against the canonical
    /// constants. Discriminated so callers can pattern-match on outcome.
    public enum ValidationResult: Equatable {
        /// Value parsed and is within bounds. `normalized` is the
        /// canonical form (lowercased enum, parsed Double for numeric,
        /// trimmed string for free-text). `requiresHuman` is `true`
        /// when the value is in-bounds-but-suspect (per
        /// `suspectThresholds`) or is a free-text field (which never
        /// auto-applies).
        case valid(normalized: NormalizedValue, requiresHuman: Bool)
        /// Value rejected. `reason` is a machine-readable code mirroring
        /// the server's `validateFieldValue` (`unknown_field`,
        /// `invalid_enum`, `not_a_number`, `not_an_integer`,
        /// `out_of_bounds`, `not_a_string`, `empty`, `too_long`).
        /// `boundsHint` is the human-readable string from
        /// `describeBounds(field:)`.
        case invalid(reason: String, boundsHint: String)
    }

    /// Canonical normalized form returned by `validateDraft` on success.
    public enum NormalizedValue: Equatable {
        case number(Double)
        case text(String)
    }

    /// Validate and normalize `value` for `field`. Mirrors the server's
    /// `validateFieldValue` exactly — numeric strings are coerced (only
    /// fully-numeric input, no trailing prose), enum values are
    /// matched case-insensitively then normalized to lowercase,
    /// free-text values are trimmed and length-checked.
    ///
    /// CRITICAL: the regex `^-?\d+(?:\.\d+)?$` requires the *entire*
    /// trimmed string to be numeric. This rejects payloads like
    /// `"60.5; DROP TABLE…"` that `Double(_:)` alone would accept after
    /// truncation. Stays in lockstep with the server's `NUMERIC_FULL`.
    public static func validateDraft(field: String, value: String) -> ValidationResult {
        guard correctableFields.contains(field) else {
            return .invalid(
                reason: "unknown_field",
                boundsHint: "\(field) is not user-correctable"
            )
        }

        // Enum branch — case-insensitive match against ENUM_VALUES.
        if let options = enumValues[field] {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !options.contains(normalized) {
                return .invalid(
                    reason: "invalid_enum",
                    boundsHint: "valid values: \(options.joined(separator: ", "))"
                )
            }
            return .valid(normalized: .text(normalized), requiresHuman: false)
        }

        // Numeric branch.
        if let bounds = sanityBounds[field] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Full-string numeric match — no trailing prose. Mirrors
            // server `NUMERIC_FULL = /^-?\d+(?:\.\d+)?$/`.
            let pattern = #"^-?\d+(?:\.\d+)?$"#
            guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
                return .invalid(reason: "not_a_number", boundsHint: describeBounds(field: field))
            }
            guard let parsed = Double(trimmed), parsed.isFinite else {
                return .invalid(reason: "not_a_number", boundsHint: describeBounds(field: field))
            }
            if integerFields.contains(field) && parsed.rounded() != parsed {
                return .invalid(reason: "not_an_integer", boundsHint: describeBounds(field: field))
            }
            if parsed < bounds.min || parsed > bounds.max {
                return .invalid(reason: "out_of_bounds", boundsHint: describeBounds(field: field))
            }
            let requiresHuman: Bool = {
                guard let suspectAt = suspectThresholds[field] else { return false }
                return parsed > suspectAt
            }()
            return .valid(normalized: .number(parsed), requiresHuman: requiresHuman)
        }

        // Free-text branch.
        if freeTextFields.contains(field) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .invalid(reason: "empty", boundsHint: "value must not be empty")
            }
            if trimmed.count > 2000 {
                return .invalid(reason: "too_long", boundsHint: "value must be 2000 characters or fewer")
            }
            return .valid(normalized: .text(trimmed), requiresHuman: true)
        }

        return .invalid(
            reason: "unknown_field",
            boundsHint: "\(field) is not user-correctable"
        )
    }

    /// Human-readable bounds string for `field`. Used in error toast
    /// copy and the "typical range: X–Y" hint under the value editor.
    /// Mirrors the server's `describeBounds` so iOS-rendered copy stays
    /// in sync with 400-response `bounds_hint` payloads.
    public static func describeBounds(field: String) -> String {
        if let options = enumValues[field] {
            return "valid values: \(options.joined(separator: ", "))"
        }
        if let bounds = sanityBounds[field] {
            return "typical range: \(formatBound(bounds.min))–\(formatBound(bounds.max))"
        }
        if freeTextFields.contains(field) {
            return "free-form text up to 2000 characters"
        }
        return "\(field) is not user-correctable"
    }

    /// Render a numeric bound without forcing a `.0` suffix on
    /// integer-typed fields (e.g. `1–60` not `1.0–60.0`) while
    /// preserving the decimal form on `seed_depth_inches` (`0.05–9.99`).
    private static func formatBound(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
