# Smart Planting Window — iOS Implementation Plan (Phase B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the iOS client side of the smart-planting-window feature — a home-ZIP location screen, server-driven planting recommendations with WeatherKit refinement, and four UI surfaces — replacing the existing local `SowRecommendation` engine.

**Architecture:** `SeedkeepKit` gains `Recommendation` DTOs + client methods against the Phase A server API. A `RecommendationStore` (`@MainActor @Observable`, owned by `AppEnvironment`) fetches server baselines, caches them in a new `LocalRecommendation` SwiftData model, and applies a client-side `WeatherKitRefiner`. A reusable `RecommendationPanel` view renders the layered result; it mounts on the seed detail page and the planting-event view. A verdict dot appears on Library rows; a new "What to plant" view lists the household's seeds by urgency. The existing `SowRecommendation` + `HardinessZoneFrostData` + manual frost-date entry are deleted — the server is now the source of truth, fed by a home ZIP.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, WeatherKit, Swift Testing. XcodeGen (`project.yml`).

**Spec:** `~/git/seedkeep/.docs/ai/specs/2026-05-20-smart-planting-window-design.md` (this plan is Phase B; Phase A — the server — is already built and merged).

**Prerequisite:** Phase A deployed to `https://seedkeep-server.fly.dev` (the `recommendations` routes + `PUT /households/me/location` live, `zip_locations` seeded). Tasks 1–7 can be built before deploy; Task 8 (end-to-end verification) needs it live.

**Conventions** (verified against the codebase — follow exactly):
- `SeedkeepKit` is a pure Swift package (no SwiftData/UIKit); DTOs are flat `Codable, Sendable, Equatable` structs in `Models/Wire.swift` with snake_case fields matching server JSON. `SeedkeepClient` is a `public actor`. Tests are **Swift Testing** (`import Testing`, `@Test`, `#expect`) in `Tests/SeedkeepKitTests/`, run via `cd SeedkeepKit && swift test`.
- SwiftData `@Model` types live in `Seedkeep/Core/Models/`, registered in the `Schema([...])` in `AppEnvironment.makeModelContainer()`. Enums stored as raw strings; arrays/JSON as JSON `String` with typed computed accessors. DTO↔Model conversion in `Core/Models/Mapping.swift` (`makeLocal()` / `apply(to:)`).
- `AppEnvironment` (`@MainActor @Observable`) owns services; views read `@Environment(AppEnvironment.self)`.
- `AppPreferences` (`@MainActor @Observable`) persists to `UserDefaults` under `seedkeep.*` keys.
- App build: `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`. `.xcodeproj` is generated from `project.yml` (`xcodegen generate` after pulling; do not hand-edit the `.xcodeproj`).

---

## File Structure

**Create:**
- `SeedkeepKit/Sources/SeedkeepKit/Models/Recommendation.swift` — `RecommendationDTO`, `DailyScoresDTO`, `DateRangeDTO`, `LocationDTO`/response wrappers.
- `Seedkeep/Core/Models/LocalRecommendation.swift` — the 9th `@Model`.
- `Seedkeep/Core/Recommendation/RecommendationStore.swift` — fetch/cache/refine coordinator.
- `Seedkeep/Core/Recommendation/WeatherKitRefiner.swift` — client-side forecast refinement.
- `Seedkeep/Features/Recommendation/RecommendationPanel.swift` — reusable window + gradient + weather-note view.
- `Seedkeep/Features/Garden/WhatToPlantView.swift` — the urgency-grouped "what to plant" view.
- `Seedkeep/Features/Settings/HomeLocationSettingsView.swift` — ZIP-entry screen.

