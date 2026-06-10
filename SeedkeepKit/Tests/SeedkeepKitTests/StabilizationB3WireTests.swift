import Testing
import Foundation
@testable import SeedkeepKit

/// Stabilization Batch 3 — wire-contract tests:
///
/// 1. `UpdateSeedInput` / `UpdatePlantingEventInput` double-optional
///    explicit-null pattern (contract decision 8): omitted vs JSON null
///    vs value, in both encode and decode directions (pending-write
///    payloads round-trip through JSON).
/// 2. Create inputs carry the optional client-supplied `id` (contract
///    decision 7).
/// 3. `DeltaPage` decodes the additive `cursor_id` tiebreaker and
///    tolerates servers that omit it (contract decision 9).
/// 4. `SeedkeepError` conforms to `LocalizedError` via `humanizeError`
///    so view-level `error.localizedDescription` sites stop showing the
///    NSError placeholder.
@Suite("Stabilization B3 — wire contract")
struct StabilizationB3WireTests {

    private func encodeToJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - UpdateSeedInput explicit nulls

    @Test func updateSeedInputOmitsUntouchedFields() throws {
        let patch = SeedkeepClient.UpdateSeedInput(state: .active)
        let obj = try encodeToJSONObject(patch)
        #expect(obj.keys.sorted() == ["state"])
    }

    @Test func updateSeedInputEncodesExplicitNullForClear() throws {
        let patch = SeedkeepClient.UpdateSeedInput(
            location_id: .some(nil),
            year_packed: .some(nil),
            custom_name: .some(nil),
            custom_variety: .some(nil),
            custom_company: .some(nil),
            notes: .some(nil)
        )
        let obj = try encodeToJSONObject(patch)
        for key in ["location_id", "year_packed", "custom_name", "custom_variety", "custom_company", "notes"] {
            #expect(obj.keys.contains(key), "\(key) must be present")
            #expect(obj[key] is NSNull, "\(key) must encode JSON null, got \(String(describing: obj[key]))")
        }
        #expect(!obj.keys.contains("state"))
        #expect(!obj.keys.contains("tag_ids"))
    }

    @Test func updateSeedInputEncodesValues() throws {
        let patch = SeedkeepClient.UpdateSeedInput(
            location_id: "loc_1",
            custom_name: "Cherokee Purple"
        )
        let obj = try encodeToJSONObject(patch)
        #expect(obj["location_id"] as? String == "loc_1")
        #expect(obj["custom_name"] as? String == "Cherokee Purple")
        #expect(!obj.keys.contains("notes"))
    }

    @Test func updateSeedInputDecodeDistinguishesOmittedFromNull() throws {
        // Pending-write payloads are decoded back before dispatch — the
        // omitted/null distinction must survive the round trip.
        let json = #"{"custom_name":null,"location_id":"loc_9"}"#
        let patch = try JSONDecoder().decode(
            SeedkeepClient.UpdateSeedInput.self, from: Data(json.utf8))
        #expect(patch.custom_name == .some(nil), "JSON null must decode to .some(nil)")
        #expect(patch.location_id == .some("loc_9"))
        #expect(patch.notes == nil, "absent key must decode to nil (leave alone)")
        #expect(patch.year_packed == nil)
    }

    @Test func updateSeedInputRoundTripsThroughJSON() throws {
        let original = SeedkeepClient.UpdateSeedInput(
            packet_count: 3,
            year_packed: .some(nil),
            notes: "keep these"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SeedkeepClient.UpdateSeedInput.self, from: data)
        #expect(decoded.packet_count == 3)
        #expect(decoded.year_packed == .some(nil))
        #expect(decoded.notes == .some("keep these"))
        #expect(decoded.custom_name == nil)
        #expect(decoded.location_id == nil)
    }

    // MARK: - UpdatePlantingEventInput completed_at

    @Test func updatePlantingEventEncodesNullForUncomplete() throws {
        let patch = SeedkeepClient.UpdatePlantingEventInput(completed_at: .some(nil))
        let obj = try encodeToJSONObject(patch)
        #expect(obj.keys.contains("completed_at"))
        #expect(obj["completed_at"] is NSNull, "mark-incomplete must send JSON null, not a sentinel")
        #expect(obj.count == 1)
    }

