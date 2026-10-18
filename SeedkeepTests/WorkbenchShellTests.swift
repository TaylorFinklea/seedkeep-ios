import Testing
import SwiftUI
@testable import Seedkeep

@Suite("Workbench shell policy")
struct WorkbenchShellTests {
    @Test("macOS uses the Workbench shell")
    func macOSUsesShell() {
        #expect(WorkbenchShellPolicy.shouldShowWorkbench(isMac: true, idiom: .other, horizontalSizeClass: nil))
    }

    @Test("iPad regular width uses the Workbench shell")
    func iPadRegularWidthUsesShell() {
        #expect(WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .tablet, horizontalSizeClass: .regular))
    }

    @Test("iPhone regular and compact widths keep tabs")
    func iPhoneKeepsTabsAtAllWidths() {
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .phone, horizontalSizeClass: .regular))
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .phone, horizontalSizeClass: .compact))
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .phone, horizontalSizeClass: nil))
    }

    @Test("iPad compact width uses tabs")
    func iPadCompactWidthUsesTabs() {
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .tablet, horizontalSizeClass: .compact))
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(isMac: false, idiom: .tablet, horizontalSizeClass: nil))
    }

    @Test("signed-out state has neither shell nor enabled commands")
    @MainActor
    func signedOutHasNoShellOrCommands() {
        #expect(!WorkbenchShellPolicy.shouldShowWorkbench(
            isSignedIn: false, isMac: true, idiom: .other, horizontalSizeClass: .regular
        ))
        #expect(!WorkbenchCommandAvailability.hasModel(nil))
        WorkbenchCommandAction.newSeed.perform(on: nil)
        #expect(!WorkbenchCommandAvailability.hasModel(nil))
    }

    @Test("routes retain their titles and symbols")
    func routesHaveStableTitlesAndSymbols() {
        #expect(WorkbenchRoute.allCases.map(\.title) == ["Today", "Seeds", "Garden", "Journal", "Settings"])
        #expect(WorkbenchRoute.allCases.map(\.symbol) == ["sun.max", "leaf", "square.grid.3x3", "book", "gearshape"])
    }
}
