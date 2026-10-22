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
/// 3. `SeedkeepError` conforms to `LocalizedError` via `humanizeError`
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
        let patch = UpdateSeedInput(state: .active)
        let obj = try encodeToJSONObject(patch)
        #expect(obj.keys.sorted() == ["state"])
    }

    @Test func updateSeedInputEncodesExplicitNullForClear() throws {
        let patch = UpdateSeedInput(
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
        let patch = UpdateSeedInput(
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
            UpdateSeedInput.self, from: Data(json.utf8))
        #expect(patch.custom_name == .some(nil), "JSON null must decode to .some(nil)")
        #expect(patch.location_id == .some("loc_9"))
        #expect(patch.notes == nil, "absent key must decode to nil (leave alone)")
        #expect(patch.year_packed == nil)
    }

    @Test func updateSeedInputRoundTripsThroughJSON() throws {
        let original = UpdateSeedInput(
            packet_count: 3,
            year_packed: .some(nil),
            notes: "keep these"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UpdateSeedInput.self, from: data)
        #expect(decoded.packet_count == 3)
        #expect(decoded.year_packed == .some(nil))
        #expect(decoded.notes == .some("keep these"))
        #expect(decoded.custom_name == nil)
        #expect(decoded.location_id == nil)
    }

    // MARK: - UpdatePlantingEventInput completed_at

    @Test func updatePlantingEventEncodesNullForUncomplete() throws {
        let patch = UpdatePlantingEventInput(completed_at: .some(nil))
        let obj = try encodeToJSONObject(patch)
        #expect(obj.keys.contains("completed_at"))
        #expect(obj["completed_at"] is NSNull, "mark-incomplete must send JSON null, not a sentinel")
        #expect(obj.count == 1)
    }

    @Test func updatePlantingEventEncodesCompletedTimestamp() throws {
        let patch = UpdatePlantingEventInput(completed_at: 1_750_000_000_000)
        let obj = try encodeToJSONObject(patch)
        #expect((obj["completed_at"] as? NSNumber)?.int64Value == 1_750_000_000_000)
    }

    @Test func updatePlantingEventOmitsCompletedAtWhenUntouched() throws {
        let patch = UpdatePlantingEventInput(notes: "moved a row over")
        let obj = try encodeToJSONObject(patch)
        #expect(!obj.keys.contains("completed_at"))
        #expect(obj["notes"] as? String == "moved a row over")
    }

    @Test func updatePlantingEventDecodeRoundTripsNull() throws {
        let json = #"{"completed_at":null}"#
        let patch = try JSONDecoder().decode(
            UpdatePlantingEventInput.self, from: Data(json.utf8))
        #expect(patch.completed_at == .some(nil))
        let absent = try JSONDecoder().decode(
            UpdatePlantingEventInput.self, from: Data("{}".utf8))
        #expect(absent.completed_at == nil)
    }

    // MARK: - Client-supplied create ids (contract decision 7)

    @Test func createBedInputEncodesClientID() throws {
        let input = CreateBedInput(id: "bed_local_abc", name: "North bed")
        let obj = try encodeToJSONObject(input)
        #expect(obj["id"] as? String == "bed_local_abc")
        #expect(obj["name"] as? String == "North bed")
    }

    @Test func createPlantingEventInputEncodesClientID() throws {
        let input = CreatePlantingEventInput(
            id: "pe_local_abc",
            kind: .sowing,
            planned_for: "2026-06-15"
        )
        let obj = try encodeToJSONObject(input)
        #expect(obj["id"] as? String == "pe_local_abc")
        #expect(obj["kind"] as? String == "sowing")
    }

    @Test func createInputsOmitNilID() throws {
        let bed = try encodeToJSONObject(CreateBedInput(name: "B"))
        #expect(!bed.keys.contains("id"))
        let pe = try encodeToJSONObject(CreatePlantingEventInput(
            kind: .sowing, planned_for: "2026-06-15"))
        #expect(!pe.keys.contains("id"))
    }

    // MARK: - SeedkeepError LocalizedError

    @Test func seedkeepErrorLocalizedDescriptionIsHumanized() {
        let err = SeedkeepError(code: "not_found", message: "planting event not found")
        #expect(err.localizedDescription == humanizeError(err))
        #expect(!err.localizedDescription.contains("SeedkeepError error"),
                "must not show the NSError bridge placeholder")
        let unauthorized = SeedkeepError(code: "unauthorized", message: "Missing authorization token")
        #expect(unauthorized.localizedDescription.contains("Sign in"))
    }
}
