// R3 Garden screenshots: one launch per configuration (the sample garden only), walking the Garden screens
// by accessibility identifier and attaching a screenshot at each step. Run it with scripts/r3-screenshots.sh.
// It is not the accessibility audit (scripts/a11y-audit.sh skips this class) and not the per-change gate.
// Only navigation is asserted: a step that can't reach its screen records an issue, and the walk goes on.
import XCTest

@MainActor
final class R3ScreenshotTests: XCTestCase {
    func testLightDefault() throws { try walk(.lightDefault) }
    func testDarkDefault() throws { try walk(.darkDefault) }
    func testLightAccessibilityXXXL() throws { try walk(.lightAXXXL) }
    func testDarkAccessibilityXXXL() throws { try walk(.darkAXXXL) }

    private var driver: AuditDriver!
    private var configuration: AuditConfiguration!
    /// Whether the running step has attached its screenshot.
    private var captured = false

    // MARK: - Walk

    private func walk(_ configuration: AuditConfiguration) throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
        self.configuration = configuration
        let app = XCUIApplication()
        app.launchArguments = configuration.launchArguments
        let driver = AuditDriver(app: app, configuration: configuration)
        self.driver = driver
        app.launch()
        defer { app.terminate() }

        // Readiness, as in the audit: the fixture-only Seeds row proves the sample garden has loaded.
        do {
            try driver.selectTab(.seeds)
            try driver.require(driver.element("seeds.row.\(AuditFixture.readinessSeedID)"),
                               "fixture readiness row", timeout: AuditDriver.readinessTimeout)
        } catch let failure as AuditFailure {
            XCTFail("[\(configuration.rawValue)] readiness: \(failure.description)")
            return
        }

        step(1, "today") {
            try driver.selectTab(.today)
            try driver.requireScreen(.today)
            // The frost banner may or may not be on Today yet; the screenshot shows whatever is there.
            capture(1, "today")
        }

        step(2, "garden-beds") {
            try driver.selectTab(.garden)
            try driver.requireScreen(.garden)
            try driver.require(bedRow, "North bed row (\(bedRowID))")
            capture(2, "garden-beds")
        }

        step(3, "bed-top") {
            try driver.scrollUntilInView(bedRow, bedRowID, wholly: false)
            try driver.tap(bedRow, bedRowID)
            try driver.requireScreen(.bedDetail)
            settle(bedScreen)
            capture(3, "bed-top")
        }