**Modify:**
- `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift` — recommendation + location methods.
- `SeedkeepKit/Tests/SeedkeepKitTests/EnvelopeTests.swift` — new DTO decode tests.
- `project.yml` — add the WeatherKit entitlement.
- `Seedkeep/App/AppEnvironment.swift` — register `LocalRecommendation`, construct `RecommendationStore`.
- `Seedkeep/Core/Models/Mapping.swift` — `RecommendationDTO.makeLocal()` / `apply(to:)`.
- `Seedkeep/Features/Settings/SettingsView.swift` — "Home location" row in the Garden section.
- `Seedkeep/Features/Settings/GardenSettingsView.swift` — remove manual frost-date entry (superseded by ZIP).
- `Seedkeep/Features/SeedDetail/SeedDetailView.swift` — mount `RecommendationPanel`.
- `Seedkeep/Features/Garden/AddPlantingEventView.swift` — replace `recommendationSection` + `frostWarningSection` with `RecommendationPanel`.
- `Seedkeep/Features/Library/SeedRow.swift` — verdict dot.
- `Seedkeep/Features/Garden/GardenView.swift` — toolbar/section link to `WhatToPlantView`.
- `Seedkeep/Core/Preferences/AppPreferences.swift` — drop the `seedkeep.garden.*` frost/zone keys.

**Delete:**
- `Seedkeep/Core/Garden/SowRecommendation.swift`
- `Seedkeep/Core/Garden/HardinessZoneFrostData.swift`

---

## Task 1: SeedkeepKit — Recommendation DTOs + client methods

**Files:**
- Create: `SeedkeepKit/Sources/SeedkeepKit/Models/Recommendation.swift`
- Modify: `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift`
- Test: `SeedkeepKit/Tests/SeedkeepKitTests/EnvelopeTests.swift`

- [ ] **Step 1: Write the DTOs**

Create `SeedkeepKit/Sources/SeedkeepKit/Models/Recommendation.swift`. Field names are snake_case to match the server JSON (verified against Phase A `assembleRecommendation` in `seedkeep-server/src/routes/recommendations.ts`):

```swift
import Foundation

public struct DateRangeDTO: Codable, Sendable, Equatable {
    public let start: String   // 'YYYY-MM-DD'
    public let end: String
}

public struct DailyScoresDTO: Codable, Sendable, Equatable {
    public let anchorDate: String  // 'YYYY-MM-DD'
    public let scores: [Double]    // length 60

    private enum CodingKeys: String, CodingKey {
        case anchorDate = "anchorDate"
        case scores
    }
}

public struct RecommendationDTO: Codable, Sendable, Equatable {
    public let catalogSeedId: String
    public let locationSignature: String
    public let computedAt: Int64        // ms-epoch
    public let source: String           // 'rule' | 'ai'
    public let confidence: Double
    public let verdict: String          // too_early|plant_soon|plant_now|late|too_late|unknown
    public let recommendedRange: DateRangeDTO?
    public let indoorRange: DateRangeDTO?
    public let dailyScores: DailyScoresDTO
    public let reasoning: String?
    public let inputsUsed: [String]

    private enum CodingKeys: String, CodingKey {
        case catalogSeedId, locationSignature, computedAt, source, confidence,
             verdict, recommendedRange, indoorRange, dailyScores, reasoning, inputsUsed
    }
}

public struct HouseholdLocationDTO: Codable, Sendable, Equatable {
    public let zip: String
    public let latitude: Double
    public let longitude: Double
    public let usdaZone: String
    public let avgLastFrost: String   // 'MM-DD'
    public let avgFirstFrost: String
}

public enum WireRecommendation {
    public struct BulkResponse: Codable, Sendable, Equatable {
        public let recommendations: [RecommendationDTO]
        public let pending: [String]
    }
}
```

NOTE: the Phase A server returns these keys in **camelCase** (the route handler builds the object with camelCase literals — `catalogSeedId`, `recommendedRange`, etc.), unlike the snake_case DTOs elsewhere in `Wire.swift`. The `CodingKeys` above are therefore camelCase. Verify against the actual server response in Task 8; if the server emits snake_case, switch the `CodingKeys`.

- [ ] **Step 2: Add client methods to SeedkeepClient**

In `SeedkeepClient.swift`, add three methods following the existing `getJSON` / `sendJSON` helper pattern (read the file first to match the exact helper signatures):

