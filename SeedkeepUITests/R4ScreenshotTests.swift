// R4 screenshots: one launch per configuration (the sample garden only), walking the R4 screens by accessibility
// identifier and attaching a screenshot at each step: Today at the top, This week, the overflow row of due work,
// the Journal search alone, its filter chip alone, the search with the chip on, and the CSV import preview (which
// needs a second launch, with the DEBUG fixture argument). Run it with scripts/r4-screenshots.sh. It is not the
// accessibility audit
// (scripts/a11y-audit.sh skips this class) and not the per-change gate. Only navigation is asserted: a step that
// can't reach its screen records an issue, and the walk goes on. Nothing is written: the search and filter are
// cleared, and the import is cancelled, never imported.
import XCTest

@MainActor
final class R4ScreenshotTests: XCTestCase {
    func testLightDefault() throws { try walk(.lightDefault) }
    func testDarkDefault() throws { try walk(.darkDefault) }
    func testLightAccessibilityXXXL() throws { try walk(.lightAXXXL) }
    func testDarkAccessibilityXXXL() throws { try walk(.darkAXXXL) }

    /// The DEBUG launch argument that opens the CSV import preview once per launch, when Seeds first appears
    /// (`Seedkeep/Features/Workbench/SeedCSVImportFixture.swift`). The test target can't see that file.
    private static let csvFixtureArgument = "-SeedkeepCSVImportFixture"
    /// A word of the sample garden's "Tomatoes went in after a week of hardening off..." entry. No other entry has it.
    private static let searchText = "Tomatoes"
    /// A bed with three entries, one of them the entry the search finds. So the search narrows the filtered feed.
    private static let filterLabel = "North bed"

    private var driver: AuditDriver!
    private var configuration: AuditConfiguration!
    /// Whether the running step has attached its screenshot.
    private var captured = false

    // MARK: - Walk

    private func walk(_ configuration: AuditConfiguration) throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
        self.configuration = configuration
        launch(configuration.launchArguments)
        defer { driver.app.terminate() }

        // Readiness, as in the R3 walk: the fixture-only Seeds row proves the sample garden has loaded.
        do {
            try awaitReadiness()
        } catch let failure as AuditFailure {
            XCTFail("[\(configuration.rawValue)] readiness: \(failure.description)")
            return
        }

        step(1, "today") {
            try driver.selectTab(.today)
            try driver.requireScreen(.today)
            capture(1, "today")
        }

        step(2, "today-week") {
            try driver.requireScreen(.today)
            // Scrolls down from the top until the summary is wholly on screen. An absent summary is an issue.
            try driver.scrollUntilInView(weekSummary, "today.week.summary")
            capture(2, "today-week")
        }

        step(3, "today-more-due") {
            // Carries on from the summary: the overflow row sits below the due rows, further down the screen.
            try driver.scrollUntilInView(moreDueRow, "today.moreDue")
            capture(3, "today-more-due")
        }

        step(4, "journal-search") {
            try driver.selectTab(.journal)
            try driver.requireScreen(.journal)
            try typeSearch()
            capture(4, "journal-search")
            try endSearch()
            try driver.require(feedSubtitle(suffix: "the household garden"),
                               "the unfiltered Journal subtitle", timeout: AuditDriver.elementTimeout)
        }

        // The filter menu sits in the toolbar, which is hidden while a search is active on iPhone. So the filter
        // is chosen with the search ended, and the search comes back afterwards with the chip still on.
        step(5, "journal-filter") {
            try driver.requireScreen(.journal)
            try driver.tap(driver.element("journal.filter.menu"), "Filter journal (journal.filter.menu)")
            // Beds are in their own submenu.
            let beds = driver.app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Beds")).firstMatch
            try driver.tap(beds, "Beds in the filter menu")
            let item = driver.app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", Self.filterLabel)).firstMatch
            try driver.tap(item, "\(Self.filterLabel) in the filter menu")
            try driver.require(filterChip, "filter chip (journal.filter.chip)")
            settle(filterChip)
            capture(5, "journal-filter")
        }