        step(4, "painting") {
            try driver.requireScreen(.bedDetail)
            // The first brush in the "Paint with a seed" strip. Its identifier is garden.brush.<seed id>.
            let brush = driver.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "garden.brush.")).firstMatch
            try driver.tap(brush, "first brush in the Paint with a seed strip")
            let stop = driver.element("garden.modeBar.stop")
            try driver.require(stop, "Stop bar (garden.modeBar.stop)")
            capture(4, "painting")
            try driver.tap(stop, "Stop")
            guard stop.waitForNonExistence(timeout: AuditDriver.elementTimeout) else {
                throw AuditFailure(description: "the Stop bar is still showing after Stop")
            }
        }

        step(5, "square-details") {
            try driver.requireScreen(.bedDetail)
            try openSquareDetails()
            settle(squareDetailsSheet)
            capture(5, "square-details")
        }

        step(6, "move-banner") {
            guard squareDetailsSheet.exists else {
                throw AuditFailure(description: "the square details sheet is not open (step 5)")
            }
            let move = driver.element("garden.squareDetails.move")
            // The form is lazy: a row below the sheet's visible part may not exist until it is scrolled to.
            try revealInSheet(move)
            try driver.tap(move, "Move")
            // Move closes the sheet and starts move mode, whose banner carries Cancel.
            guard squareDetailsSheet.waitForNonExistence(timeout: AuditDriver.screenTimeout) else {
                throw AuditFailure(description: "the square details sheet did not close after Move")
            }
            let banner = driver.app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Tap an empty square to move")).firstMatch
            try driver.require(banner, "move banner text")
            let cancel = driver.element("garden.modeBar.stop")
            try driver.require(cancel, "move banner Cancel (garden.modeBar.stop)")
            capture(6, "move-banner")
            try driver.tap(cancel, "Cancel")
            guard cancel.waitForNonExistence(timeout: AuditDriver.elementTimeout) else {
                throw AuditFailure(description: "the move banner is still showing after Cancel")
            }
        }

        step(7, "bed-events") {
            try driver.requireScreen(.bedDetail)
            let row = driver.element(eventRowID)
            // The list is lazy: a row below the fold may not exist until it is scrolled to, so scroll first.
            _ = row.waitForExistence(timeout: 3)
            try driver.scrollUntilInView(row, eventRowID)
            capture(7, "bed-events")
        }

        step(8, "windows") {
            // The Windows button is on the Garden list, so leave the bed screen first.
            if bedScreen.exists { try driver.leave(.bedDetail) }
            try driver.requireScreen(.garden)
            try driver.tap(driver.element("garden.windows"), "Windows (garden.windows)")
            try driver.requireScreen(.windows)
            settle(driver.element(AuditDestination.windows.screenIdentifier))
            capture(8, "windows")
            try driver.leave(.windows)
        }
    }

    // MARK: - Steps

    /// Opens square details from the sample event's events-list row (selecting a row writes nothing), as the
    /// audit's square details checkpoint does.
    private func openSquareDetails() throws {
        let row = driver.element(eventRowID)
        _ = row.waitForExistence(timeout: 3)
        try driver.scrollUntilInView(row, eventRowID, wholly: false)
        try driver.tap(row, eventRowID)
        try driver.require(squareDetailsSheet, "garden.squareDetails", timeout: AuditDriver.screenTimeout)
    }

    /// Swipes the open details sheet up until the element is hittable. The sheet stays where it is; its form
    /// scrolls. (AuditDriver's drags run on the window, which would start below a medium-height sheet.)
    private func revealInSheet(_ element: XCUIElement) throws {
        for _ in 0..<AuditDriver.maxPages {
            if element.exists, element.isHittable { return }
            squareDetailsSheet.swipeUp()
        }
        throw AuditFailure(description: "could not scroll \(element.identifier) into view in the sheet")
    }

    /// Waits, without a fixed sleep, until an element's frame stops changing (a sheet or a push finishing its
    /// animation), so a screenshot isn't taken mid-transition. Bounded.
    private func settle(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<AuditDriver.maxPages {
            let next = element.frame
            if next == last { return }
            last = next
        }
    }

    // MARK: - Steps and screenshots

    /// One step, as its own activity. A step that can't reach its screen records an issue and still attaches
    /// what is on screen (suffixed "unreached"); the walk goes on to the next step.
    private func step(_ number: Int, _ name: String, _ body: () throws -> Void) {
        captured = false
        XCTContext.runActivity(named: "\(configuration.rawValue) \(number) \(name)") { _ in
            do {
                try body()
            } catch let failure as AuditFailure {
                XCTFail("[\(configuration.rawValue)] step \(number) \(name): \(failure.description)")
            } catch {
                XCTFail("[\(configuration.rawValue)] step \(number) \(name): \(error)")
            }
            if !captured { capture(number, name, suffix: "unreached") }
        }
    }

    /// Attaches the screen as `<config>-<nn>-<step>`, kept with the result bundle.
    private func capture(_ number: Int, _ name: String, suffix: String? = nil) {
        let index = number < 10 ? "0\(number)" : "\(number)"
        let base = "\(configuration.rawValue)-\(index)-\(name)"
        let attachment = XCTAttachment(screenshot: driver.app.screenshot())
        attachment.name = suffix.map { "\(base)-\($0)" } ?? base
        attachment.lifetime = .keepAlways
        add(attachment)
        captured = true
    }

    // MARK: - Elements

    private var bedRowID: String { "garden.bed.\(AuditFixture.northBedID)" }
    private var bedRow: XCUIElement { driver.element(bedRowID) }
    private var bedScreen: XCUIElement { driver.element(AuditDestination.bedDetail.screenIdentifier) }
    /// The sample event whose events-list row opens square details (the audit's square details checkpoint).
    private var eventRowID: String { "garden.events.select.\(AuditFixture.squareDetailsEventID)" }
    private var squareDetailsSheet: XCUIElement { driver.element("garden.squareDetails") }
}