    @Test func updatePlantingEventEncodesCompletedTimestamp() throws {
        let patch = SeedkeepClient.UpdatePlantingEventInput(completed_at: 1_750_000_000_000)
        let obj = try encodeToJSONObject(patch)
        #expect((obj["completed_at"] as? NSNumber)?.int64Value == 1_750_000_000_000)
    }

    @Test func updatePlantingEventOmitsCompletedAtWhenUntouched() throws {
        let patch = SeedkeepClient.UpdatePlantingEventInput(notes: "moved a row over")
        let obj = try encodeToJSONObject(patch)
        #expect(!obj.keys.contains("completed_at"))
        #expect(obj["notes"] as? String == "moved a row over")
    }

    @Test func updatePlantingEventDecodeRoundTripsNull() throws {
        let json = #"{"completed_at":null}"#
        let patch = try JSONDecoder().decode(
            SeedkeepClient.UpdatePlantingEventInput.self, from: Data(json.utf8))
        #expect(patch.completed_at == .some(nil))
        let absent = try JSONDecoder().decode(
            SeedkeepClient.UpdatePlantingEventInput.self, from: Data("{}".utf8))
        #expect(absent.completed_at == nil)
    }

    // MARK: - Client-supplied create ids (contract decision 7)

    @Test func createBedInputEncodesClientID() throws {
        let input = SeedkeepClient.CreateBedInput(id: "bed_local_abc", name: "North bed")
        let obj = try encodeToJSONObject(input)
        #expect(obj["id"] as? String == "bed_local_abc")
        #expect(obj["name"] as? String == "North bed")
    }

    @Test func createPlantingEventInputEncodesClientID() throws {
        let input = SeedkeepClient.CreatePlantingEventInput(
            id: "pe_local_abc",
            kind: .sowing,
            planned_for: "2026-06-15"
        )
        let obj = try encodeToJSONObject(input)
        #expect(obj["id"] as? String == "pe_local_abc")
        #expect(obj["kind"] as? String == "sowing")
    }

    @Test func createInputsOmitNilID() throws {
        let bed = try encodeToJSONObject(SeedkeepClient.CreateBedInput(name: "B"))
        #expect(!bed.keys.contains("id"))
        let pe = try encodeToJSONObject(SeedkeepClient.CreatePlantingEventInput(
            kind: .sowing, planned_for: "2026-06-15"))
        #expect(!pe.keys.contains("id"))
    }

    // MARK: - DeltaPage cursor_id (contract decision 9)

    @Test func deltaPageDecodesCursorID() throws {
        let json = #"""
        { "items": [], "cursor": 1717000000000, "has_more": true, "cursor_id": "tag_zzz" }
        """#
        let page = try JSONDecoder().decode(DeltaPage<TagDTO>.self, from: Data(json.utf8))
        #expect(page.cursor == 1_717_000_000_000)
        #expect(page.cursor_id == "tag_zzz")
    }

    @Test func deltaPageToleratesMissingCursorID() throws {
        // Legacy server build without decision 9 — must decode, nil id.
        let json = #"{ "items": [], "cursor": 5, "has_more": false }"#
        let page = try JSONDecoder().decode(DeltaPage<TagDTO>.self, from: Data(json.utf8))
        #expect(page.cursor_id == nil)
    }

    // MARK: - SeedkeepError LocalizedError + httpStatus

    @Test func seedkeepErrorLocalizedDescriptionIsHumanized() {
        let err = SeedkeepError(code: "not_found", message: "planting event not found")
        #expect(err.localizedDescription == humanizeError(err))
        #expect(!err.localizedDescription.contains("SeedkeepError error"),
                "must not show the NSError bridge placeholder")
        let unauthorized = SeedkeepError(code: "unauthorized", message: "Missing authorization token")
        #expect(unauthorized.localizedDescription.contains("Sign in"))
    }

    @Test func envelopeFailureCarriesHTTPStatusThroughAttach() {
        let base = SeedkeepError(
            code: "rate_limited", message: "slow down", retryAfterSeconds: 1800)
        let attached = base.attaching(httpStatus: 429)
        #expect(attached.httpStatus == 429)
        #expect(attached.retryAfterSeconds == 1800)
        #expect(attached.code == "rate_limited")
    }
}
