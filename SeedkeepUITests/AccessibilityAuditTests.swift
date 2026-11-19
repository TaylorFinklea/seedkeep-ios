// The R2d automated accessibility audit: one launch per iPhone configuration, walking AuditManifest and
// running `performAccessibilityAudit` at every checkpoint. Run it with scripts/a11y-audit.sh, never in
// the per-change gate. Log lines start with "[a11y-audit]" so the script can summarise them.
import XCTest

@MainActor
final class AccessibilityAuditTests: XCTestCase {
    /// The Today title's height splits the default size from Accessibility XXXL. Measured on the
    /// "Seedkeep iPhone" simulator (2026-10-21): 40.7 pt at the default size, 71.7 pt at XXXL.
    static let titleHeightThreshold: CGFloat = 56
    /// The median screen luminance must be clearly dark or clearly light.
    static let darkMaxLuminance = 0.35
    static let lightMinLuminance = 0.65

    func testLightDefault() throws { try runAudit(.lightDefault) }
    func testDarkDefault() throws { try runAudit(.darkDefault) }
    func testLightAccessibilityXXXL() throws { try runAudit(.lightAXXXL) }
    func testDarkAccessibilityXXXL() throws { try runAudit(.darkAXXXL) }

    // MARK: - One configuration

    private var driver: AuditDriver!
    private var configuration: AuditConfiguration!
    private var auditCount = 0
    private var findingCount = 0
    private var suppressedCount = 0
    private var usedAllowlistEntries: Set<Int> = []

    private func runAudit(_ configuration: AuditConfiguration) throws {
        continueAfterFailure = true
        executionTimeAllowance = 900
        self.configuration = configuration
        let app = XCUIApplication()
        app.launchArguments = configuration.launchArguments
        let driver = AuditDriver(app: app, configuration: configuration)
        self.driver = driver

        driver.log("START date=\(ISO8601DateFormatter().string(from: Date())) timeZone=\(TimeZone.current.identifier)")
        app.launch()
        defer {
            reportUnusedAllowlistEntries()
            driver.log("SUMMARY audits=\(auditCount) findings=\(findingCount) suppressed=\(suppressedCount) tabsByIdentifier=\(driver.tabsByIdentifier) tabsByLabel=\(driver.tabsByLabel)")
            app.terminate()
        }

        do {
            try assertReadiness()
            try assertEffectiveConfiguration()
            try walkManifest()
        } catch let failure as AuditFailure {
            driver.log("ABORT \(failure.description)")
            XCTFail("[\(configuration.rawValue)] \(failure.description)")
        }
    }

    /// Readiness: the fixture-only Seeds row. Its id exists only in the sample garden, so finding it proves
    /// both the fixture and that the data has loaded.
    private func assertReadiness() throws {
        try driver.selectTab(.seeds)
        try driver.requireScreen(.seeds)
        try driver.require(
            driver.element("seeds.row.\(AuditFixture.readinessSeedID)"),
            "fixture readiness row seeds.row.\(AuditFixture.readinessSeedID)",
            timeout: AuditDriver.readinessTimeout)
    }

    /// Fails the configuration when the app ignored its appearance or text size.
    private func assertEffectiveConfiguration() throws {
        let luminance = try driver.medianLuminance()
        let appearanceOK = switch configuration.appearance {
        case .dark: luminance <= Self.darkMaxLuminance
        case .light: luminance >= Self.lightMinLuminance
        }

        try driver.selectTab(.today)
        try driver.requireScreen(.today)
        let titleHeight = try driver.todayTitleHeight()
        let sizeOK = configuration.isAccessibilitySize
            ? titleHeight > Self.titleHeightThreshold
            : titleHeight < Self.titleHeightThreshold

        driver.log(String(format: "CONFIG luminance=%.3f titleHeight=%.1f threshold=%.1f appearanceOK=%@ sizeOK=%@",
                          luminance, titleHeight, Self.titleHeightThreshold,
                          String(appearanceOK), String(sizeOK)))
        guard appearanceOK else {
            throw AuditFailure(description: "appearance \(configuration.appearance.rawValue) ignored (median luminance \(luminance))")
        }
        guard sizeOK else {
            throw AuditFailure(description: "text size \(configuration.contentSizeCategory) ignored (Today title \(titleHeight) pt)")
        }
    }

