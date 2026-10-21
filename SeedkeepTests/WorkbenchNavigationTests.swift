import Testing
@testable import Seedkeep

@Suite("Workbench navigation per platform")
struct WorkbenchNavigationTests {
    @Test("the Mac leaves Settings out of the sidebar, and iPad keeps it, in route order")
    func sidebarRoutesPerPlatform() {
        #expect(WorkbenchNavigation.routes(isMac: true) == [.today, .seeds, .garden, .windows, .journal])
        #expect(WorkbenchNavigation.routes(isMac: false) == [.today, .seeds, .garden, .windows, .journal, .settings])
    }

    @Test("settings stays a route on every platform, so exhaustive switches still compile")
    func settingsRouteIsKept() {
        #expect(WorkbenchRoute.allCases.contains(.settings))
        #expect(WorkbenchRoute(rawValue: "settings") == .settings)
    }

    @Test("the Go menu's Settings item (⌘,) is off the Mac and kept on iPad")
    func goMenuSettingsItemPerPlatform() {
        #expect(!WorkbenchNavigation.goMenuShowsSettings(isMac: true))
        #expect(WorkbenchNavigation.goMenuShowsSettings(isMac: false))
    }

    @Test("the Go menu's numbered routes never include Settings, on any platform")
    func numberedRoutesExcludeSettings() {
        #expect(!WorkbenchGoShortcut.routes.contains(.settings))
        #expect(WorkbenchGoShortcut.routes.count == 5)
    }

    @Test("the palette's Go items follow the platform's routes")
    func paletteGoItemsFollowPlatform() {
        // "Go to" matches only the Go items, and every one of them fits the palette's nine-row cap.
        func goRoutes(isMac: Bool) -> [WorkbenchRoute] {
            CommandPaletteSearch.results(query: "Go to", rows: [], isMac: isMac).compactMap { item -> WorkbenchRoute? in
                if case .route(let route) = item.kind { return route }
                return nil
            }
        }

        #expect(Set(goRoutes(isMac: true)) == Set(WorkbenchRoute.allCases).subtracting([.settings]))
        #expect(Set(goRoutes(isMac: false)) == Set(WorkbenchRoute.allCases))
    }

    @Test("searching for Settings on the Mac finds no Settings route")
    func paletteSearchOmitsSettingsOnMac() {
        let macIDs = CommandPaletteSearch.results(query: "settings", rows: [], isMac: true).map(\.id)
        #expect(!macIDs.contains("route:settings"))

        let iPadIDs = CommandPaletteSearch.results(query: "settings", rows: [], isMac: false).map(\.id)
        #expect(iPadIDs.contains("route:settings"))
    }

    @Test("the running test host reports the platform it was built for")
    func platformFlagMatchesBuild() {
        #if os(macOS)
        #expect(WorkbenchNavigation.isMacPlatform)
        #else
        #expect(!WorkbenchNavigation.isMacPlatform)
        #endif
    }
}
