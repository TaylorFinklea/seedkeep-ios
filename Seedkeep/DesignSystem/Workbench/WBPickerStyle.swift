// Picker style at accessibility text sizes (C3). A menu's options don't grow with Dynamic Type; a
// navigation-link picker pushes a list that does. iOS only: macOS has no navigation-link style.
import SwiftUI

extension View {
    /// Uses `.navigationLink` on iOS at accessibility sizes and keeps the picker's current style
    /// everywhere else. Apply it to the `Picker` itself, so no other picker in its section changes.
    func wbAccessibilityPickerStyle() -> some View {
        #if os(iOS)
        return modifier(WBAccessibilityPickerStyle())
        #else
        return self
        #endif
    }
}

#if os(iOS)
private struct WBAccessibilityPickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.navigationLink)
        } else {
            content
        }
    }
}
#endif