    // MARK: - The walk

    private func walkManifest() throws {
        for stop in AuditManifest.stops {
            let destination = stop.destination
            do {
                try enter(destination)
                try driver.requireScreen(destination)
                for plan in stop.checkpoints {
                    try run(plan, on: destination)
                }
                if !destination.isTabRoot {
                    try driver.leave(destination)
                }
            } catch let failure as AuditFailure {
                // One destination failing doesn't hide the rest: record it, get back to a tab root, go on.
                driver.log("ABORT-DESTINATION dest=\(destination.rawValue) \(failure.description)")
                XCTFail("[\(configuration.rawValue)] \(destination.rawValue): \(failure.description)")
                try recover(from: destination)
            }
        }
    }

    private func enter(_ destination: AuditDestination) throws {
        if destination.isTabRoot {
            try driver.selectTab(destination.tab)
            return
        }
        try driver.requireScreen(AuditDestination(rawValue: destination.tab.rawValue)!)
        let identifier: String = switch destination {
        case .seedDetail: "seeds.row.\(AuditFixture.detailSeedID)"
        case .addSeed: "seeds.add"
        case .randomPick: "seeds.random"
        case .bedDetail: "garden.bed.\(AuditFixture.northBedID)"
        case .windows: "garden.windows"
        case .journalEntry: "journal.entry.\(AuditFixture.journalEntryID)"
        case .locations, .tags, .homeLocation, .notifications, .aiProvider, .apiKeys, .whatsNew:
            "settings.\(destination.rawValue)"
        case .today, .seeds, .garden, .journal, .settings:
            preconditionFailure("tab roots are entered by tab")
        }
        let target = driver.element(identifier)
        // A row below the fold isn't in the tree until scrolled to, so a miss here isn't a failure yet.
        _ = target.waitForExistence(timeout: 3)
        if destination == .journalEntry || destination == .apiKeys {
            try positionAuditRowForTap(target, identifier)
        } else {
            try driver.scrollUntilInView(target, identifier, wholly: false)
        }
        try driver.tap(target, identifier)
    }

    /// Leave a real tap area above the tab bar and below the navigation/search chrome. A row can report
    /// hittable with only a sliver showing, and a full-page drag may overshoot it beneath a pinned header.
    private func positionAuditRowForTap(_ target: XCUIElement, _ identifier: String) throws {
        func usableFrame() -> CGRect? {
            guard target.exists else { return nil }
            let frame = target.frame
            guard !frame.isNull, !frame.isInfinite, !frame.isEmpty,
                  frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite else { return nil }
            return frame
        }
        var discoveries = 0
        for _ in 0..<AuditDriver.maxPages {
            let candidateFrame = usableFrame()
            let window = driver.app.windows.firstMatch.frame
            let nav = driver.app.navigationBars.firstMatch
            let tab = driver.app.tabBars.firstMatch
            let top = max(window.minY, nav.exists ? nav.frame.maxY : window.minY) + 8
            let bottom = min(window.maxY, tab.exists ? tab.frame.minY : window.maxY) - 8
            guard bottom - top >= 100 else { throw AuditFailure(description: "no usable viewport for \(identifier)") }
            guard let frame = candidateFrame else {
                // Keep the bounded down/up lazy-cell search, but start its drags below pinned chrome.
                // A recycled cell gets one additional discovery attempt, not an unbounded retry.
                guard discoveries < 2 else { throw AuditFailure(description: "\(identifier) has no usable frame") }
                discoveries += 1
                try driver.scrollUntilInView(target, identifier, wholly: false, contentTop: top)
                continue
            }
            let viewport = CGRect(x: window.minX, y: top, width: window.width, height: bottom - top)
            let visible = viewport.intersection(frame)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if viewport.contains(center), !visible.isNull, visible.width >= min(frame.width, 44),
               visible.height >= min(frame.height, 44), target.isHittable {
                driver.log("TAP-AREA target=\(identifier) frame=\(frame) top=\(top) bottom=\(bottom) visible=\(visible)")
                return
            }
            let direction: AuditDriver.Direction = frame.midY < viewport.midY ? .up : .down
            driver.resetScrollTracking()
            if try !driver.scrollPage(direction, contentTop: top) {
                // At an edge, try the other direction once before reporting failure.
                let opposite: AuditDriver.Direction = direction == .down ? .up : .down
                driver.resetScrollTracking()
                guard try driver.scrollPage(opposite, contentTop: top) else {
                    throw AuditFailure(description: "could not position \(identifier) in the usable viewport")
                }
            }
        }
        throw AuditFailure(description: "could not position \(identifier) within \(AuditDriver.maxPages) attempts")
    }

