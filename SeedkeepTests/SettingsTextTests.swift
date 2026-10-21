import Testing
@testable import Seedkeep

@Suite("SettingsText — version row")
struct SettingsTextTests {

    @Test("version and build both present")
    func bothPresent() {
        #expect(SettingsText.versionText(version: "0.4.0", build: 52) == "Version 0.4.0 (52)")
    }

    @Test("empty version shows the build alone")
    func buildOnly() {
        #expect(SettingsText.versionText(version: "", build: 52) == "Build 52")
    }

    @Test("zero build shows the version alone")
    func versionOnly() {
        #expect(SettingsText.versionText(version: "0.4.0", build: 0) == "Version 0.4.0")
    }

    @Test("both missing hides the row")
    func neitherPresent() {
        #expect(SettingsText.versionText(version: "", build: 0) == nil)
    }

    @Test("a blank version counts as missing")
    func blankVersion() {
        #expect(SettingsText.versionText(version: "  ", build: 52) == "Build 52")
        #expect(SettingsText.versionText(version: " \n", build: 0) == nil)
    }

    @Test("a negative build counts as missing")
    func negativeBuild() {
        #expect(SettingsText.versionText(version: "0.4.0", build: -1) == "Version 0.4.0")
    }
}
