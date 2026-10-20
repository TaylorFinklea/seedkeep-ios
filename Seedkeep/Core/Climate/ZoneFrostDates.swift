/// Average frost dates for one USDA hardiness zone, both "MM-DD".
struct ZoneFrost: Equatable, Sendable {
    let lastFrost: String
    let firstFrost: String
}

/// Zone-level frost dates, ported from the server's `ZONE_FROST_FALLBACK`
/// (`seedkeep-server/scripts/build-zip-dataset.ts`). They are estimates from NOAA 1991–2020
/// normals and horticultural references, not measurements for any one ZIP. Keep this table in
/// step with the server's.
enum ZoneFrostDates {
    static let table: [String: ZoneFrost] = [
        "1a": ZoneFrost(lastFrost: "06-15", firstFrost: "08-15"),
        "1b": ZoneFrost(lastFrost: "06-10", firstFrost: "08-20"),
        "2a": ZoneFrost(lastFrost: "06-08", firstFrost: "08-25"),
        "2b": ZoneFrost(lastFrost: "06-05", firstFrost: "08-28"),
        "3a": ZoneFrost(lastFrost: "06-01", firstFrost: "09-01"),
        "3b": ZoneFrost(lastFrost: "05-25", firstFrost: "09-08"),
        "4a": ZoneFrost(lastFrost: "05-20", firstFrost: "09-15"),
        "4b": ZoneFrost(lastFrost: "05-15", firstFrost: "09-22"),
        "5a": ZoneFrost(lastFrost: "05-10", firstFrost: "10-01"),
        "5b": ZoneFrost(lastFrost: "05-01", firstFrost: "10-08"),
        "6a": ZoneFrost(lastFrost: "04-25", firstFrost: "10-15"),
        "6b": ZoneFrost(lastFrost: "04-15", firstFrost: "10-22"),
        "7a": ZoneFrost(lastFrost: "04-10", firstFrost: "11-01"),
        "7b": ZoneFrost(lastFrost: "04-01", firstFrost: "11-08"),
        "8a": ZoneFrost(lastFrost: "03-20", firstFrost: "11-15"),
        "8b": ZoneFrost(lastFrost: "03-10", firstFrost: "11-25"),
        "9a": ZoneFrost(lastFrost: "02-20", firstFrost: "12-10"),
        "9b": ZoneFrost(lastFrost: "02-01", firstFrost: "12-20"),
        "10a": ZoneFrost(lastFrost: "01-20", firstFrost: "12-31"),
        "10b": ZoneFrost(lastFrost: "01-10", firstFrost: "12-31"),
        "11a": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
        "11b": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
        "12a": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
        "12b": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
        "13a": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
        "13b": ZoneFrost(lastFrost: "01-01", firstFrost: "12-31"),
    ]

    static func frost(forZone zone: String) -> ZoneFrost? {
        table[zone]
    }
}
