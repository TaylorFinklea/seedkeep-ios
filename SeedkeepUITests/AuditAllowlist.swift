// Audit findings the R2d audit suppresses. Each entry needs a disposition, a reason and the
// condition for rechecking it; a "deferred defect" needs the owner's approval before it is added.
import XCTest

struct AuditAllowlistEntry: Sendable {
    enum Disposition: Sendable, CustomStringConvertible {
        /// A finding judged not to be an app defect, on the evidence in its reason (system-drawn
        /// controls, or text set in a scaling text style). Not a runtime proof.
        case acceptedLimitation
        /// A real defect fixed later, in the named phase. Needs the owner's approval.
        case deferredDefect(phase: String)

        var description: String {
            switch self {
            case .acceptedLimitation: "accepted limitation (judged not an app defect; see reason)"
            case .deferredDefect(let phase): "deferred defect (\(phase))"
            }
        }
    }

    /// How the entry names the element. A label and element type are used only when the element has
    /// no identifier.
    enum ElementMatch: Sendable, Equatable {
        case identifier(String)
        case labelAndType(label: String, type: XCUIElement.ElementType)
        /// An issue the audit reports without an element, so nothing names it. Matches only such
        /// issues, for the entry's destination, checkpoint and audit type; the reason must say which
        /// screenshots were reviewed.
        case unresolved
    }

    let destination: AuditDestination
    /// The recorded checkpoint name: `top`, `scrolled`, `page.<n>`, or an anchor's name. Nil matches
    /// any checkpoint: paged screens (Settings, Today) move the same element between `page.<n>`
    /// checkpoints as text size and content change.
    let checkpoint: String?
    let auditType: XCUIAccessibilityAuditType
    let element: ElementMatch
    let configurations: Set<AuditConfiguration>
    let disposition: Disposition
    let reason: String
    let recheckWhen: String
}

enum AuditAllowlist {
    /// Why an entry stands: the reason, and the condition that rechecks it.
    private struct Justification: Sendable {
        let reason: String
        let recheck: String
    }

    private static let toolbarButton = Justification(
        reason: "System toolbar (glass) button: fixed-size text with Large Content Viewer.",
        recheck: "If replaced with a custom button.")
    private static let systemTextField = Justification(
        reason: "System text field: scrolls its text horizontally instead of truncating.",
        recheck: "If the field becomes a multi-line or custom view.")
    private static let navigationTitle = Justification(
        reason: "System inline navigation title; shown in full in the R3 screenshots at every size.",
        recheck: "If the title becomes custom.")

    /// Dynamic Type on static text in a text style: the style and where it is set, then the audit's limit.
    private static func textStyle(_ style: String, _ source: String) -> Justification {
        Justification(
            reason: "Uses \(style) at \(source): a text style, so it scales with Dynamic Type (code-checked, "
                + "not measured per element). Why the audit flags it is not established.",
            recheck: "If the element's font changes.")
    }

    private static func accepted(
        _ destination: AuditDestination,
        _ checkpoint: String?,
        _ auditType: XCUIAccessibilityAuditType,
        _ element: AuditAllowlistEntry.ElementMatch,
        _ configurations: Set<AuditConfiguration>,
        _ justification: Justification
    ) -> AuditAllowlistEntry {
        AuditAllowlistEntry(
            destination: destination,
            checkpoint: checkpoint,
            auditType: auditType,
            element: element,
            configurations: configurations,
            disposition: .acceptedLimitation,
            reason: justification.reason,
            recheckWhen: justification.recheck
        )
    }

