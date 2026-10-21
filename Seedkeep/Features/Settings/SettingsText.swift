import Foundation

/// Text for the Settings screen that is worth testing on its own.
enum SettingsText {
    /// The About row: "Version 0.4.0 (52)". When one part is missing it shows the other ("Build 52"
    /// or "Version 0.4.0"); when both are missing it returns nil and the row is hidden. An empty or
    /// blank version and a build of 0 count as missing.
    static func versionText(version: String, build: Int) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmed.isEmpty, build > 0) {
        case (false, true): return "Version \(trimmed) (\(build))"
        case (false, false): return "Version \(trimmed)"
        case (true, true): return "Build \(build)"
        case (true, false): return nil
        }
    }

    /// The What's New row's VoiceOver label. The unseen dot is visual only, so it is spoken as "new".
    static func whatsNewLabel(unseen: Bool) -> String {
        unseen ? "What's New, new" : "What's New"
    }
}
