import Foundation

/// Sunrise / sunset calculation using the NOAA solar-position algorithm.
/// Inputs: latitude / longitude in degrees, date in user's local timezone.
/// Outputs: sunrise + sunset `Date` values for that day at that location,
/// converted to the device's current timezone.
///
/// Used by the Today screen's `SunArc`. Pure math — no WeatherKit call, no
/// network. Accurate to ≈1 minute for typical garden latitudes (the small
/// error is from atmospheric refraction modeling which we treat as the
/// standard 0.833°).
enum Solar {

    /// Result for a given location/date.
    struct DayLight {
        let sunrise: Date
        let sunset: Date
    }

    /// Compute sunrise + sunset for a coordinate on a calendar day.
    /// Returns nil for high-latitude polar day / polar night cases.
    static func dayLight(latitude: Double, longitude: Double, on date: Date = Date()) -> DayLight? {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else {
            return nil
        }
        let doy = dayOfYear(year: year, month: month, day: day)

        let gamma = 2 * .pi / 365.0 * Double(doy - 1)
        // Equation of time (minutes)
        let eqTime = 229.18 * (
            0.000075
            + 0.001868 * cos(gamma)
            - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma)
            - 0.040849 * sin(2 * gamma)
        )
        // Solar declination (radians)
        let decl = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.00148  * sin(3 * gamma)

        let latRad = latitude * .pi / 180
        // Solar zenith for sunrise/sunset: 90.833° (allows for atmospheric refraction)
        let zenith = 90.833 * .pi / 180
        let cosHourAngle = (cos(zenith) - sin(latRad) * sin(decl)) / (cos(latRad) * cos(decl))
        guard cosHourAngle >= -1 && cosHourAngle <= 1 else {
            // Polar day or night
            return nil
        }
        let hourAngleDeg = acos(cosHourAngle) * 180 / .pi

        // UTC minutes from midnight
        let sunriseUTC = 720 - 4 * (longitude + hourAngleDeg) - eqTime
        let sunsetUTC  = 720 - 4 * (longitude - hourAngleDeg) - eqTime

        guard let midnightUTC = utcMidnight(year: year, month: month, day: day) else {
            return nil
        }
        let sunrise = midnightUTC.addingTimeInterval(sunriseUTC * 60)
        let sunset  = midnightUTC.addingTimeInterval(sunsetUTC  * 60)
        return DayLight(sunrise: sunrise, sunset: sunset)
    }

    private static func dayOfYear(year: Int, month: Int, day: Int) -> Int {
        let cumNonLeap = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        var d = cumNonLeap[month - 1] + day
        if isLeap(year) && month > 2 { d += 1 }
        return d
    }

    private static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    private static func utcMidnight(year: Int, month: Int, day: Int) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = 0; c.minute = 0; c.second = 0
        return cal.date(from: c)
    }
}
