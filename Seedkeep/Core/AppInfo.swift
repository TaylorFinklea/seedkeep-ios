import Foundation

/// App identity numbers read from the bundle. `release.sh` stamps
/// `CFBundleVersion` (build) and `CFBundleShortVersionString` (marketing).
enum AppInfo {
    /// The build number (`CFBundleVersion`) as an Int, or 0 if unreadable.
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The marketing version (`CFBundleShortVersionString`), e.g. "0.4.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
