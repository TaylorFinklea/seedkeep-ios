import Foundation
import SwiftUI
import Testing
@testable import Seedkeep

@Suite("AppAppearance")
struct AppAppearanceTests {

    @Test("raw values, storage key and picker titles")
    func rawValuesAndTitles() {
        #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppAppearance.storageKey == "seedkeep.appearance")
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
    }

    @Test("an unset or unknown stored value means system")
    func unsetOrUnknownMeansSystem() {
        #expect(AppAppearance.resolve(nil) == .system)
        #expect(AppAppearance.resolve("") == .system)
        #expect(AppAppearance.resolve("sepia") == .system)
        // Raw values are case-sensitive.
        #expect(AppAppearance.resolve("Dark") == .system)
    }

    @Test("a stored raw value resolves to its appearance")
    func storedRawValuesResolve() {
        #expect(AppAppearance.resolve("system") == .system)
        #expect(AppAppearance.resolve("light") == .light)
        #expect(AppAppearance.resolve("dark") == .dark)
    }

    @Test("colorScheme follows the device for system and forces light or dark")
    func colorSchemeMapping() {
        #expect(AppAppearance.system.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test("under XCTest the store is standard defaults, not a sample garden")
    func liveStoreIsStandard() {
        #expect(!DevicePreferences.isSampleGarden)
        let key = "seedkeep.test.appearance.live"
        let store = DevicePreferences.store
        defer { store.removeObject(forKey: key) }
        store.set("written", forKey: key)
        #expect(UserDefaults.standard.string(forKey: key) == "written")
    }

    #if DEBUG
    @Test("a sample-garden store is the fixture suite and never standard defaults")
    func sampleGardenStoreIsTheFixtureSuite() {
        let key = "seedkeep.test.appearance.fixture"
        let store = DevicePreferences.store(isFixture: true)
        defer { store.removeObject(forKey: key) }
        store.set("written", forKey: key)
        #expect(store.string(forKey: key) == "written")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }
    #endif
}
