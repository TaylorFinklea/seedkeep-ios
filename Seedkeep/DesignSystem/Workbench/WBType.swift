// Workbench type scale (R2a). Every role is a system text style, so Dynamic Type scales it.
// The body, caption and monospaced fonts stay in WBColor.swift (parent-owned).
import SwiftUI

/// One Workbench type role: a system text style with an optional weight. A role has no point
/// size, so there is no way to build a fixed-size Workbench font.
struct WBTextRole: Equatable {
    let style: Font.TextStyle
    let weight: Font.Weight?

    var font: Font { .system(style, weight: weight) }
}

enum WBType {
    static let largeTitle = WBTextRole(style: .largeTitle, weight: .semibold)
    static let title = WBTextRole(style: .title2, weight: .semibold)
    static let headline = WBTextRole(style: .headline, weight: nil)
    static let callout = WBTextRole(style: .callout, weight: nil)
    static let footnote = WBTextRole(style: .footnote, weight: nil)
    /// Section labels (`WBSectionHeader`), set in capitals by the header.
    static let sectionLabel = WBTextRole(style: .caption, weight: .semibold)
}

extension Font {
    static let wbLargeTitle = WBType.largeTitle.font
    static let wbTitle = WBType.title.font
    static let wbHeadline = WBType.headline.font
    static let wbCallout = WBType.callout.font
    static let wbFootnote = WBType.footnote.font
    static let wbSectionLabel = WBType.sectionLabel.font
}