    private func run(_ plan: AuditCheckpointPlan, on destination: AuditDestination) throws {
        switch plan {
        case .top:
            try audit(destination, checkpoint: "top")
        case .scrolledOnce:
            driver.resetScrollTracking()
            if try !driver.scrollPage(.down) {
                driver.log("NOTE dest=\(destination.rawValue) did not scroll; auditing in place")
            }
            try audit(destination, checkpoint: "scrolled")
        case .pagesToEnd:
            var page = 0
            driver.resetScrollTracking()
            while try driver.scrollPage(.down) {
                page += 1
                try audit(destination, checkpoint: "page.\(page)")
                if page == AuditDriver.maxPages {
                    throw AuditFailure(description: "\(destination.rawValue) did not end within \(page) pages")
                }
            }
            if destination == .settings {
                // The sub-screens open from rows above; start them from the top.
                try driver.scrollToTop()
            }
        case .anchor(let anchor):
            try scroll(to: anchor)
            try audit(destination, checkpoint: anchor.rawValue)
        case .squareDetails:
            try openSquareDetails()
            try audit(destination, checkpoint: "squareDetails", screen: "garden.squareDetails")
            try closeSquareDetails(from: destination)
        }
    }

    private func scroll(to anchor: AuditAnchor) throws {
        switch anchor {
        case .plantingPanel:
            let header = driver.app.staticTexts.matching(
                NSPredicate(format: "label ==[c] %@", "Planting window")).firstMatch
            try driver.scrollUntilInView(header, "Planting window header")
            // Bring the panel under the header into view too, until the content ends.
            for _ in 0..<AuditDriver.maxPages {
                let windowHeight = driver.app.windows.firstMatch.frame.height
                guard driver.isInView(header), header.frame.minY > windowHeight * 0.45 else { break }
                if try !driver.scrollPage(.down) { break }
            }
        case .grid:
            let cell = driver.element("garden.grid.r1.s1")
            try driver.require(cell, "grid square garden.grid.r1.s1")
            try driver.scrollUntilInView(cell, "grid square garden.grid.r1.s1")
        }
    }

    /// Opens square details from a planting's events-list row (selecting a row writes nothing).
    private func openSquareDetails() throws {
        let identifier = "garden.events.select.\(AuditFixture.squareDetailsEventID)"
        let row = driver.element(identifier)
        _ = row.waitForExistence(timeout: 3)
        try driver.scrollUntilInView(row, identifier, wholly: false)
        try driver.tap(row, identifier)
        try driver.require(driver.element("garden.squareDetails"), "garden.squareDetails",
                           timeout: AuditDriver.screenTimeout)
    }

    /// Closes square details with Done and checks the bed screen is back.
    private func closeSquareDetails(from destination: AuditDestination) throws {
        let done = driver.element("garden.squareDetails.done")
        try driver.require(done, "garden.squareDetails.done")
        try driver.tap(done, "garden.squareDetails.done")
        guard driver.element("garden.squareDetails").waitForNonExistence(timeout: AuditDriver.screenTimeout) else {
            throw AuditFailure(description: "garden.squareDetails still present after Done")
        }
        try driver.requireScreen(destination)
    }