```swift
public func setHouseholdLocation(zip: String) async throws -> HouseholdLocationDTO {
    try await sendJSON(method: "PUT", path: "/api/households/me/location",
                       body: ["zip": zip])
}

public func recommendation(catalogSeedID: String) async throws -> RecommendationDTO {
    try await getJSON(path: "/api/recommendations/\(catalogSeedID)")
}

public func bulkRecommendations(catalogSeedIDs: [String]) async throws -> WireRecommendation.BulkResponse {
    try await sendJSON(method: "POST", path: "/api/recommendations/bulk",
                       body: ["catalogSeedIds": catalogSeedIDs])
}
```

Match the actual envelope-unwrapping pattern of the existing methods — if existing methods return the unwrapped `data` payload, these should too. If the single-recommendation response is wrapped (e.g. `{ ok, data: {...Recommendation} }`), `getJSON` returning `RecommendationDTO` directly is correct since `data` *is* the recommendation.

- [ ] **Step 3: Write the failing tests**

Add to `EnvelopeTests.swift` (Swift Testing style):

```swift
@Test func decodesRecommendation() throws {
    let json = #"""
    { "ok": true, "data": {
        "catalogSeedId": "cat_1", "locationSignature": "7a:39.5,-77.0",
        "computedAt": 1779000000000, "source": "rule", "confidence": 0.85,
        "verdict": "plant_now",
        "recommendedRange": { "start": "2026-05-18", "end": "2026-07-01" },
        "indoorRange": null,
        "dailyScores": { "anchorDate": "2026-05-20", "scores": [0.0, 0.5, 1.0] },
        "reasoning": null, "inputsUsed": ["frost_tolerance", "avg_last_frost"]
    } }
    """#.data(using: .utf8)!
    let env = try JSONDecoder().decode(Envelope<RecommendationDTO>.self, from: json)
    guard case .ok(let rec, _) = env else { Issue.record("expected ok"); return }
    #expect(rec.verdict == "plant_now")
    #expect(rec.recommendedRange?.start == "2026-05-18")
    #expect(rec.dailyScores.scores.count == 3)
}

@Test func decodesBulkRecommendations() throws {
    let json = #"""
    { "ok": true, "data": { "recommendations": [], "pending": ["cat_7"] } }
    """#.data(using: .utf8)!
    let env = try JSONDecoder().decode(Envelope<WireRecommendation.BulkResponse>.self, from: json)
    guard case .ok(let bulk, _) = env else { Issue.record("expected ok"); return }
    #expect(bulk.pending == ["cat_7"])
}

@Test func decodesHouseholdLocation() throws {
    let json = #"""
    { "ok": true, "data": {
        "zip": "10001", "latitude": 40.75, "longitude": -73.99,
        "usdaZone": "7b", "avgLastFrost": "04-01", "avgFirstFrost": "11-08"
    } }
    """#.data(using: .utf8)!
    let env = try JSONDecoder().decode(Envelope<HouseholdLocationDTO>.self, from: json)
    guard case .ok(let loc, _) = env else { Issue.record("expected ok"); return }
    #expect(loc.usdaZone == "7b")
}
```

- [ ] **Step 4: Run tests**

Run: `cd SeedkeepKit && swift test`
Expected: PASS — the three new tests plus the existing suite. If a decode test fails on key casing, fix the `CodingKeys` in `Recommendation.swift` to match (camelCase vs snake_case) and re-run.

- [ ] **Step 5: Commit**

```bash
git add SeedkeepKit/Sources/SeedkeepKit/Models/Recommendation.swift \
  SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift \
  SeedkeepKit/Tests/SeedkeepKitTests/EnvelopeTests.swift
git commit -m "Add Recommendation DTOs + client methods to SeedkeepKit"
```

---

## Task 2: `LocalRecommendation` SwiftData model

**Files:**
- Create: `Seedkeep/Core/Models/LocalRecommendation.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift`, `Seedkeep/Core/Models/Mapping.swift`

- [ ] **Step 1: Write the model**

