/// The climate facts for one home ZIP, resolved offline by `ClimateLookup`. The frost dates are
/// zone-level estimates (see `Seedkeep/Resources/Climate/SOURCES.md`), not measured for the ZIP.
struct HomeClimate: Codable, Equatable, Sendable {
    let zip: String
    let latitude: Double
    let longitude: Double
    let usdaZone: String
    /// Average last spring frost, "MM-DD".
    let avgLastFrost: String
    /// Average first autumn frost, "MM-DD".
    let avgFirstFrost: String
}
