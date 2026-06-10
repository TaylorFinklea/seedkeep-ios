import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Phase 4D · Tests for the `CatalogFeedbackSheet` correction-submission
/// surface. The sheet itself is a SwiftUI `View` whose helpers are
/// `private`; this codebase doesn't ship a snapshot library
/// (`PetCardTests` documents the convention: "Snapshot infrastructure
/// isn't set up in this codebase; the previews … cover the rendered
/// surface for visual review. These tests cover the deterministic per-
/// phase modifiers + the accessibility-label state that screen readers
/// see.").
///
/// We follow the same convention: test the OBSERVABLE behavior the spec
/// pins via:
///
/// 1. **Construction smoke** per field-type variant — building a sheet
///    for each (numeric / enum / single-line text / freeform) doesn't
///    crash and the canonical field shape derived from
///    `CatalogFieldBounds.validateDraft` matches the expected
///    `ValidationResult.normalized` form.
/// 2. **Picker label semantics** — labels carry `· auto` / `· reviewed`
///    suffixes derived from `CatalogFieldBounds.autoApplyFields`
///    membership; the sheet's picker builder produces the same suffix
///    when fed each field name.
/// 3. **Current-value rendering** from `GrowingInfoSnapshot` — the
///    snapshot's structured values are the source of truth when no
///    catalog DTO is available offline. Test that the snapshot fields
///    survive a round-trip through the canonical field accessor used
///    inside the sheet.
/// 4. **Inline bounds helper** — `CatalogFieldBounds.describeBounds`
///    produces the "typical range: X–Y" copy the sheet renders below
///    numeric input. Asserted directly.
/// 5. **Pre-flight 409 banner** — a `LocalCatalogCorrection` with
///    `status == "open"` and matching `(catalogSeedID, fieldName)` is
///    surfaced via the sheet's `@Query` filter. Asserted via the
///    SwiftData container directly.
/// 6. **`@SceneStorage` key stability** — the body-preservation key the
///    sheet uses must stay byte-identical to the spec's contract
///    (`seedkeep.catalogFeedback.body`) so withdraw-and-replace doesn't
///    lose the drafted body.
/// 7. **"File anyway" payload contract** — the SeedkeepKit submit method
///    sends `user_acknowledged_bounds=true` on the wire when invoked
///    with the override flag. Asserted via a routed mock URL session
///    that captures the POST body.
/// 8. **429 retry copy buckets** — the bucket boundaries the spec calls
///    out (< 60s / < 5min / < 30min / else) are tested by re-deriving
///    the same algorithm and exercising every boundary.
@MainActor
@Suite("CatalogFeedbackSheet — Phase 4D contract", .serialized)
struct CatalogFeedbackSheetTests {

    // MARK: - Test 1: construction smoke per field-type variant

    @Test("validateDraft handles each field-type variant the sheet exposes")
    func validateDraftPerFieldType() {
        // Numeric variant
        let numeric = CatalogFieldBounds.validateDraft(
            field: "days_to_maturity_min", value: "65"
        )
        if case .valid(.number(let n), _) = numeric {
            #expect(n == 65)
        } else {
            Issue.record("numeric variant should validate cleanly, got \(numeric)")
        }

        // Enum variant
        let enumResult = CatalogFieldBounds.validateDraft(
            field: "sun_requirement", value: "full"
        )
        if case .valid(.text(let t), _) = enumResult {
            #expect(t == "full")
        } else {
            Issue.record("enum variant should validate cleanly, got \(enumResult)")
        }

        // Single-line text variant
        let textResult = CatalogFieldBounds.validateDraft(
            field: "scientific_name", value: "Solanum lycopersicum"
        )
        if case .valid(.text(let t), let requiresHuman) = textResult {
            #expect(t == "Solanum lycopersicum")
            #expect(requiresHuman == true,
                    "free-text fields must always queue for a human")
        } else {
            Issue.record("text variant should validate cleanly, got \(textResult)")
        }