Create `Seedkeep/Core/Models/LocalRecommendation.swift`:

```swift
import Foundation
import SwiftData

@Model
final class LocalRecommendation {
    @Attribute(.unique) var catalogSeedID: String
    var locationSignature: String
    var computedAt: Int64          // ms-epoch, server compute time
    var source: String             // "rule" | "ai"
    var confidence: Double
    var verdict: String            // server-computed at fetch time
    var rangeStart: String?        // 'YYYY-MM-DD'
    var rangeEnd: String?
    var indoorStart: String?
    var indoorEnd: String?
    var scoresAnchorDate: String   // day 0 of dailyScores
    var dailyScoresJSON: String    // JSON-encoded [Double]
    var reasoning: String?
    var fetchedAt: Int64           // ms-epoch, when the client last pulled it

    init(catalogSeedID: String, locationSignature: String, computedAt: Int64,
         source: String, confidence: Double, verdict: String,
         rangeStart: String?, rangeEnd: String?, indoorStart: String?, indoorEnd: String?,
         scoresAnchorDate: String, dailyScoresJSON: String, reasoning: String?,
         fetchedAt: Int64) {
        self.catalogSeedID = catalogSeedID
        self.locationSignature = locationSignature
        self.computedAt = computedAt
        self.source = source
        self.confidence = confidence
        self.verdict = verdict
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.indoorStart = indoorStart
        self.indoorEnd = indoorEnd
        self.scoresAnchorDate = scoresAnchorDate
        self.dailyScoresJSON = dailyScoresJSON
        self.reasoning = reasoning
        self.fetchedAt = fetchedAt
    }

    var dailyScores: [Double] {
        (try? JSONDecoder().decode([Double].self, from: Data(dailyScoresJSON.utf8))) ?? []
    }
}
```

- [ ] **Step 2: Register the model in the container**

In `AppEnvironment.swift`, find `makeModelContainer()` and add `LocalRecommendation.self` to the `Schema([...])` array (it becomes the 9th type).

- [ ] **Step 3: Add the mapping**

In `Core/Models/Mapping.swift`, add an extension converting `RecommendationDTO` → `LocalRecommendation`:

```swift
extension RecommendationDTO {
    func makeLocal(fetchedAt: Int64) -> LocalRecommendation {
        LocalRecommendation(
            catalogSeedID: catalogSeedId, locationSignature: locationSignature,
            computedAt: computedAt, source: source, confidence: confidence,
            verdict: verdict,
            rangeStart: recommendedRange?.start, rangeEnd: recommendedRange?.end,
            indoorStart: indoorRange?.start, indoorEnd: indoorRange?.end,
            scoresAnchorDate: dailyScores.anchorDate,
            dailyScoresJSON: (try? String(data: JSONEncoder().encode(dailyScores.scores), encoding: .utf8)) ?? "[]",
            reasoning: reasoning, fetchedAt: fetchedAt)
    }

    func apply(to local: LocalRecommendation, fetchedAt: Int64) {
        local.locationSignature = locationSignature
        local.computedAt = computedAt
        local.source = source
        local.confidence = confidence
        local.verdict = verdict
        local.rangeStart = recommendedRange?.start
        local.rangeEnd = recommendedRange?.end
        local.indoorStart = indoorRange?.start
        local.indoorEnd = indoorRange?.end
        local.scoresAnchorDate = dailyScores.anchorDate
        local.dailyScoresJSON = (try? String(data: JSONEncoder().encode(dailyScores.scores), encoding: .utf8)) ?? "[]"
        local.reasoning = reasoning
        local.fetchedAt = fetchedAt
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Core/Models/LocalRecommendation.swift Seedkeep/App/AppEnvironment.swift Seedkeep/Core/Models/Mapping.swift
git commit -m "Add LocalRecommendation SwiftData model + DTO mapping"
```

---

## Task 3: WeatherKit entitlement + `WeatherKitRefiner`

**Files:**
- Modify: `project.yml`
- Create: `Seedkeep/Core/Recommendation/WeatherKitRefiner.swift`