    /// A 1.0-triage entry: any checkpoint, all four configurations (umbrella decision 2026-11-19).
    private static func triaged(
        _ destination: AuditDestination,
        _ auditType: XCUIAccessibilityAuditType,
        _ element: AuditAllowlistEntry.ElementMatch,
        _ reason: String,
        _ recheck: String
    ) -> AuditAllowlistEntry {
        accepted(destination, nil, auditType, element,
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL],
                 Justification(reason: reason, recheck: recheck))
    }

    /// Accepted limitations, one entry per destination, checkpoint, type, label and element type. Findings
    /// not listed here stay unresolved (suspected audit noise is recorded in the R2 plan, not suppressed).
    static let entries: [AuditAllowlistEntry] = [
        // A. System toolbar buttons (Cancel, Save, Done, Close): Dynamic Type only. Their contrast
        //    findings stay unsuppressed: nothing here measures the rendered contrast.
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "Cancel", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "Save", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.addSeed, "top", .dynamicType,
                 .labelAndType(label: "Cancel", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.addSeed, "top", .dynamicType,
                 .labelAndType(label: "Save", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.windows, "top", .dynamicType,
                 .labelAndType(label: "Done", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.bedDetail, "squareDetails", .dynamicType,
                 .identifier("garden.squareDetails.done"),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.journalEntry, "top", .dynamicType,
                 .labelAndType(label: "Cancel", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.journalEntry, "top", .dynamicType,
                 .labelAndType(label: "Save", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.homeLocation, "top", .dynamicType,
                 .labelAndType(label: "Save", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),
        accepted(.whatsNew, "top", .dynamicType,
                 .labelAndType(label: "Close", type: .button),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], toolbarButton),

        // B. System text fields (UIKit text field and search field): clipped text.
        accepted(.seeds, "scrolled", .textClipped,
                 .labelAndType(label: "Search seeds", type: .searchField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),
        accepted(.seeds, "top", .textClipped,
                 .labelAndType(label: "Search seeds", type: .searchField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),
        accepted(.journal, "top", .textClipped,
                 .labelAndType(label: "Search journal", type: .searchField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),
        accepted(.seedDetail, "top", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),
        accepted(.addSeed, "scrolled", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault], systemTextField),
        accepted(.addSeed, "top", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),

        // C. The "Windows" inline navigation title: clipped text.
        accepted(.windows, "top", .textClipped,
                 .labelAndType(label: "Windows", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], navigationTitle),

        // D. Dynamic Type on static text in a text style, checked against the view code.
        accepted(.seedDetail, "plantingPanel", .dynamicType,
                 .labelAndType(label: "Add a sow, transplant, harvest, or note tied to this seed and (optionally) a bed.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote (form footer)", "SeedDetailView.swift:759")),
        accepted(.seedDetail, "plantingPanel", .dynamicType,
                 .labelAndType(label: "Missed this year", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption (semibold, WBStatusChip)", "RecommendationPanel.swift:63 and WBComponents.swift:208")),
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "NOTES", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbSectionLabel (WBSectionHeader)", "AddSeedView.swift:140")),
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "None", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], textStyle("the default body style (picker and tag values)", "AddSeedView.swift:101 and :114")),
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "Source", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Picker label)", "AddSeedView.swift:124")),
        accepted(.addSeed, "scrolled", .dynamicType,
                 .labelAndType(label: "Tags", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], textStyle("the default body style", "AddSeedView.swift:112")),
        accepted(.addSeed, "top", .dynamicType,
                 .labelAndType(label: "None", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (picker and tag values)", "AddSeedView.swift:101 and :114")),
        accepted(.addSeed, "top", .dynamicType,
                 .labelAndType(label: "Tags", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style", "AddSeedView.swift:112")),
        accepted(.randomPick, "top", .dynamicType,
                 .labelAndType(label: "1 packet", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption (medium weight)", "RandomPickView.swift:186")),
        accepted(.randomPick, "top", .dynamicType,
                 .labelAndType(label: "Baker Creek", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCallout", "RandomPickView.swift:151")),
        accepted(.randomPick, "top", .dynamicType,
                 .labelAndType(label: "Brandywine", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbTitle", "RandomPickView.swift:145")),
        accepted(.randomPick, "top", .dynamicType,
                 .labelAndType(label: "Notes: Save seed from the best fruit.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "RandomPickView.swift:168")),
        accepted(.randomPick, "top", .dynamicType,
                 .labelAndType(label: "packed 2025", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption (medium weight)", "RandomPickView.swift:186")),
        accepted(.journalEntry, "top", .dynamicType,
                 .labelAndType(label: "Add photos", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "JournalEntryView.swift:105")),
        accepted(.journalEntry, "top", .dynamicType,
                 .labelAndType(label: "CHECKLIST", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbSectionLabel (WBSectionHeader)", "JournalEntryView.swift:148")),
        accepted(.settings, "page.1", .dynamicType,
                 .labelAndType(label: "CloudKit sync hasn’t run yet — tap “Sync now”.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote", "SettingsView.swift:253")),
        accepted(.settings, "page.1", .dynamicType,
                 .labelAndType(label: "Frost dates estimated from the hardiness zone", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "SettingsView.swift:342")),
        accepted(.settings, "page.1", .dynamicType,
                 .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:339")),
        accepted(.settings, "page.1", .dynamicType,
                 .labelAndType(label: "USDA ARS Plant Hardiness Zone Map (2023)", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:336")),
        accepted(.settings, "page.2", .dynamicType,
                 .labelAndType(label: "Check iCloud account", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:226")),
        accepted(.settings, "page.2", .dynamicType,
                 .labelAndType(label: "CloudKit sync hasn’t run yet — tap “Sync now”.", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL], textStyle(".wbFootnote", "SettingsView.swift:253")),
        accepted(.settings, "page.2", .dynamicType,
                 .labelAndType(label: "Frost dates estimated from the hardiness zone", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "SettingsView.swift:342")),
        accepted(.settings, "page.2", .dynamicType,
                 .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:339")),
        accepted(.settings, "page.2", .dynamicType,
                 .labelAndType(label: "USDA ARS Plant Hardiness Zone Map (2023)", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:336")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "Check iCloud account", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:226")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "CloudKit sync hasn’t run yet — tap “Sync now”.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote", "SettingsView.swift:253")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "Frost dates estimated from the hardiness zone", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "SettingsView.swift:342")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:339")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "USDA ARS Plant Hardiness Zone Map (2023)", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:336")),
        accepted(.homeLocation, "top", .dynamicType,
                 .labelAndType(label: "Avg first frost", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "HomeLocationSettingsView.swift:49")),
        accepted(.homeLocation, "top", .dynamicType,
                 .labelAndType(label: "Avg last frost", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "HomeLocationSettingsView.swift:48")),
        accepted(.homeLocation, "top", .dynamicType,
                 .labelAndType(label: "USDA zone", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "HomeLocationSettingsView.swift:47")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "7am on the morning of any planned planting event", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "NotificationsSettingsView.swift:78")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "8am after 5 dry days with no soaking rain in the 3-day forecast", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "NotificationsSettingsView.swift:67")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "All notifications are scheduled on-device. Seedkeep doesn't send anything through Apple's push servers.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote (form footer)", "NotificationsSettingsView.swift:89")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "Planting reminders", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "NotificationsSettingsView.swift:77")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "Watering reminders", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "NotificationsSettingsView.swift:66")),
        accepted(.apiKeys, "top", .dynamicType,
                 .labelAndType(label: "Active", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "APIKeysSettingsView.swift:41 and :46")),

        // E. 1.0 triage (umbrella decision 2026-11-19). Every finding group from the 2026-11-18 audit was
        //    reviewed against its screenshots and view source, with a second reviewer challenging each
        //    call. None met the 1.0 blocker rules (no unlabeled control, no text below 3:1, no lost
        //    core-flow text, no fixed-size core-flow text). These entries match any checkpoint and all
        //    four configurations. Triage record: .docs/ai/plans/2026-11-19-a11y-triage.md.
        triaged(.today, .contrast, .labelAndType(label: "Black Seeded Simpson", type: .staticText),
                "Element screenshot shows the row ghosting behind the translucent Liquid Glass tab bar at the screen bottom; the text itself is WBColor.ink, which passes 4.5:1.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "Note", type: .staticText),
                "Muted footnote subtitle (>=5.43:1 on all surfaces) captured at page.N scroll while overlapping the glass tab bar; element screenshot is black/empty.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "See all in Windows", type: .staticText),
                "Accent-colored button text (>=4.5:1 by token measurement) sampled while paged near translucent bars; screenshot shows clear green on plain background.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "Sow · Lettuce", type: .staticText),
                "Row subtitle uses WBColor.muted (>=5.43:1) on the plain background; at top checkpoint it sits under the glass tab bar, so the sampled background is wrong.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "THIS WEEK", type: .staticText),
                "Section header previously measured 8.0:1 in pixels; the screenshot shows legible muted text on plain background, so the flag is a sampling artifact.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "Today", type: .staticText),
                "Large title is WBColor.ink, near-black on near-white; the audit's element frame overlaps the translucent nav/tab bars, so the contrast reading is wrong.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .labelAndType(label: "Transplant · Tomato", type: .staticText),
                "Muted subtitle on the plain background (>=5.43:1); flagged at page.1 where the row is half-hidden under the glass tab bar.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .identifier("today.frostBanner"),
                "Accent text on the warn-soft banner is at least 4.5:1 by token measurement; the screenshot shows bright green clearly legible, clipped only at the scroll edge under the tab bar.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.today, .contrast, .identifier("today.week.summary"),
                "WBColor.muted callout text (>=4.5:1) on the plain background; at default size the text is clearly legible and nothing overlaps it besides scroll-edge sampling.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.aiProvider, .contrast, .labelAndType(label: "Packet photos are sent to your AI provider with your own key. Your key is stored only on this device and sent only to your AI provider.", type: .staticText),
                "Footnote uses WBColor.muted, which measures >=5.43:1 on every surface; flag is a sampling artifact (scroll edge/glass overlap). Settings is not a core flow.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.apiKeys, .contrast, .unresolved,
                "No element resolved. Screenshot shows ink/muted text and a placeholder 'Paste key' (system placeholder color) plus a disabled Save button under the tab bar; no palette text below 3:1.",
                "If a later audit names an element for this screen and type."),
        triaged(.apiKeys, .contrast, .labelAndType(label: "API key from console.anthropic.com (starts with sk-ant-).", type: .staticText),
                "Helper text uses muted (>=5.43:1); flagged frame sits under the translucent tab bar at axxxl, so sampled pixels are glass, not palette.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.homeLocation, .contrast, .labelAndType(label: "Save", type: .button),
                "Toolbar Save is a system Liquid Glass button (disabled until a ZIP resolves); contrast is system-drawn.",
                "If replaced with a custom control."),
        triaged(.homeLocation, .contrast, .labelAndType(label: "ZIP", type: .staticText),
                "LabeledContent row with muted label/ink value, both >=4.5:1 on surfaces; single axxxl occurrence with no visible defect.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.notifications, .contrast, .labelAndType(label: "Heat warnings", type: .staticText),
                "Toggle label in ink/system text; palette text passes 4.5:1, flag appears only at axxxl and is a sampling artifact.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .unresolved,
                "No element resolved; page.N checkpoints with text half-hidden under translucent nav/tab bar (blurred 'Notifications' visible behind bar in screenshot). Palette text measures >=4.5:1.",
                "If a later audit names an element for this screen and type."),
        triaged(.settings, .contrast, .labelAndType(label: "AI", type: .staticText),
                "Section header (WBSectionHeader) in muted-class color passes >=4.5:1; flagged at page.1 scroll position near the nav bar edge.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .labelAndType(label: "Frost dates estimated from the hardiness zone", type: .staticText),
                "Caption uses WBColor.muted (>=5.43:1); one light-default occurrence at a scroll checkpoint.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .labelAndType(label: "None configured", type: .staticText),
                "Row detail uses muted (>=5.43:1); screenshot shows it legible on card, sits near the tab bar at page.2.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .labelAndType(label: "Privacy Policy", type: .link),
                "SwiftUI Link in app tint/accent (>=4.5:1 on surfaces); flagged at scroll checkpoints, likely glass overlap.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .labelAndType(label: "Sync now", type: .staticText),
                "Accent-colored label passes >=4.5:1; screenshot shows 'Sync now' blurred behind the tab bar at page.2/3, so audit sampled glass.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .contrast, .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                "Body text in ink (high contrast); flagged only at axxxl page.3 where it overlaps the tab bar.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.settings, .dynamicType, .unresolved,
                "No element resolved; every Settings font is Font.system(.textStyle) or WBType text style, which scale (axxxl screenshots show large text). No fixed-size fonts found.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "55401 · Zone 5a", type: .staticText),
                "Uses wbMonoCaption = Font.system(.caption, design: .monospaced), a text style that scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Appearance", type: .staticText),
                "Section header/picker row built from text-style fonts; audit callback is a false positive (same row scales at axxxl).",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "CloudKit sync hasn’t run yet — tap “Sync now”.", type: .staticText),
                "Text uses .wbFootnote (WBType footnote text style) and renders enlarged in axxxl.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Data sources", type: .staticText),
                "Uses .wbCaption.weight(.semibold), Font.system(.caption); scales with Dynamic Type.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Home location", type: .staticText),
                "NavigationLink row with .wbBody (Font.system(.body)); scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Locations", type: .staticText),
                "Row text is a system text style; scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Notifications", type: .staticText),
                "Row label in .wbBody text style; scales (screenshots show wrapped enlarged 'Notifications').",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Privacy Policy", type: .link),
                "SwiftUI Link with default body font; scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Support", type: .link),
                "Link/row in default system text style; scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Tags", type: .staticText),
                "Row label in text-style font; scales.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "What's New", type: .staticText),
                "Label(\"What's New\") uses default body text style; scales.",
                "If the element's font changes."),
        triaged(.settings, .textClipped, .unresolved,
                "No element resolved; axxxl screenshot shows Settings rows wrapping onto multiple lines with no truncation, and Settings is not a core flow.",
                "If a later audit names an element for this screen and type."),
        triaged(.settings, .textClipped, .labelAndType(label: "Check iCloud account", type: .staticText),
                "Label in a Button row wraps by default (no lineLimit); flagged at default size, so only a heuristic warning. Settings not core flow.",
                "If the row gains a line limit or a custom layout."),
        triaged(.settings, .textClipped, .labelAndType(label: "Locations", type: .staticText),
                "Short row label with no lineLimit; wraps in list rows, so no information lost. Heuristic warning at default size.",
                "If the row gains a line limit or a custom layout."),
        triaged(.settings, .textClipped, .labelAndType(label: "Sync now", type: .staticText),
                "Label in a Button row without lineLimit, wraps rather than truncates; heuristic warning at default size.",
                "If the row gains a line limit or a custom layout."),
        triaged(.settings, .textClipped, .labelAndType(label: "Tags", type: .staticText),
                "Short row label with no lineLimit; wraps, nothing lost. Settings not a core flow.",
                "If the row gains a line limit or a custom layout."),
        triaged(.settings, .textClipped, .labelAndType(label: "What's New", type: .staticText),
                "Label row without lineLimit wraps at large sizes; nothing truncated. Settings not a core flow.",
                "If the row gains a line limit or a custom layout."),
        triaged(.whatsNew, .contrast, .labelAndType(label: "Close", type: .button),
                "Toolbar Close button is a system Liquid Glass button; contrast is system-drawn.",
                "If replaced with a custom control."),
        triaged(.bedDetail, .contrast, .unresolved,
                "No resolved element; axxxl screenshots show palette text on opaque surfaces with only the Liquid Glass tab bar overlapping scrolled content, so a sampling artifact.",
                "If a later audit names an element for this screen and type."),
        triaged(.bedDetail, .contrast, .labelAndType(label: "BS", type: .staticText),
                "BS is a grid cell scrolled half under the translucent tab bar in the screenshot; cell text uses ink/muted tokens (>=4.5:1).",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.bedDetail, .contrast, .labelAndType(label: "D1", type: .staticText),
                "D1 is a grid cell clipped under the Liquid Glass tab bar at the bottom of the screenshot; tokens measure >=4.5:1.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.bedDetail, .contrast, .identifier("garden.squareDetails.done"),
                "Sheet toolbar Done is a system Liquid Glass button; its contrast is system-drawn and renders clearly legible in the screenshot.",
                "If replaced with a custom control."),
        triaged(.bedDetail, .dynamicType, .unresolved,
                "No element resolved; Garden text uses wb text-style fonts that scale (screenshots at axxxl show scaled text), so nothing identifiable as fixed-size.",
                "If a later audit names an element for this screen and type."),
        triaged(.bedDetail, .dynamicType, .labelAndType(label: "Date", type: .staticText),
                "Date is the system DatePicker compact control in the sheet Form; its font is system-drawn.",
                "If replaced with a custom control."),
        triaged(.bedDetail, .dynamicType, .labelAndType(label: "Done", type: .staticText),
                "Done is the sheet toolbar Liquid Glass button or the system Toggle label; both are system-drawn and the screenshot shows scaling at axxxl.",
                "If replaced with a custom control."),
        triaged(.bedDetail, .dynamicType, .labelAndType(label: "Spacing: 3 in", type: .staticText),
                "Spacing row uses text-style fonts (wbFootnote); screenshot at default shows a footnote row and axxxl screenshots show it scaling.",
                "If the element's font changes."),
        triaged(.bedDetail, .dynamicType, .labelAndType(label: "Task", type: .staticText),
                "Task is a system Picker row in the Form; its font is system-drawn and scales.",
                "If replaced with a custom control."),
        triaged(.bedDetail, .elementDetection, .unresolved,
                "No resolved element; the Planting sheet text is real SwiftUI text, likely the blurred list behind the sheet being detected.",
                "If a later audit names an element for this screen and type."),
        triaged(.bedDetail, .textClipped, .unresolved,
                "Likely the events-list note line (lineLimit(1) shows 'Two plants, s...') at axxxl; the full note is readable and editable in Square details, so no information is lost.",
                "If the truncated text becomes the only place the information appears."),
        triaged(.bedDetail, .textClipped, .labelAndType(label: "SUGAR SNAP", type: .staticText),
                "SUGAR SNAP header is fully visible at axxxl in the screenshot and wraps; no clipping observed.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.bedDetail, .textClipped, .labelAndType(label: "Spacing: 3 in", type: .staticText),
                "Spacing text is fully visible in the default-size screenshot and wraps at larger sizes; the audit flag is a heuristic.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.garden, .contrast, .labelAndType(label: "Next: Note, Nov 16", type: .staticText),
                "The Next row is scrolled under the translucent Liquid Glass tab bar in the screenshot; the element is muted text (>=4.5:1) on an opaque surface.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.windows, .contrast, .labelAndType(label: "Done", type: .button),
                "Windows sheet Done is a system Liquid Glass toolbar button; legible in the screenshot and system-drawn.",
                "If replaced with a custom control."),
        triaged(.windows, .dynamicType, .unresolved,
                "No element resolved at default size; Windows text uses text-style fonts and scales in the axxxl screenshot.",
                "If a later audit names an element for this screen and type."),
        triaged(.windows, .textClipped, .unresolved,
                "No resolved element; axxxl Windows screenshot shows seed names and dates wrapping fully with no truncation, only list cut off by the sheet edge.",
                "If a later audit names an element for this screen and type."),
        triaged(.addSeed, .contrast, .unresolved,
                "No resolved element; scrolled checkpoint where form content passes under the translucent Liquid Glass nav bar, a known sampling artifact. Visible form text is high-contrast.",
                "If a later audit names an element for this screen and type."),
        triaged(.addSeed, .contrast, .labelAndType(label: "1 packet", type: .staticText),
                "Element screenshot shows the Quantity row blurred behind the glass Cancel/title bar after scrolling; the row text is ink on a surface, and palette ink measures >=4.5:1.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.addSeed, .contrast, .labelAndType(label: "Cancel", type: .button),
                "Cancel is a system Liquid Glass toolbar button over blurred content; system-drawn and legible, labeled.",
                "If replaced with a custom control."),
        triaged(.addSeed, .contrast, .labelAndType(label: "Save", type: .button),
                "Save is a system glass toolbar button; the dimmed look in screenshots is the standard disabled state while Name is empty.",
                "If replaced with a custom control."),
        triaged(.addSeed, .dynamicType, .labelAndType(label: "Source", type: .staticText),
                "'Source' is the label of a native SwiftUI Picker row in a Form; it scales with Dynamic Type, as the axxxl screenshots show similar labels scaling.",
                "If replaced with a custom control."),
        triaged(.addSeed, .textClipped, .unresolved,
                "At axxxl the section headers, rows and placeholders wrap and scale fully in the screenshot; no information is lost or truncated.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.seedDetail, .contrast, .unresolved,
                "No resolved element; planting-panel screenshots show muted/ink palette text (>=4.5:1) plus glass bar overlap. Nothing visibly low-contrast.",
                "If a later audit names an element for this screen and type."),
        triaged(.seedDetail, .contrast, .labelAndType(label: "GROWING INFO", type: .staticText),
                "Section header uses muted token, which measures >=4.5:1 on all surfaces; flagged at top checkpoint where it sits against the glass nav bar.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.seedDetail, .dynamicType, .unresolved,
                "Planting panel text uses wbBody/wbCaption (Font.system text styles) and the screenshot confirms it renders at default size; the audit callback is unresolved and no fixed-size font is used there.",
                "If the element's font changes."),
        triaged(.seedDetail, .textClipped, .unresolved,
                "Unresolved element at default size. Visible planting panel is not clipped; the one truncated journal snippet is an intentional preview with a tappable entry for full text.",
                "If a later audit names an element for this screen and type."),
        triaged(.seeds, .contrast, .unresolved,
                "Mostly scrolled checkpoints with rows blurred under the glass search pill, toolbar and tab bar; visible row text is ink/muted on the surface with no low-contrast text.",
                "If the element moves off palette text tokens or onto a new surface."),
        triaged(.journal, .contrast, .unresolved,
                "No resolved element; top-checkpoint screenshots show Journal list under translucent glass toolbar/search/tab bar, where sampling artifacts are known. Palette text passes 4.5:1.",
                "If a later audit names an element for this screen and type."),
        triaged(.journalEntry, .contrast, .labelAndType(label: "Cancel", type: .button),
                "Cancel is a system Liquid Glass toolbar button; green label on glass renders legibly in screenshots and contrast is system-drawn.",
                "If replaced with a custom control."),
        triaged(.journalEntry, .contrast, .labelAndType(label: "Save", type: .button),
                "Save is a system Liquid Glass toolbar button; label is clearly legible in screenshots and contrast is system-drawn.",
                "If replaced with a custom control."),
        triaged(.journalEntry, .textClipped, .labelAndType(label: "Add photos", type: .staticText),
                "Default-size screenshot shows 'Add photos' fully visible in a wide full-width row; the Label uses system font so it scales and wraps, nothing is lost.",
                "If the element moves off palette text tokens or onto a new surface."),
        // F. Second run (2026-11-19 rerun): new non-contrast findings of the same classes.
        triaged(.settings, .dynamicType, .labelAndType(label: "Check iCloud account", type: .staticText),
                "Button Label in the default body style (SettingsView.swift:235); scales with Dynamic Type and wraps, seen in full in the rerun screenshots.",
                "If the element's font changes."),
        triaged(.settings, .dynamicType, .labelAndType(label: "Sync now", type: .staticText),
                "Button Label in the default body style (SettingsView.swift:199); scales with Dynamic Type and wraps.",
                "If the element's font changes."),
        triaged(.seeds, .elementDetection, .unresolved,
                "Rerun light-default scrolled screenshot: the only undetected text is list rows blurred behind the Liquid Glass toolbar and search field.",
                "If a later audit names an element for this screen and type."),
        triaged(.today, .elementDetection, .unresolved,
                "Rerun dark-default page.1 screenshot: the only undetected text is the banner blurred behind the status bar at the scroll edge.",
                "If a later audit names an element for this screen and type."),
    ]

    /// The index of the first entry matching an issue, or nil. An issue without an element matches only
    /// an `.unresolved` entry.
    static func match(
        destination: AuditDestination,
        checkpoint: String,
        auditType: XCUIAccessibilityAuditType,
        identifier: String?,
        label: String?,
        elementType: XCUIElement.ElementType?,
        configuration: AuditConfiguration,
        in entries: [AuditAllowlistEntry] = entries
    ) -> Int? {
        let hasIdentifier = !(identifier ?? "").isEmpty
        return entries.firstIndex { entry in
            guard entry.destination == destination,
                  entry.checkpoint == nil || entry.checkpoint == checkpoint,
                  entry.auditType == auditType,
                  entry.configurations.contains(configuration) else { return false }
            switch entry.element {
            case .identifier(let expected):
                return elementType != nil && hasIdentifier && identifier == expected
            case .labelAndType(let expectedLabel, let expectedType):
                return elementType != nil && !hasIdentifier && label == expectedLabel && elementType == expectedType
            case .unresolved:
                return elementType == nil
            }
        }
    }
}
