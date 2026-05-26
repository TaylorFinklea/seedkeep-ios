import Foundation

/// Roman numeral conversion. Used for folio markers ("fol. xxiii"),
/// specimen numbers ("no. I"), section rubrics ("I. growing info"),
/// and plot numbers ("Plot II"). Counts inside lists/badges stay
/// Arabic per the design decision — only display elements get Romanized.
enum HerbRomanNumeral {

    /// Roman numeral string for the given non-negative integer.
    /// Returns "0" for n == 0 (no Roman zero) and the Arabic numeral
    /// for n > 3999 (Roman gets unreadable past that, and we won't have
    /// folios numbered 4000+).
    static func string(for n: Int, lowercase: Bool = true) -> String {
        guard n > 0 else { return "0" }
        guard n <= 3999 else { return String(n) }

        let pairs: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100,  "c"), (90,  "xc"), (50,  "l"), (40,  "xl"),
            (10,   "x"), (9,   "ix"), (5,   "v"), (4,   "iv"),
            (1,    "i"),
        ]

        var remaining = n
        var out = ""
        for (value, glyph) in pairs {
            while remaining >= value {
                out += glyph
                remaining -= value
            }
        }
        return lowercase ? out : out.uppercased()
    }

    /// Convenience for display: "fol. xxiii", "Plot II", "no. I".
    static func folio(_ n: Int) -> String { string(for: n) }
}