        step(6, "journal-search-filter") {
            try driver.requireScreen(.journal)
            try driver.require(filterChip, "filter chip (journal.filter.chip)")
            try typeSearch()
            capture(6, "journal-search-filter")
            // Ends the search, then removes the filter, so the Journal is back to the whole feed.
            try endSearch()
            try driver.tap(driver.element("journal.filter.remove"), "filter chip remove (journal.filter.remove)")
            guard filterChip.waitForNonExistence(timeout: AuditDriver.elementTimeout) else {
                throw AuditFailure(description: "the filter chip is still showing after remove")
            }
        }

        step(7, "csv-preview") {
            // The fixture opens the preview when Seeds first appears, once per launch. So this step relaunches
            // with its argument, and only then opens Seeds.
            driver.app.terminate()
            launch(configuration.launchArguments + [Self.csvFixtureArgument])
            try driver.selectTab(.seeds)
            try driver.require(csvSheet, "csvImport.sheet", timeout: AuditDriver.screenTimeout)
            try driver.require(csvPreview, "csvImport.preview", timeout: AuditDriver.screenTimeout)
            settle(csvSheet)
            capture(7, "csv-preview")
            // Cancel only. Import would write to the sample store, and these screenshots are read-only.
            try driver.tap(driver.element("csvImport.cancel"), "Cancel (csvImport.cancel)")
            guard csvSheet.waitForNonExistence(timeout: AuditDriver.screenTimeout) else {
                throw AuditFailure(description: "the CSV import sheet is still showing after Cancel")
            }
        }
    }

    // MARK: - Launch and readiness

    /// Launches the app with these arguments and makes its driver the current one.
    private func launch(_ arguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = arguments
        driver = AuditDriver(app: app, configuration: configuration)
        app.launch()
    }

    private func awaitReadiness() throws {
        try driver.selectTab(.seeds)
        try driver.require(driver.element("seeds.row.\(AuditFixture.readinessSeedID)"),
                           "fixture readiness row", timeout: AuditDriver.readinessTimeout)
    }

    // MARK: - Journal search

    /// Types the search into the Journal's search field, then waits for the result count the debounced search
    /// applies ("1 of N entries"). The filter alone shows a different count, so this is a real signal.
    private func typeSearch() throws {
        let field = searchField
        try driver.require(field, "Journal search field")
        field.tap()
        field.typeText(Self.searchText)
        try driver.require(feedSubtitle(prefix: "1 of "), "the Journal result count (1 of N entries)",
                           timeout: AuditDriver.elementTimeout)
    }

    /// Ends the Journal search and clears its text. The search bar's Cancel (iOS 26: a "Close" button beside the
    /// field) does both, and it brings the toolbar back. Without one, the text is cleared with the field's clear
    /// button, or by deleting the typed text. Waits for the button to go, so the search is over before the next
    /// step.
    private func endSearch() throws {
        let cancel = driver.app.navigationBars.buttons
            .matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        if cancel.exists {
            try driver.tap(cancel, "Cancel or Close (Journal search)")
            guard cancel.waitForNonExistence(timeout: AuditDriver.elementTimeout) else {
                throw AuditFailure(description: "the Journal search is still active after Cancel or Close")
            }
        } else {
            let field = searchField
            try driver.require(field, "Journal search field")
            let clear = field.buttons["Clear text"]
            if clear.exists {
                try driver.tap(clear, "Clear text (Journal search)")
            } else {
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.searchText.count))
            }
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

    private var weekSummary: XCUIElement { driver.element("today.week.summary") }
    private var moreDueRow: XCUIElement { driver.element("today.moreDue") }
    private var searchField: XCUIElement { driver.app.searchFields.firstMatch }
    private var filterChip: XCUIElement { driver.element("journal.filter.chip") }
    /// The Journal's result subtitle (`JournalFeedPresentation.subtitle`): "1 of 6 entries" while the search or
    /// filter applies, and "6 entries · the household garden" when it doesn't.
    private func feedSubtitle(prefix: String) -> XCUIElement {
        driver.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
    private func feedSubtitle(suffix: String) -> XCUIElement {
        driver.app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", suffix)).firstMatch
    }
    private var csvSheet: XCUIElement { driver.element("csvImport.sheet") }
    private var csvPreview: XCUIElement { driver.element("csvImport.preview") }
}