- [ ] **Step 1: Add the WeatherKit entitlement**

In `project.yml`, under the `Seedkeep` target's `entitlements.properties`, add alongside the existing `com.apple.developer.applesignin` and `com.apple.developer.associated-domains`:

```yaml
        com.apple.developer.weatherkit: true
```

Run `xcodegen generate` after. NOTE: WeatherKit also requires enabling the capability for the App ID in the Apple Developer portal — this is a one-time external step (flag it in the task report; the build succeeds without it, but live WeatherKit calls fail until the portal capability is on).

- [ ] **Step 2: Write the refiner**

Create `Seedkeep/Core/Recommendation/WeatherKitRefiner.swift`. It takes a server baseline + a WeatherKit 10-day daily forecast and returns adjusted scores + an optional note. Keep the rule logic pure and separately testable from the WeatherKit fetch.

```swift
import Foundation
import WeatherKit
import CoreLocation

struct RefinedRecommendation {
    var verdict: String
    var dailyScores: [Double]
    var scoresAnchorDate: String
    var weatherNote: String?
}

struct ForecastDay: Sendable {       // testable stand-in for WeatherKit's DayWeather
    let date: Date
    let lowTempF: Double
    let highTempF: Double
    let precipitationInches: Double
}

struct WeatherKitRefiner {
    // Pure: baseline + forecast → refined. No I/O. Unit-tested.
    static func refine(verdict: String, scores: [Double], anchorDate: String,
                       frostTolerance: String?, soilTempMaxF: Int?,
                       forecast: [ForecastDay]) -> RefinedRecommendation {
        // TODO(plan): implement the four rules from the spec —
        //  (a) frost in forecast + tender variety → shift verdict toward "wait",
        //      zero scores for days <= the frost day;
        //  (b) heavy rain day → drop that day + 2 trailing days;
        //  (c) sustained heat vs soilTempMaxF for a cool-season variety → trim
        //      the late edge;
        //  (d) no adverse signal in 10 days → weatherNote = "Next 10 days look ideal."
        // The implementer writes this against the tests in Step 3.
        fatalError("implement against tests")
    }

    // Thin WeatherKit fetch — fetches the daily forecast for a coordinate.
    static func fetchForecast(latitude: Double, longitude: Double) async throws -> [ForecastDay] {
        let weather = try await WeatherService.shared.weather(
            for: CLLocation(latitude: latitude, longitude: longitude))
        return weather.dailyForecast.forecast.prefix(10).map { day in
            ForecastDay(
                date: day.date,
                lowTempF: day.lowTemperature.converted(to: .fahrenheit).value,
                highTempF: day.highTemperature.converted(to: .fahrenheit).value,
                precipitationInches: day.precipitationAmount.converted(to: .inches).value)
        }
    }
}
```

**This task requests your implementation.** `WeatherKitRefiner.refine(...)` is the heart of the client-side refinement — it encodes how *this year's* weather adjusts the season-typical server baseline. The four rules are described in the spec (§ "iOS WeatherKit refinement"); the exact thresholds (what counts as "heavy rain", how many days of heat is "sustained") are judgment calls. Implement `refine` against the Step 3 tests, choosing thresholds you can defend — e.g. heavy rain = `precipitationInches > 0.5`, sustained heat = 3+ consecutive days above a cool-season ceiling. Mark the file location: `WeatherKitRefiner.swift`, the `refine` function.

- [ ] **Step 3: Write tests for the pure refiner**

Create `SeedkeepTests` coverage (Swift Testing) — or a dedicated test file — for `WeatherKitRefiner.refine`: one test per rule (frost downgrade, heavy-rain score drop, sustained-heat trim, ideal-stretch note) using hand-built `[ForecastDay]` fixtures. The `refine` function is pure so no WeatherKit mocking is needed.

