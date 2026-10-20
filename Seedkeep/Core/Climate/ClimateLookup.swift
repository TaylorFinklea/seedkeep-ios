import Foundation

/// Offline ZIP lookup over the bundled `Climate/zip_climate.csv` (every ZIP in the Census ZCTA
/// gazetteer, zoned from the USDA Plant Hardiness Zone Map). The file parses once, on first use,
/// behind a `static let`, which Swift initializes once and thread-safely. The first load is about
/// one parse of 33,751 rows, so call from a detached task when it may run before the table is
/// warm.
enum ClimateLookup {
    private struct Row: Sendable {
        let latitude: Double
        let longitude: Double
        let zone: String
    }

    private static let rows: [String: Row] = loadRows()

    /// The climate for a ZIP, or nil when the ZIP is not exactly five ASCII digits or is not in
    /// the table.
    static func climate(forZip zip: String) -> HomeClimate? {
        guard isFiveDigits(zip),
              let row = rows[zip],
              let frost = ZoneFrostDates.frost(forZone: row.zone) else { return nil }
        return HomeClimate(
            zip: zip,
            latitude: row.latitude,
            longitude: row.longitude,
            usdaZone: row.zone,
            avgLastFrost: frost.lastFrost,
            avgFirstFrost: frost.firstFrost
        )
    }

    private static func isFiveDigits(_ zip: String) -> Bool {
        zip.count == 5 && zip.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func loadRows() -> [String: Row] {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "zip_climate", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("zip_climate.csv is missing from the app bundle")
            return [:]
        }
        var rows: [String: Row] = [:]
        rows.reserveCapacity(33_751)
        // Line 1 is the header `zip,lat,lon,zone`.
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let latitude = Double(fields[1]),
                  let longitude = Double(fields[2]) else { continue }
            rows[String(fields[0])] = Row(latitude: latitude, longitude: longitude, zone: String(fields[3]))
        }
        return rows
    }

    /// Anchors `Bundle(for:)` to the bundle that holds this module's resources.
    private final class BundleAnchor {}
}