    /// After a failed destination: dismiss whatever is open and return to its tab root.
    private func recover(from destination: AuditDestination) throws {
        if !destination.isTabRoot && driver.element(destination.screenIdentifier).exists {
            // The failed entry may never have opened its child; do not tap a root toolbar button as Back.
            try? driver.leave(destination)
            if driver.element(destination.screenIdentifier).exists {
                // A sheet whose own button failed: swipe it away.
                try? driver.swipeDownSheet(destination)
            }
        }
        try driver.selectTab(destination.tab)
    }

    // MARK: - Auditing

    private func audit(_ destination: AuditDestination, checkpoint: String, screen: String? = nil) throws {
        // Contract: each audit runs after checking `screen.<name>` (or the sheet's own screen).
        if let screen {
            try driver.require(driver.element(screen), screen)
        } else {
            try driver.requireScreen(destination)
        }
        auditCount += 1
        let before = findingCount
        do {
            try driver.app.performAccessibilityAudit(for: .all) { [self] issue in
                handle(issue, destination: destination, checkpoint: checkpoint)
            }
        } catch {
            driver.log("AUDIT-ERROR dest=\(destination.rawValue) checkpoint=\(checkpoint) error=\(error)")
            XCTFail("[\(configuration.rawValue)] audit of \(destination.rawValue)/\(checkpoint) failed to run: \(error)")
        }
        driver.log("AUDITED dest=\(destination.rawValue) checkpoint=\(checkpoint) findings=\(findingCount - before)")
    }

    /// Returns true to suppress the issue (allowlisted), false to let it fail the test.
    private func handle(_ issue: XCUIAccessibilityAuditIssue, destination: AuditDestination, checkpoint: String) -> Bool {
        let type = Self.name(of: issue.auditType)
        var identifier: String?
        var label: String?
        var elementType: XCUIElement.ElementType?
        if let element = issue.element, element.exists {
            identifier = element.identifier
            label = element.label
            elementType = element.elementType
        }
        let where_ = "dest=\(destination.rawValue) checkpoint=\(checkpoint) type=\(type)"
        let what = "id=\"\(identifier ?? "")\" label=\"\(label ?? "")\" elementType=\(elementType.map { String($0.rawValue) } ?? "none")"

        if let index = AuditAllowlist.match(
            destination: destination, checkpoint: checkpoint, auditType: issue.auditType,
            identifier: identifier, label: label, elementType: elementType, configuration: configuration) {
            let entry = AuditAllowlist.entries[index]
            usedAllowlistEntries.insert(index)
            suppressedCount += 1
            driver.log("SUPPRESSED \(where_) \(what) disposition=\"\(entry.disposition)\" reason=\"\(entry.reason)\" recheck=\"\(entry.recheckWhen)\"")
            return true
        }
        findingCount += 1
        let missing = elementType == nil ? " element=nil" : ""
        driver.log("FINDING \(where_) \(what)\(missing) desc=\"\(issue.compactDescription)\" detail=\"\(issue.detailedDescription)\"")
        return false
    }

    private func reportUnusedAllowlistEntries() {
        for (index, entry) in AuditAllowlist.entries.enumerated()
        where entry.configurations.contains(configuration) && !usedAllowlistEntries.contains(index) {
            driver.log("UNUSED-ALLOWLIST index=\(index) dest=\(entry.destination.rawValue) checkpoint=\(entry.checkpoint) type=\(Self.name(of: entry.auditType)) element=\(entry.element)")
        }
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"),
            (.textClipped, "textClipped"), (.trait, "trait"),
        ]
        let names = known.filter { type.contains($0.0) }.map(\.1)
        return names.isEmpty ? "raw\(type.rawValue)" : names.joined(separator: "+")
    }
}