- [ ] **Step 4: Build + test**

Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build` then the test scheme. Expected: BUILD SUCCEEDED, refiner tests pass.

- [ ] **Step 5: Commit**

```bash
git add project.yml Seedkeep/Core/Recommendation/WeatherKitRefiner.swift SeedkeepTests/
git commit -m "Add WeatherKit entitlement + WeatherKitRefiner with tests"
```

---

## Task 4: `RecommendationStore`

**Files:**
- Create: `Seedkeep/Core/Recommendation/RecommendationStore.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift`

- [ ] **Step 1: Write the store**

Create `Seedkeep/Core/Recommendation/RecommendationStore.swift` — a `@MainActor @Observable` service owned by `AppEnvironment`, mirroring how `SyncEngine` is structured. Responsibilities:
- `recommendation(for catalogSeedID:) -> LocalRecommendation?` — synchronous read from SwiftData (for view bodies).
- `refresh(catalogSeedID:) async` — calls `client.recommendation(catalogSeedID:)`, upserts `LocalRecommendation` via the Task 2 mapping.
- `bulkRefresh(catalogSeedIDs:) async` — calls `client.bulkRecommendations(...)`, upserts each, re-requests `pending[]` on the next call.
- A WeatherKit refinement layer: after a baseline is loaded, lazily call `WeatherKitRefiner.fetchForecast` once per household location (cache the forecast in-memory for ~6h), apply `WeatherKitRefiner.refine` to produce a `RefinedRecommendation` held in an in-memory `[String: RefinedRecommendation]` map keyed by `catalogSeedID`. The persisted `LocalRecommendation` is the server baseline; refinement is in-memory only (forecast goes stale daily).

Construct it with the `SeedkeepClient` + `ModelContainer` (same as `SyncEngine`). Read `SyncEngine.swift` for the established `@MainActor` service shape and `ModelContext` usage.

- [ ] **Step 2: Wire into AppEnvironment**

In `AppEnvironment.swift`, add `public let recommendations: RecommendationStore` and construct it in `live()` alongside `sync`.

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Seedkeep/Core/Recommendation/RecommendationStore.swift Seedkeep/App/AppEnvironment.swift
git commit -m "Add RecommendationStore — fetch, cache, WeatherKit refinement"
```

---

## Task 5: `RecommendationPanel` reusable view

**Files:**
- Create: `Seedkeep/Features/Recommendation/RecommendationPanel.swift`

- [ ] **Step 1: Write the panel**

Create `Seedkeep/Features/Recommendation/RecommendationPanel.swift` — a SwiftUI view taking a `LocalRecommendation` (+ optional in-memory `RefinedRecommendation`) and rendering the layered model:
- the recommended window as a date range,
- the 60-day suitability gradient strip (horizontal bar of colored segments from `dailyScores`, with a date axis and — when a user-chosen date is supplied — a marker),
- the verdict as a colored capsule/label,
- the WeatherKit note (when present),
- a `409 no_household_location` empty state ("Set your garden location to get planting recommendations" linking to `HomeLocationSettingsView`).

