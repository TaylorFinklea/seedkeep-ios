import Foundation

/// Single source of truth for any per-day notification identifier or
/// per-day map key emitted by the weather-warnings stack.
///
/// Identifiers are anchored to the **home location's** timezone (sourced
/// from WeatherKit forecast metadata), not the device timezone. That way
/// a user travelling abroad still gets warnings keyed to their garden's
/// local day — and identifiers stay stable across multiple devices on the
/// same iCloud account.
///
/// Locale is fixed to `en_US_POSIX` and calendar to gregorian so the
/// rendered YMD is byte-for-byte stable regardless of the user's regional
/// settings.
enum Identifier {
    /// YMD formatted in the supplied home timezone. en_US_POSIX, gregorian.
    /// MUST be used wherever a per-day notification identifier is generated
    /// OR a `pastRain` map key is computed. Never use `Date.description`
    /// or `Calendar.current` for that purpose.
    static func isoDay(_ date: Date, in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        return f.string(from: date)
    }
}
