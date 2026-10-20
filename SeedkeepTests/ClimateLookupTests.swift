import Testing
import Foundation
@testable import Seedkeep

// The bundled table is Seedkeep/Resources/Climate/zip_climate.csv, built from the server's ZIP
// dataset by scripts/build-climate-resources.py. The rows below are copied from that file.

@Suite("ClimateLookup — bundled ZIP table")
struct ClimateLookupTests {
    @Test("a known ZIP resolves to its coordinates, zone and zone frost dates")
    func knownZip() {
        let climate = ClimateLookup.climate(forZip: "10001")
        #expect(climate == HomeClimate(
            zip: "10001",
            latitude: 40.75074,
            longitude: -73.99653,
            usdaZone: "7b",
            avgLastFrost: "04-01",
            avgFirstFrost: "11-08"
        ))
    }

    @Test("a ZIP with a leading zero resolves")
    func leadingZeroZip() {
        let climate = ClimateLookup.climate(forZip: "00601")
        #expect(climate?.usdaZone == "11b")
        #expect(climate?.avgLastFrost == "01-01")
        #expect(climate?.avgFirstFrost == "12-31")
    }

    @Test("ZIPs across the country resolve to their zones")
    func zonesAcrossTheCountry() {
        #expect(ClimateLookup.climate(forZip: "90001")?.usdaZone == "10b")
        #expect(ClimateLookup.climate(forZip: "99501")?.usdaZone == "5a")
        #expect(ClimateLookup.climate(forZip: "02139")?.usdaZone == "6b")
    }

    @Test("an unknown ZIP returns nil")
    func unknownZip() {
        #expect(ClimateLookup.climate(forZip: "00000") == nil)
        #expect(ClimateLookup.climate(forZip: "99999") == nil)
    }

    @Test("a malformed ZIP returns nil without a lookup")
    func malformedZip() {
        #expect(ClimateLookup.climate(forZip: "") == nil)
        #expect(ClimateLookup.climate(forZip: "1000") == nil)
        #expect(ClimateLookup.climate(forZip: "100011") == nil)
        #expect(ClimateLookup.climate(forZip: "1000a") == nil)
        #expect(ClimateLookup.climate(forZip: " 10001") == nil)
        #expect(ClimateLookup.climate(forZip: "10001-1234") == nil)
    }
}

@Suite("ZoneFrostDates — zone-level frost table")
struct ZoneFrostDatesTests {
    @Test("the table covers the 26 zones from 1a to 13b")
    func coversEveryZone() {
        #expect(ZoneFrostDates.table.count == 26)
        #expect(ZoneFrostDates.frost(forZone: "1a") == ZoneFrost(lastFrost: "06-15", firstFrost: "08-15"))
        #expect(ZoneFrostDates.frost(forZone: "7a") == ZoneFrost(lastFrost: "04-10", firstFrost: "11-01"))
        #expect(ZoneFrostDates.frost(forZone: "13b") == ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"))
    }

    @Test("an unknown zone has no frost dates")
    func unknownZone() {
        #expect(ZoneFrostDates.frost(forZone: "14a") == nil)
        #expect(ZoneFrostDates.frost(forZone: "") == nil)
    }
}

@MainActor
@Suite("AppPreferences — home climate")
struct HomeClimatePreferencesTests {
    private func makePreferences() -> (AppPreferences, UserDefaults, String) {
        let suiteName = "HomeClimatePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let prefs = AppPreferences(defaults: defaults, bundleDefaultURL: URL(string: "https://example.invalid")!)
        return (prefs, defaults, suiteName)
    }

    @Test("homeClimate is nil until every location field is cached")
    func homeClimateNeedsEveryField() {
        let (prefs, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(prefs.homeClimate == nil)

        prefs.homeZip = "10001"
        prefs.cachedUsdaZone = "7b"
        prefs.cachedLatitude = 40.75074
        prefs.cachedLongitude = -73.99653
        #expect(prefs.homeClimate == nil)

        prefs.avgLastFrost = "04-01"
        prefs.avgFirstFrost = "11-08"
        #expect(prefs.homeClimate == HomeClimate(
            zip: "10001",
            latitude: 40.75074,
            longitude: -73.99653,
            usdaZone: "7b",
            avgLastFrost: "04-01",
            avgFirstFrost: "11-08"
        ))
    }

    @Test("saveHomeClimate caches every field and survives a relaunch")
    func saveRoundTrips() throws {
        let (prefs, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let climate = try #require(ClimateLookup.climate(forZip: "10001"))
        prefs.saveHomeClimate(climate)

        let relaunched = AppPreferences(defaults: defaults, bundleDefaultURL: URL(string: "https://example.invalid")!)
        #expect(relaunched.homeClimate == climate)
    }

    @Test("backfill fills the frost dates of a saved ZIP and leaves the coordinates alone")
    func backfillFillsMissingFrostDates() async {
        let (prefs, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.homeZip = "10001"
        prefs.cachedUsdaZone = "7b"
        prefs.cachedLatitude = 40.75074
        prefs.cachedLongitude = -73.99653

        await prefs.backfillFrostDates()

        #expect(prefs.avgLastFrost == "04-01")
        #expect(prefs.avgFirstFrost == "11-08")
        #expect(prefs.cachedLatitude == 40.75074)
        #expect(prefs.cachedLongitude == -73.99653)
        #expect(prefs.homeClimate != nil)
    }

    @Test("backfill leaves a ZIP the table does not know without frost dates")
    func backfillSkipsUnknownZip() async {
        let (prefs, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.homeZip = "00000"

        await prefs.backfillFrostDates()

        #expect(prefs.avgLastFrost == nil)
        #expect(prefs.avgFirstFrost == nil)
    }

    @Test("backfill does nothing when the frost dates are already cached")
    func backfillKeepsCachedDates() async {
        let (prefs, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.homeZip = "10001"
        prefs.avgLastFrost = "03-30"
        prefs.avgFirstFrost = "11-10"

        await prefs.backfillFrostDates()

        #expect(prefs.avgLastFrost == "03-30")
        #expect(prefs.avgFirstFrost == "11-10")
    }
}