Verdict → colour mapping (matches the spec's vocabulary): `plant_now` green, `plant_soon` amber, `too_early` slate, `late` orange, `too_late` red, `unknown` dashed grey.

It takes an optional `userDate: Date?` parameter so the planting-event mount can show the chosen date against the gradient; when nil (seed-detail mount) the marker is omitted.

- [ ] **Step 2: Build with a preview**

Add a `#Preview` with a sample `LocalRecommendation`. Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Seedkeep/Features/Recommendation/RecommendationPanel.swift
git commit -m "Add reusable RecommendationPanel view"
```

---

## Task 6: Home-location ZIP screen; retire manual frost entry

**Files:**
- Create: `Seedkeep/Features/Settings/HomeLocationSettingsView.swift`
- Modify: `Seedkeep/Features/Settings/SettingsView.swift`, `Seedkeep/Features/Settings/GardenSettingsView.swift`, `Seedkeep/Core/Preferences/AppPreferences.swift`

- [ ] **Step 1: Write the ZIP screen**

Create `Seedkeep/Features/Settings/HomeLocationSettingsView.swift` — a `Form`-based view (mirror `GardenSettingsView`'s structure): a 5-digit ZIP `TextField` (`.keyboardType(.numberPad)`), a "Save" button that calls `appEnv.client.setHouseholdLocation(zip:)`, and a result area showing the resolved zone + frost dates on success or the error (`invalid_zip` / `unknown_zip`) on failure. On success, store the resolved `HouseholdLocationDTO` into a new `AppPreferences` value (`homeZip`, `cachedUsdaZone`) so the UI can show it without a round-trip.

- [ ] **Step 2: Add the Settings row**

In `SettingsView.swift`, add a `NavigationLink` to `HomeLocationSettingsView()` in the **"Garden"** section, following the established row shape (Label + caption subtitle showing the current ZIP/zone).

- [ ] **Step 3: Retire manual frost entry**

`GardenSettingsView` currently edits `lastFrost` / `firstFrost` / `hardinessZone` from `AppPreferences`. The server (via the ZIP) now owns frost/zone. Remove the manual frost-date + zone editors from `GardenSettingsView` (leave any non-frost garden settings intact; if the view becomes empty, remove its Settings row too). Remove the `seedkeep.garden.lastFrostMonth/Day`, `firstFrostMonth/Day`, `hardinessZone` keys and accessors from `AppPreferences.swift`. The `MonthDay` type can stay if still referenced; if not, remove it.

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED. This step will surface every reference to the removed `AppPreferences` frost APIs — Task 7 cleans up the remaining callers (`SowRecommendation`, `AddPlantingEventView`), so a build break confined to those files is expected and fine until Task 7; if other unexpected callers appear, report them.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Features/Settings/HomeLocationSettingsView.swift \
  Seedkeep/Features/Settings/SettingsView.swift \
  Seedkeep/Features/Settings/GardenSettingsView.swift \
  Seedkeep/Core/Preferences/AppPreferences.swift
git commit -m "Add home-ZIP location screen; retire manual frost entry"
```

---

## Task 7: Wire the four surfaces; delete the old engine

**Files:**
- Delete: `Seedkeep/Core/Garden/SowRecommendation.swift`, `Seedkeep/Core/Garden/HardinessZoneFrostData.swift`
- Create: `Seedkeep/Features/Garden/WhatToPlantView.swift`
- Modify: `Seedkeep/Features/SeedDetail/SeedDetailView.swift`, `Seedkeep/Features/Garden/AddPlantingEventView.swift`, `Seedkeep/Features/Library/SeedRow.swift`, `Seedkeep/Features/Garden/GardenView.swift`

- [ ] **Step 1: Delete the old engine**

Delete `Seedkeep/Core/Garden/SowRecommendation.swift` and `Seedkeep/Core/Garden/HardinessZoneFrostData.swift`. (`git rm` them.)

- [ ] **Step 2: Seed detail panel**

In `SeedDetailView.swift`, mount `RecommendationPanel` in `plantSection` (adjacent to the "Plan to plant" button) — or as a new section directly below `growingInfoSection`. The view already loads `catalog: CatalogSeedDTO?` in a `.task(id:)`; add a parallel fetch: `appEnv.recommendations.refresh(catalogSeedID:)` then read `appEnv.recommendations.recommendation(for:)`. If the seed has no `catalogID`, omit the panel.

- [ ] **Step 3: Planting-event panel**

In `AddPlantingEventView.swift`, replace the `recommendationSection` (the old `SowRecommendation.Plan` card) and fold in the `frostWarningSection` by mounting `RecommendationPanel` with `userDate:` set to the picked plant date. Keep the "Use this date" affordance — wire it to set the DatePicker to the recommended window start. The old `sowRecommendation` computed property and its `SowRecommendation.recommend(...)` call are removed.

- [ ] **Step 4: Library verdict dot**

In `SeedRow.swift`, add a small colored verdict dot in row 2's `HStack` (immediately after the type capsule, per the spec — dot only, no text). Read the verdict from `appEnv.recommendations.recommendation(for: seed.catalogID)`; show nothing if the seed has no catalog link or no cached recommendation. `LibraryView` should call `appEnv.recommendations.bulkRefresh(catalogSeedIDs:)` for its visible seeds (in its existing sync/refresh path).

- [ ] **Step 5: "What to plant" view**

Create `Seedkeep/Features/Garden/WhatToPlantView.swift` — a `List` of the household's catalog-linked seeds grouped by verdict urgency (`plant_now`, `plant_soon`, then a collapsed "later / closing / missed" group), each row showing the seed name + window + days-remaining. Sort within the query by one key (`rangeStart`) and group in code (per the project's single-key `@Query` convention). Add a toolbar button or section link in `GardenView` that pushes `WhatToPlantView`.

