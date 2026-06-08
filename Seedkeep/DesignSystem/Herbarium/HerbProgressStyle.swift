import SwiftUI

extension View {
    /// Tints embedded ProgressView with HerbColor.sepia. Use at every
    /// ProgressView call site so loading indicators stay on-palette.
    func herbProgressStyle() -> some View {
        self.tint(HerbColor.sepia)
    }
}
