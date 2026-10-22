import Testing
@testable import Seedkeep

/// `GrowingInfoSnapshot` carries a seed's growing info, and `hasAny` decides whether seed detail
/// shows the growing-info section. (Moved from the removed catalog-feedback tests in N3.)
struct GrowingInfoSnapshotTests {
    @Test("GrowingInfoSnapshot keeps every numeric, enum and free-text field")
    func growingInfoSnapshotKeepsFields() {
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
        #expect(snap.days_to_maturity_min == 60)
        #expect(snap.days_to_maturity_max == 75)
        #expect(snap.soil_temp_min_f == 60)
        #expect(snap.soil_temp_max_f == 85)
        #expect(snap.seed_depth_inches == 0.25)
        #expect(snap.plant_spacing_inches == 24)
        #expect(snap.row_spacing_inches == 36)
        #expect(snap.hardiness_zone_min == 5)
        #expect(snap.hardiness_zone_max == 9)
        #expect(snap.viability_years == 4)
        #expect(snap.sun_requirement == "full")
        #expect(snap.frost_tolerance == "tender")
        #expect(snap.sow_method == "transplant")
        #expect(snap.life_cycle == "annual")
        #expect(snap.scientific_name == "Solanum lycopersicum")
        #expect(snap.instructions == "Direct-sow after last frost.")
    }

    @Test("hasAny is true when any field is set and false for an empty snapshot")
    func hasAnyReflectsContent() {
        #expect(GrowingInfoSnapshot(viability_years: 4).hasAny)
        #expect(!GrowingInfoSnapshot().hasAny)
    }
}
