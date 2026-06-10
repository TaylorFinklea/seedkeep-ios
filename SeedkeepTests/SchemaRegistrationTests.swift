import Testing
import Foundation
import ObjectiveC.runtime
import SwiftData
@testable import Seedkeep

/// Guardrail for the `SeedkeepSchema.all` shared model list.
///
/// Background: `LocalForecastSnapshot` was registered in every TEST
/// schema but missing from the hand-typed production `Schema` in
/// `AppEnvironment.makeModelContainer`, so all weather-warning
/// persistence (dedup dates, TZ/clock-skew baselines, forecast cache)
/// silently failed on device while the suite stayed green. Production
/// and tests now build from the single `SeedkeepSchema.all` constant;
/// this suite walks the app binary's class list at runtime so a future
/// `@Model` that never gets added to the constant fails CI instead of
/// shipping unregistered.
@Suite("SeedkeepSchema — model registration guardrail")
struct SchemaRegistrationTests {

    /// Every class compiled into the app image that conforms to
    /// `PersistentModel` must produce an entity that
    /// `Schema(SeedkeepSchema.all)` knows.
    ///
    /// Mechanics: `objc_copyClassNamesForImage` lists class NAMES for the
    /// app binary only (never materializing class objects for the whole
    /// process — a global `objc_copyClassList` walk crashes on exotic
    /// runtime classes). Candidates are resolved by name and cast to
    /// `PersistentModel.Type`.
    @Test("every @Model class in the app target is registered in SeedkeepSchema.all")
    func allAppModelsAreRegistered() {
        // Locate the app executable's image via a known model class.
        guard let appImage = class_getImageName(LocalSeed.self) else {
            Issue.record("could not resolve the app image name")
            return
        }

        var nameCount: UInt32 = 0
        guard let classNames = objc_copyClassNamesForImage(appImage, &nameCount) else {
            Issue.record("objc_copyClassNamesForImage returned nil")
            return
        }
        defer { free(UnsafeMutableRawPointer(mutating: classNames)) }

        var discovered: [any PersistentModel.Type] = []
        for index in 0..<Int(nameCount) {
            let name = String(cString: classNames[index])
            // Name gate before resolving: the Swift dynamic-cast machinery
            // messages the class object, and runtime-generated/proxy
            // classes can crash on that. Every model follows the house
            // `Local*` naming convention; a new @Model must keep it for
            // this guardrail to see it.
            guard name.contains("Local") else { continue }
            guard let cls = NSClassFromString(name) else { continue }
            guard let modelType = cls as? any PersistentModel.Type else { continue }
            discovered.append(modelType)
        }

        // The app currently ships 20 @Model types; a collapse of the
        // discovery mechanism (returning 0/1 classes) must not
        // vacuously pass.
        #expect(
            discovered.count >= 20,
            "model discovery found only \(discovered.count) PersistentModel classes — reflection broke?"
        )

        let registeredNames = Set(Schema(SeedkeepSchema.all).entities.map(\.name))
        let discoveredEntities = Schema(discovered).entities
        for entity in discoveredEntities {
            #expect(
                registeredNames.contains(entity.name),
                "@Model \(entity.name) exists in the app target but is missing from SeedkeepSchema.all — production persistence for it will silently fail"
            )
        }
    }

    /// Regression pin for the original incident: the production schema
    /// must include `LocalForecastSnapshot` explicitly.
    @Test("LocalForecastSnapshot is registered in the shared schema")
    func forecastSnapshotRegistered() {
        let names = Set(Schema(SeedkeepSchema.all).entities.map(\.name))
        #expect(names.contains("LocalForecastSnapshot"))
    }
}
