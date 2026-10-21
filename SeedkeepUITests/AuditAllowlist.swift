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
    }

    let destination: AuditDestination
    /// The recorded checkpoint name: `top`, `scrolled`, `page.<n>`, or an anchor's name.
    let checkpoint: String
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
    private static let canvasCap = Justification(
        reason: "Bed canvas text is capped at .xxxLarge by design (R2c decision); "
            + "names stay in VoiceOver and the events list.",
        recheck: "If the cap is removed.")

    /// Dynamic Type on static text in a text style: the style and where it is set, then the audit's limit.
    private static func textStyle(_ style: String, _ source: String) -> Justification {
        Justification(
            reason: "Uses \(style) at \(source): a text style, so it scales with Dynamic Type (code-checked, "
                + "not measured per element). Why the audit flags it is not established.",
            recheck: "If the element's font changes.")
    }

    private static func accepted(
        _ destination: AuditDestination,
        _ checkpoint: String,
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
        accepted(.seedDetail, "top", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),
        accepted(.addSeed, "scrolled", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault], systemTextField),
        accepted(.addSeed, "top", .textClipped,
                 .labelAndType(label: "", type: .textField),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], systemTextField),

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
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Description", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".caption", "BedDetailView.swift:68")),
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Dimensions", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "BedDetailView.swift:73")),
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Raised, full sun", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style", "BedDetailView.swift:69")),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Description", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".caption", "BedDetailView.swift:68")),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Dimensions", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "BedDetailView.swift:73")),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Raised, full sun", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style", "BedDetailView.swift:69")),
        accepted(.windows, "top", .dynamicType,
                 .labelAndType(label: "Snap a corner", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], textStyle(".wbCallout (semibold)", "WindowsView.swift:94")),
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
                 .labelAndType(label: "Share garden via iCloud", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:292")),
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
                 .labelAndType(label: "Share garden via iCloud", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:292")),
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
                 .labelAndType(label: "Share garden via iCloud", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:292")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:339")),
        accepted(.settings, "page.3", .dynamicType,
                 .labelAndType(label: "USDA ARS Plant Hardiness Zone Map (2023)", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:336")),
        accepted(.settings, "page.4", .dynamicType,
                 .labelAndType(label: "Check iCloud account", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:226")),
        accepted(.settings, "page.4", .dynamicType,
                 .labelAndType(label: "CloudKit sync hasn’t run yet — tap “Sync now”.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote", "SettingsView.swift:253")),
        accepted(.settings, "page.4", .dynamicType,
                 .labelAndType(label: "Frost dates estimated from the hardiness zone", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "SettingsView.swift:342")),
        accepted(.settings, "page.4", .dynamicType,
                 .labelAndType(label: "Share garden via iCloud", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "SettingsView.swift:292")),
        accepted(.settings, "page.4", .dynamicType,
                 .labelAndType(label: "U.S. Census Bureau", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbBody", "SettingsView.swift:339")),
        accepted(.settings, "page.4", .dynamicType,
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
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "NotificationsSettingsView.swift:84")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "8am after 5 dry days with no soaking rain in the 3-day forecast", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "NotificationsSettingsView.swift:73")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "All notifications are scheduled on-device. Seedkeep doesn't send anything through Apple's push servers.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote (form footer)", "NotificationsSettingsView.swift:108")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "Correction outcomes", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "NotificationsSettingsView.swift:94")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "Planting reminders", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "NotificationsSettingsView.swift:83")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "Watering reminders", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (Label)", "NotificationsSettingsView.swift:72")),
        accepted(.notifications, "top", .dynamicType,
                 .labelAndType(label: "When off, new corrections still appear in House → your contributions. Past notifications already on your lock screen aren't removed.", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbCaption", "NotificationsSettingsView.swift:95")),
        accepted(.apiKeys, "top", .dynamicType,
                 .labelAndType(label: "API key from console.anthropic.com (starts with sk-ant-).", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle(".wbFootnote (form footer)", "APIKeysSettingsView.swift:129")),
        accepted(.apiKeys, "top", .dynamicType,
                 .labelAndType(label: "Active", type: .staticText),
                 [.lightDefault, .darkDefault], textStyle("the default body style (LabeledContent)", "APIKeysSettingsView.swift:41 and :46")),

        // D (exception). Bed canvas planting labels, capped at .xxxLarge by design.
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Black Seeded Simpson", type: .staticText),
                 [.lightDefault, .darkDefault], canvasCap),
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Brandywine", type: .staticText),
                 [.lightDefault, .darkDefault], canvasCap),
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Danvers 126", type: .staticText),
                 [.lightDefault, .darkDefault], canvasCap),
        accepted(.bedDetail, "canvas", .dynamicType,
                 .labelAndType(label: "Sugar Snap", type: .staticText),
                 [.lightDefault, .darkDefault], canvasCap),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Black Seeded Simpson", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], canvasCap),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Brandywine", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], canvasCap),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Danvers 126", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], canvasCap),
        accepted(.bedDetail, "top", .dynamicType,
                 .labelAndType(label: "Sugar Snap", type: .staticText),
                 [.lightDefault, .darkDefault, .lightAXXXL, .darkAXXXL], canvasCap),
    ]

    /// The index of the first entry matching an issue, or nil. An issue without an element never matches.
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
        guard let elementType else { return nil }
        let hasIdentifier = !(identifier ?? "").isEmpty
        return entries.firstIndex { entry in
            guard entry.destination == destination,
                  entry.checkpoint == checkpoint,
                  entry.auditType == auditType,
                  entry.configurations.contains(configuration) else { return false }
            switch entry.element {
            case .identifier(let expected):
                return hasIdentifier && identifier == expected
            case .labelAndType(let expectedLabel, let expectedType):
                return !hasIdentifier && label == expectedLabel && elementType == expectedType
            }
        }
    }
}
