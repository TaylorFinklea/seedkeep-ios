import Foundation
import CoreGraphics

/// Canonical horizontal/vertical/section spacing rhythm used across the
/// herbarium UI. Codifies the 22/26 pattern that previously lived as raw
/// magic numbers in every view.
///
/// Usage:
/// ```swift
/// .padding(.horizontal, HerbSpace.gutter)        // 22
/// .padding(.horizontal, HerbSpace.titleGutter)   // 26 — title block inset
/// .padding(.vertical, HerbSpace.sectionRhythm)   // 12 — between rule + section
/// ```
enum HerbSpace {
    /// Standard horizontal page gutter for full-width content (rows, rules).
    static let gutter: CGFloat = 22

    /// Page-title gutter — title block sits slightly inset from rules / lists.
    static let titleGutter: CGFloat = 26

    /// Vertical rhythm between scholar-rule and next section.
    static let sectionRhythm: CGFloat = 12

    /// Tight vertical rhythm inside a section (e.g. between subtitle and body).
    static let tight: CGFloat = 6

    /// Bottom-pad for tab roots so SproutFAB doesn't sit atop content.
    static let fabClearance: CGFloat = 96
}
