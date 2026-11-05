// N2-E (G3) screenshots: the choice screen of a deleted garden, owner and participant wording, in the four
// R2d configurations (default and accessibility text size, light and dark). One launch per wording, over the
// sample garden with the DEBUG `-SeedkeepGardenGone owner|participant` argument (nothing is sent anywhere:
// CloudKit is off in sample-garden mode). Run it with scripts/gone-screenshots.sh. It is not the accessibility
// audit (scripts/a11y-audit.sh skips this class) and not the per-change gate. Nothing is tapped: the screen
// is only looked at, so neither choice runs.
import XCTest

@MainActor
final class GardenGoneScreenshotTests: XCTestCase {
    func testLightDefault() throws { try walk(.lightDefault) }
    func testDarkDefault() throws { try walk(.darkDefault) }
    func testLightAccessibilityXXXL() throws { try walk(.lightAXXXL) }
    func testDarkAccessibilityXXXL() throws { try walk(.darkAXXXL) }

    private static let wordings = ["owner", "participant"]

    private func walk(_ configuration: AuditConfiguration) throws {
        continueAfterFailure = true
        executionTimeAllowance = 300
        for (index, wording) in Self.wordings.enumerated() {
            let app = XCUIApplication()
            app.launchArguments = configuration.launchArguments + ["-SeedkeepGardenGone", wording]
            let driver = AuditDriver(app: app, configuration: configuration)
            app.launch()
            let name = "\(configuration.rawValue)-0\(index + 1)-\(wording)"
            var reached = true
            XCTContext.runActivity(named: name) { _ in
                do {
                    try driver.require(driver.element("screen.gardenGone"), "screen.gardenGone",
                                       timeout: AuditDriver.readinessTimeout)
                    try driver.require(driver.element("gardenGone.keep"), "gardenGone.keep")
                    try driver.require(driver.element("gardenGone.discard"), "gardenGone.discard")
                    // The counts load a moment after the screen shows.
                    try driver.require(driver.element("gardenGone.inventory"), "gardenGone.inventory")
                } catch {
                    reached = false
                    XCTFail("[\(configuration.rawValue)] \(wording): \(error)")
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = reached ? name : "\(name)-unreached"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }
}
