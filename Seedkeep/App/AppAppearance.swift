import SwiftUI

/// The Light / Dark / System override. It's per device, shared by every window, independent of the
/// garden, and never synced. System follows the device's appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "seedkeep.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the device's appearance and its changes.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: ColorScheme.light
        case .dark: ColorScheme.dark
        }
    }

    /// The appearance a stored value selects. An unset or unknown value means System.
    static func resolve(_ storedValue: String?) -> AppAppearance {
        storedValue.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// The appearance the user chose on this device.
    static var stored: AppAppearance {
        resolve(DevicePreferences.store.string(forKey: storageKey))
    }
}

/// Applies the stored appearance to a window's content. It's a view, not the `App`, that reads the
/// preference, so the window updates as soon as Settings changes it.
struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey, store: DevicePreferences.store)
    private var storedAppearance: String = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(AppAppearance.resolve(storedAppearance).colorScheme)
    }
}