- [ ] **Step 6: Build + full test**

Run: `xcodegen generate && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED with no remaining references to `SowRecommendation` / `HardinessZoneFrostData`. Run `cd SeedkeepKit && swift test` and the app test scheme — all green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Wire planting-window surfaces; remove local SowRecommendation engine"
```

---

## Task 8: End-to-end verification + TestFlight

**Prerequisite:** Phase A deployed to `seedkeep-server.fly.dev` with `zip_locations` seeded.

- [ ] **Step 1: Device/simulator smoke**

Build to a simulator or device signed in to a real household. Verify: Settings → Home location → enter a ZIP → resolves zone + frost; a seed with a catalog link shows a `RecommendationPanel` on its detail page with a window + gradient; the Library row shows a verdict dot; `AddPlantingEventView` shows the panel with the date marker; the "What to plant" view groups seeds by urgency. On a device with WeatherKit entitlement provisioned, confirm the weather note appears.

- [ ] **Step 2: Offline check**

Airplane mode: a previously-viewed recommendation still renders from `LocalRecommendation` (gradient against absolute dates, no weather note). A never-fetched one shows the load-when-online placeholder.

- [ ] **Step 3: Bump build + cut TestFlight**

Bump `CURRENT_PROJECT_VERSION` in `project.yml`, archive, upload to TestFlight (the established release flow — see prior `Release 0.1.0 (build N)` commits).

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "Release 0.2.0 (build N) to TestFlight"
```

---

## Self-Review

**Spec coverage** — Phase B spec items → tasks: SeedkeepKit DTOs/methods → T1; `LocalRecommendation` → T2; WeatherKit entitlement + refiner → T3; `RecommendationStore` → T4; `RecommendationPanel` → T5; ZIP-entry screen → T6; four UI surfaces → T7; end-to-end + TestFlight → T8.

**Beyond the spec, driven by codebase reality:** deleting `SowRecommendation` + `HardinessZoneFrostData` and retiring the manual frost entry (T6/T7) — the spec assumed a greenfield client; the user chose "replace the local engine."

**Known soft spots for the executor:**
- T1 Step 1: server response key casing (camelCase vs snake_case) — the Phase A route builds camelCase; verify against a live response in T8 and fix `CodingKeys` if needed.
- T3: `WeatherKitRefiner.refine` is a requested contribution — the four rules are specified but the thresholds are judgment calls; tests lock the behavior.
- T3: the WeatherKit Apple Developer portal capability is an external one-time step — the build succeeds without it but live calls fail until it's enabled.
- T6 Step 4 will break the build in `SowRecommendation` / `AddPlantingEventView` callers — that is expected and resolved in T7. A build break outside those files is not expected — report it.

**Type consistency** — `RecommendationDTO` (SeedkeepKit) ↔ `LocalRecommendation` (`@Model`) ↔ the Task 2 mapping all agree on field names; `RecommendationPanel` consumes `LocalRecommendation`; `RecommendationStore` is the single owner of fetch+cache+refine.

---

## Execution

After Task 8, the smart-planting-window feature is complete across both repos. Update `seedkeep-ios/.docs/ai/{current-state,roadmap}.md` and the umbrella `seedkeep/.docs/ai/current-state.md`. Phase 2's WeatherKit milestone (M2 in the umbrella roadmap) is then met; extension calendars remain deferred to 0.3.0.
