import SwiftUI

/// Canonical herbarium form chrome: vellum-backed scroll surface where the
/// stock Form blends into the page. Apply to any Form-containing root view
/// (sheets, Settings sub-views, Add* flows) so the form sections render as
/// herbarium specimen rows instead of stock iOS list chrome.
///
/// Usage:
/// ```swift
/// Form { ... }.vellumForm()
/// ```
extension View {
    func vellumForm() -> some View {
        ZStack {
            VellumBackground()
            self.scrollContentBackground(.hidden)
        }
    }
}