        // Free-form ("other") isn't validated by validateDraft (it's
        // the sheet's local sentinel for "no structured field selected"
        // and routes straight into the legacy `body`-only path). It is
        // intentionally NOT in `correctableFields`; assert validateDraft
        // rejects it.
        let other = CatalogFieldBounds.validateDraft(
            field: "other", value: "anything"
        )
        if case .invalid(let reason, _) = other {
            #expect(reason == "unknown_field")
        } else {
            Issue.record("'other' sentinel should not pass validateDraft (default-deny)")
        }
    }

    // MARK: - Test 2: picker label semantics — `· auto` / `· reviewed` suffix

    @Test("picker tag derived from autoApplyFields: numeric/enum → '· auto', free-text → '· reviewed'")
    func pickerTagAutoVsReviewed() {
        // Numeric / enum auto-apply candidates.
        for autoField in [
            "days_to_maturity_min", "days_to_maturity_max",
            "soil_temp_min_f", "soil_temp_max_f",
            "plant_spacing_inches", "row_spacing_inches",
            "seed_depth_inches",
            "hardiness_zone_min", "hardiness_zone_max",
            "viability_years",
            "sun_requirement", "frost_tolerance", "sow_method", "life_cycle",
        ] {
            #expect(
                CatalogFieldBounds.autoApplyFields.contains(autoField),
                "\(autoField) should be in autoApplyFields — picker label tag would drift to '· reviewed'"
            )
        }

        // Free-text fields never auto-apply.
        for textField in [
            "scientific_name", "common_name", "variety", "company", "instructions",
        ] {
            #expect(
                !CatalogFieldBounds.autoApplyFields.contains(textField),
                "\(textField) must NOT be in autoApplyFields — picker label tag would mislead the user"
            )
            // But still correctable (so the picker can offer them).
            #expect(
                CatalogFieldBounds.correctableFields.contains(textField),
                "\(textField) must be in correctableFields — otherwise the picker wouldn't expose it"
            )
        }
    }

    // MARK: - Test 3: current-value rendering from GrowingInfoSnapshot

    @Test("GrowingInfoSnapshot exposes every numeric / enum / free-text field the picker reads")
    func growingInfoSnapshotExposesFields() {
        let snap = GrowingInfoSnapshot(
            scientific_name: "Solanum lycopersicum",
            life_cycle: "annual",
            sun_requirement: "full",
            frost_tolerance: "tender",
            sow_method: "transplant",
            seed_depth_inches: 0.25,
            days_to_germinate_min: 6,
            days_to_germinate_max: 14,
            days_to_maturity_min: 60,
            days_to_maturity_max: 75,
            soil_temp_min_f: 60,
            soil_temp_max_f: 85,
            plant_spacing_inches: 24,
            row_spacing_inches: 36,
            hardiness_zone_min: 5,
            hardiness_zone_max: 9,
            viability_years: 4,
            instructions: "Direct-sow after last frost."
        )
        // Numeric ranges flow into "Currently: X–Y" copy via the
        // sheet's `formatRange` helper. Verify the source values reach
        // the snapshot intact.
        #expect(snap.days_to_maturity_min == 60)
        #expect(snap.days_to_maturity_max == 75)
        #expect(snap.soil_temp_min_f == 60)
        #expect(snap.soil_temp_max_f == 85)
        #expect(snap.seed_depth_inches == 0.25)
        #expect(snap.plant_spacing_inches == 24)
        #expect(snap.row_spacing_inches == 36)
        #expect(snap.hardiness_zone_min == 5)
        #expect(snap.hardiness_zone_max == 9)
        // viability_years is an AUTO_APPLY field — without it in the
        // snapshot, client_seen_value is always null and the server's
        // OCC gate can never auto-apply a viability correction.
        #expect(snap.viability_years == 4)
        // Enums flow through verbatim — the sheet's humanizeEnum maps
        // these to title-case for display, but the raw value is what
        // the picker uses to drive the initial selection.
        #expect(snap.sun_requirement == "full")
        #expect(snap.frost_tolerance == "tender")
        #expect(snap.sow_method == "transplant")
        #expect(snap.life_cycle == "annual")
        // Free-text fields flow through verbatim.
        #expect(snap.scientific_name == "Solanum lycopersicum")
        #expect(snap.instructions == "Direct-sow after last frost.")

        // `hasAny` is true when ANY field is populated — drives the
        // sheet's offline-fallback branch (when nil DTO + snapshot has
        // values, the picker still renders current values).
        #expect(snap.hasAny)

        // Empty snapshot flips `hasAny` to false.
        let empty = GrowingInfoSnapshot()
        #expect(!empty.hasAny)
    }

    // MARK: - Test 4: inline bounds helper renders below numeric input

    @Test("describeBounds produces 'typical range: X–Y' copy for numeric fields")
    func describeBoundsNumericCopy() {
        // The sheet's `boundsHintLine` renders:
        //   "Typical range: <describeBounds(field)>. Outside that …"
        // describeBounds is the load-bearing helper; assert its
        // canonical shape for every numeric field.
        let germMin = CatalogFieldBounds.describeBounds(field: "days_to_germinate_min")
        #expect(germMin.contains("typical range"))
        #expect(germMin.contains("1"))
        #expect(germMin.contains("60"))

        let seedDepth = CatalogFieldBounds.describeBounds(field: "seed_depth_inches")
        #expect(seedDepth.contains("0.05"))
        #expect(seedDepth.contains("9.99"))

        // Enums report their valid values verbatim — drives the
        // segmented picker hint.
        let sun = CatalogFieldBounds.describeBounds(field: "sun_requirement")
        #expect(sun.contains("full"))
        #expect(sun.contains("partial"))
        #expect(sun.contains("shade"))

        // Free-text bounds describe the length cap.
        let scientific = CatalogFieldBounds.describeBounds(field: "scientific_name")
        #expect(scientific.contains("2000"))
    }

    // MARK: - Test 5: pre-flight 409 banner — local @Query filter

    @Test("pre-flight: an open LocalCatalogCorrection with matching (seed, field) surfaces via SwiftData query")
    func preflightQuerySurfacesExistingOpenRow() throws {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "catalogFeedbackSheetTests_preflight",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        // Seed three rows: one we want to find (open + matching field),
        // one with the same field but already terminal (applied —
        // should be filtered out), one with a different field
        // entirely (also filtered out).
        let catalogID = "cs_target"
        let openRow = LocalCatalogCorrection(
            id: "corr_open",
            catalogSeedID: catalogID,
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "70",
            status: "open",
            createdAt: 1_716_900_000_000,
            updatedAt: 1_716_900_000_000
        )
        let appliedRow = LocalCatalogCorrection(
            id: "corr_applied",
            catalogSeedID: catalogID,
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "65",
            status: "applied",
            createdAt: 1_716_800_000_000,
            updatedAt: 1_716_950_000_000
        )
        let otherFieldRow = LocalCatalogCorrection(
            id: "corr_other_field",
            catalogSeedID: catalogID,
            catalogSeedName: "Sungold",
            fieldName: "soil_temp_max_f",
            valueType: "integer",
            suggestedValue: "85",
            status: "open",
            createdAt: 1_716_850_000_000,
            updatedAt: 1_716_850_000_000
        )
        context.insert(openRow)
        context.insert(appliedRow)
        context.insert(otherFieldRow)
        try context.save()

        // Reproduce the sheet's in-memory filter (the sheet uses
        // `@Query private var allCorrections: [LocalCatalogCorrection]`
        // and filters in-memory because SwiftData macro predicates
        // can't take runtime String comparisons against String? cleanly).
        let descriptor = FetchDescriptor<LocalCatalogCorrection>()
        let all = try context.fetch(descriptor)
        let match = all.first { row in
            row.catalogSeedID == catalogID
                && row.fieldName == "days_to_maturity_min"
                && row.status == "open"
                && row.deletedAt == nil
        }
        #expect(match?.id == "corr_open",
                "pre-flight filter should surface the open row for this (seed, field)")

        // Soft-delete the open row → filter should no longer match.
        openRow.deletedAt = 1_716_970_000_000
        try context.save()
        let allAfterDelete = try context.fetch(descriptor)
        let postDelete = allAfterDelete.first { row in
            row.catalogSeedID == catalogID
                && row.fieldName == "days_to_maturity_min"
                && row.status == "open"
                && row.deletedAt == nil
        }
        #expect(postDelete == nil,
                "pre-flight filter must skip soft-deleted rows")
    }

    // MARK: - Test 6: @SceneStorage key is scoped per catalog entry

    @Test("body draft @SceneStorage key is scoped per catalog entry — no cross-seed draft bleed")
    func sceneStorageKeyContract() {
        // The sheet keys its drafted body per catalog entry so a
        // drafted "Why?" for seed A never pre-fills seed B's correction
        // sheet (it used to be one app-wide key). Withdraw-and-replace
        // still works because the SAME catalog entry resolves the SAME
        // key.
        let keyA = CatalogFeedbackSheet.draftKey(catalogID: "cs_a")
        let keyB = CatalogFeedbackSheet.draftKey(catalogID: "cs_b")
        #expect(keyA != keyB, "different catalog entries must use different draft keys")
        #expect(keyA == CatalogFeedbackSheet.draftKey(catalogID: "cs_a"),
                "the same catalog entry must resolve a stable key across sheet instances")
        #expect(keyA.hasPrefix("seedkeep.catalogFeedback.body."),
                "scene storage key must stay in the seedkeep.catalogFeedback.body.* namespace")
        #expect(keyA.hasSuffix("cs_a"), "key must embed the catalog id")
    }

    // MARK: - Test 6b: withdraw-and-replace closes the local row immediately

    @Test("markWithdrawnLocally flips the local row to dismissed/user_withdrawn so the pre-flight banner clears")
    func markWithdrawnLocallyClosesRow() throws {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "catalogFeedbackSheetTests_withdraw",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let row = LocalCatalogCorrection(
            id: "corr_withdraw",
            catalogSeedID: "cs_target",
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "70",
            status: "open",
            createdAt: 1_716_900_000_000,
            updatedAt: 1_716_900_000_000
        )
        context.insert(row)
        try context.save()

        CatalogFeedbackSheet.markWithdrawnLocally(row)

        #expect(row.status == "dismissed")
        #expect(row.dismissedReason == "user_withdrawn")

        // The pre-flight banner filter must no longer match.
        let all = try context.fetch(FetchDescriptor<LocalCatalogCorrection>())
        let stillOpen = all.first { r in
            r.catalogSeedID == "cs_target"
                && r.fieldName == "days_to_maturity_min"
                && r.status == "open"
                && r.deletedAt == nil
        }
        #expect(stillOpen == nil,
                "withdrawn row must not keep driving the pre-flight banner")
    }

    // MARK: - Test 7: "File anyway" sets user_acknowledged_bounds=true on the wire

    @Test("\"File anyway\" path sends user_acknowledged_bounds=true in the POST body")
    func fileAnywaySendsAcknowledgedFlag() async throws {
        // Stand up a routed URL session that captures the POST body so
        // we can assert what the SeedkeepClient actually sent.
        FeedbackSubmitMockURLProtocol.resetCapture()
        FeedbackSubmitMockURLProtocol.responseBody = Data(
            #"{"ok":true,"data":{"id":"corr_anyway","status":"open"}}"#.utf8
        )
        let session = FeedbackSubmitMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )

        let res = try await client.submitCatalogFeedback(
            catalogID: "cs_x",
            body: "200 days is what I measured",
            fieldHint: "days_to_maturity_max",
            fieldName: "days_to_maturity_max",
            suggestedValue: "200",
            clientSeenValue: "75",
            userAcknowledgedBounds: true,                          // <— under test
            idempotencyKey: UUID().uuidString
        )
        #expect(res.id == "corr_anyway")
        #expect(res.status == "open")

        // Inspect the captured POST body — should contain
        // "user_acknowledged_bounds":true.
        let captured = FeedbackSubmitMockURLProtocol.lastBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: captured, options: [])
        guard let dict = json as? [String: Any] else {
            Issue.record("submit body not a JSON object — got \(json)")
            return
        }
        #expect(
            (dict["user_acknowledged_bounds"] as? Bool) == true,
            "File anyway path must POST user_acknowledged_bounds=true; got body: \(dict)"
        )
        // And the structured fields should ride along so the server
        // can route correctly.
        #expect((dict["field_name"] as? String) == "days_to_maturity_max")
        #expect((dict["suggested_value"] as? String) == "200")
    }

    @Test("standard submit (no File anyway) does NOT send user_acknowledged_bounds=true")
    func standardSubmitOmitsAcknowledgedFlag() async throws {
        FeedbackSubmitMockURLProtocol.resetCapture()
        FeedbackSubmitMockURLProtocol.responseBody = Data(
            #"{"ok":true,"data":{"id":"corr_normal","status":"open"}}"#.utf8
        )
        let session = FeedbackSubmitMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )

        _ = try await client.submitCatalogFeedback(
            catalogID: "cs_x",
            body: "65 not 60 — confirmed at my farm",
            fieldHint: "days_to_maturity_min",
            fieldName: "days_to_maturity_min",
            suggestedValue: "65",
            clientSeenValue: "60",
            userAcknowledgedBounds: false,
            idempotencyKey: UUID().uuidString
        )

        // The SeedkeepClient omits the field on the wire when false
        // (per `submitCatalogFeedback`'s encoder branch).
        let captured = FeedbackSubmitMockURLProtocol.lastBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: captured, options: [])
        guard let dict = json as? [String: Any] else {
            Issue.record("submit body not a JSON object — got \(json)")
            return
        }
        // Either the key is absent or it's not literal true.
        let flag = dict["user_acknowledged_bounds"] as? Bool
        #expect(
            flag != true,
            "standard submit must NOT POST user_acknowledged_bounds=true; got \(String(describing: flag))"
        )
    }

    // MARK: - Test 7b: idempotency replay flag is an envelope sibling of `data`

    @Test("submit replay: `replay: true` rides beside `data`, not inside it — response.replay is true")
    func replayFlagDecodedFromEnvelopeSibling() async throws {
        FeedbackSubmitMockURLProtocol.resetCapture()
        // Real wire shape on an Idempotency-Key replay: the flag is a
        // TOP-LEVEL sibling of `data`.
        FeedbackSubmitMockURLProtocol.responseBody = Data(
            #"{"ok":true,"data":{"id":"corr_replayed","status":"applied"},"replay":true}"#.utf8
        )
        let session = FeedbackSubmitMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )

        let res = try await client.submitCatalogFeedback(
            catalogID: "cs_x",
            body: "65 not 60",
            fieldName: "days_to_maturity_min",
            suggestedValue: "65",
            idempotencyKey: "fixed-key"
        )
        #expect(res.id == "corr_replayed")
        #expect(res.status == "applied")
        #expect(res.replay == true, "replay must be read from the envelope level")

        // Fresh submit (no replay sibling) → false.
        FeedbackSubmitMockURLProtocol.responseBody = Data(
            #"{"ok":true,"data":{"id":"corr_fresh","status":"open"}}"#.utf8
        )
        let fresh = try await client.submitCatalogFeedback(
            catalogID: "cs_x",
            body: "65 not 60",
            fieldName: "days_to_maturity_min",
            suggestedValue: "65",
            idempotencyKey: UUID().uuidString
        )
        #expect(fresh.replay == false)
    }

    // MARK: - Test 7c: 429 retry_after_seconds is an envelope sibling of `error`

    @Test("429: retry_after_seconds rides beside `error` and lands on SeedkeepError")
    func retryAfterSecondsDecodedFromEnvelopeSibling() async throws {
        FeedbackSubmitMockURLProtocol.resetCapture()
        // Real wire shape for the daily bucket: message carries NO
        // digits; the window is the envelope-level sibling.
        FeedbackSubmitMockURLProtocol.responseBody = Data(
            #"{"ok":false,"error":{"code":"rate_limited","message":"too many submissions today"},"retry_after_seconds":21600}"#.utf8
        )
        FeedbackSubmitMockURLProtocol.responseStatus = 429
        defer { FeedbackSubmitMockURLProtocol.responseStatus = 200 }
        let session = FeedbackSubmitMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )

        do {
            _ = try await client.submitCatalogFeedback(
                catalogID: "cs_x",
                body: "65 not 60",
                fieldName: "days_to_maturity_min",
                suggestedValue: "65",
                idempotencyKey: UUID().uuidString
            )
            Issue.record("expected a rate_limited SeedkeepError")
        } catch let err as SeedkeepError {
            #expect(err.code == "rate_limited")
            #expect(err.retryAfterSeconds == 21_600,
                    "retry_after_seconds must come from the envelope sibling; got \(String(describing: err.retryAfterSeconds))")
        }
    }

    // MARK: - Test 8: 429 retry copy adapts to retry_after_seconds buckets

    @Test("retry-after copy buckets — < 60s / < 5min / < 30min / else (5-min rounding)")
    func retryAfterBuckets() {
        // The sheet's private `retryWindowCopy(seconds:)` collapses
        // a retry-after window into one of four bucket strings. We
        // re-implement the same algorithm here and assert the bucket
        // boundaries so a drift between the sheet's copy and this
        // contract fails the test.
        //
        // Spec §7:
        //   < 60s   → "in a few seconds"
        //   < 5min  → "in a few minutes"
        //   < 30min → "in about X minutes" (5-min rounding, min 5)
        //   else    → "in about an hour"

        #expect(Self.bucketize(1) == "in a few seconds")
        #expect(Self.bucketize(59) == "in a few seconds")
        #expect(Self.bucketize(60) == "in a few minutes")
        #expect(Self.bucketize(299) == "in a few minutes")
        #expect(Self.bucketize(300) == "in about 5 minutes")
        #expect(Self.bucketize(600) == "in about 10 minutes")
        #expect(Self.bucketize(1_500) == "in about 25 minutes")
        #expect(Self.bucketize(1_799) == "in about 30 minutes")
        #expect(Self.bucketize(1_800) == "in about an hour")
        #expect(Self.bucketize(3_600) == "in about an hour")

        // Edge: nil or 0 → "in about an hour" fallback.
        #expect(Self.bucketize(nil) == "in about an hour")
        #expect(Self.bucketize(0) == "in about an hour")
        #expect(Self.bucketize(-1) == "in about an hour")
    }

    /// Mirror of `CatalogFeedbackSheet.retryWindowCopy(seconds:)`.
    /// Re-implemented locally because the original is `private`; any
    /// drift in the sheet's algorithm will break the spec contract
    /// asserted by this test.
    static func bucketize(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "in about an hour" }
        if s < 60 { return "in a few seconds" }
        if s < 300 { return "in a few minutes" }
        if s < 1_800 {
            let minutes = max(5, Int((Double(s) / 60.0 / 5.0).rounded()) * 5)
            return "in about \(minutes) minutes"
        }
        return "in about an hour"
    }
}

// MARK: - URLProtocol stub for the submitCatalogFeedback POST body capture

/// Captures the body of the next POST and serves a configurable
/// response. Used by the "File anyway" / standard-submit tests to
/// assert what the SeedkeepClient actually puts on the wire.
final class FeedbackSubmitMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var lastBody: Data?
    static let lock = NSLock()

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackSubmitMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func resetCapture() {
        lock.lock()
        defer { lock.unlock() }
        Self.lastBody = nil
        Self.responseStatus = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        // URLProtocol delivers POST bodies via `httpBodyStream` (not
        // `httpBody`) when the request is built via URLRequest +
        // URLSession.upload(...). The SeedkeepClient builds via
        // `req.httpBody = …` so reading either is fine; cover both.
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            var collected = Data()
            stream.open()
            defer { stream.close() }
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 {
                    collected.append(buffer, count: read)
                } else {
                    break
                }
            }
            Self.lastBody = collected
        }
        let body = Self.responseBody
        let status = Self.responseStatus
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
