# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-20 — Phase B: smart planting window (iOS client)

- Built the **iOS client side of the smart-planting-window feature** (0.2.0) and merged it to `main` (commit `666ac46`). Plan: `.docs/ai/plans/2026-05-20-smart-planting-window-ios.md`. Design spec: `~/git/seedkeep/.docs/ai/specs/2026-05-20-smart-planting-window-design.md`. Executed as 8 tasks via subagent-driven development on branch `smart-planting-window-ios` (merged, worktree cleaned up).
- **SeedkeepKit** — `Recommendation.swift` DTOs (`RecommendationDTO`, `DailyScoresDTO`, `DateRangeDTO`, `HouseholdLocationDTO`, `WireRecommendation.BulkResponse`) + client methods `setHouseholdLocation(zip:)`, `recommendation(catalogSeedID:)`, `bulkRecommendations(catalogSeedIDs:)`. 14/14 kit tests.
- **`LocalRecommendation`** — 9th SwiftData `@Model`, registered in `AppEnvironment.makeModelContainer()`; `RecommendationDTO` mapping in `Mapping.swift`.
- **`WeatherKitRefiner`** (`Core/Recommendation/`) — pure `refine(...)` (frost / heavy-rain / sustained-heat / ideal-stretch rules, tested) + a thin `fetchForecast` WeatherKit call. WeatherKit entitlement added to `project.yml`.
- **`RecommendationStore`** (`Core/Recommendation/`, owned by `AppEnvironment.recommendations`) — fetch/cache/refine coordinator; `updateEpoch` observable drives view reactivity; `needsHomeLocation` flag.
- **`RecommendationPanel`** (`Features/Recommendation/`) — reusable view: verdict badge, recommended window, 60-day suitability gradient, weather note. `VerdictPalette.swift` shares verdict colors.
- **Four UI surfaces** wired: Library `SeedRow` verdict dot, `SeedDetailView` panel, `AddPlantingEventView` panel (replacing the old sow-recommendation + frost-warning sections), new `WhatToPlantView` (Garden tab, urgency-grouped).
- **`HomeLocationSettingsView`** — home-ZIP entry (Settings → Garden); resolves zone/lat-lon/frost server-side.
- **Removed** the old local engine: `SowRecommendation.swift`, `HardinessZoneFrostData.swift`, `GardenSettingsView.swift` (manual frost-date entry) — the server now owns frost/zone via the home ZIP. `AppPreferences` frost/zone keys + `MonthDay` removed.
- A final code review found 6 issues (recommendation reactivity, verdict-dot visibility, WeatherKit never invoked, a refiner range crash, lat/lon not persisted, color divergence) — all fixed in commit `666ac46`.

**Date**: 2026-05-19

- Cut TestFlight build 16 (0.1.0 / 16) — current latest on App Store Connect.
- Eliminated multi-second scan-confirm hang: moved UIImage resize (1–3s per photo) and base64 encoding (~8 MB total for front + back) off MainActor onto detached tasks. `resizedJPEG` and `encodeBase64Pair` are now `nonisolated`; `applyResizedPhoto` re-checks scan phase post-resize so cancelled photos drop cleanly. Files: `Seedkeep/Features/Scan/ScanFlow.swift`.
- Added per-seed `customType: String?` to `LocalSeed` (additive, local-only migration). `AddSeedView` infers a type from the extraction / catalog `common_name` at save time; `SeedDetailView` exposes a Type field in the Identity section (wired via `SyncEngine.setLocalCustomType`). `SeedRow` renders the type as a tint-colored capsule.
- Added "Group by type" toggle in `LibraryView` toolbar (persisted via `@AppStorage`). On = `insetGrouped` style with one section per type, "Untyped" pushed to bottom; off = the existing flat list. Stable alphabetical section order.
- Cut TestFlight build 15 (0.1.0 / 15) immediately prior, carrying:
  - Editable seed identity — name, variety, company now editable from `SeedDetailView` via `enqueueUpdateSeed`.
  - Transplant frost warnings — frost-warning banner now fires on transplant events for tender plants scheduled before last frost, not just direct-sow.
  - Growing-info snapshot on `LocalSeed` — new `GrowingInfoSnapshot` (Codable) + `growingInfoJSON` field. `SeedDetailView` reads snapshot first, falls back to catalog, backfills legacy seeds on read. Lets manual-entry and offline seeds carry growing info without depending on a catalog row.

**Date**: 2026-05-17 (range: 2026-05-04 → 2026-05-17, multiple sessions documented in commits only)

- Phase 2A shipped (build 10): Garden tab — beds CRUD + planting events timeline. Files: `Seedkeep/Features/Garden/{GardenView, AddBedView, BedDetailView, AddPlantingEventView}.swift`. SwiftData adds `LocalBed`, `LocalPlantingEvent`. Pairs with `seedkeep-server` migration adding `beds` + `planting_events` tables.
- Phase 2B shipped (build 11): Frost-date awareness in planting events. Server returns last/first frost dates for the household's hardiness zone; planting events show "X days before last frost" relative banners.
- Phase 2C.1 shipped (build 12): Bed layout canvas — `BedLayoutCanvas.swift` renders the bed as a measured grid; planting events carry `xFeet` / `yFeet` for spatial position. `AddPlantingEventView` includes position pickers.
- Phase 2C shipped (build 13): Spacing rings (visualizes per-plant spacing radius on the canvas), drag-and-drop reposition, zone-based auto-fill of suggested spacing, sow-recommendation chips on the planting event card.
- Build 14 cut on top of Phase 2C (consolidation only, no notable user-facing changes documented in the commit).
- NUMERIC decode fix (server-side, in `seedkeep-server` commit `0662fe7`): postgres.js was returning NUMERIC columns as strings, which broke iOS-side Double decoding. Server now parses NUMERIC as Number before envelope serialization.

## Build Status

- `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED** on merged `main` (2026-05-20).
- `cd SeedkeepKit && swift test` → **14/14** (added 3 Recommendation DTO decode tests). App test target `SeedkeepTests` → 15/15 (added `WeatherKitRefinerTests`).
- `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 16` in `project.yml` — **not yet bumped for 0.2.0**; no TestFlight build cut with Phase B yet.
- SwiftData model count is now **9** (`LocalRecommendation` added).
- `main` is **not pushed to origin** — Phase B is merged locally only.

## Blockers

- **Phase B depends on the Phase A server being deployed.** The recommendation routes + `PUT /households/me/location` exist in `seedkeep-server` `main` (pushed to origin) but are **not deployed** to `seedkeep-server.fly.dev` yet. Until deploy, the iOS recommendation surfaces will get connection errors. Deploy steps are in `seedkeep-server/.docs/ai/current-state.md`.
- **WeatherKit capability** must be enabled for the App ID (`app.seedkeep.ios`) in the Apple Developer portal (Certificates, Identifiers & Profiles → Identifiers → WeatherKit). The build succeeds without it, but live `fetchForecast` calls fail until it's on.
- Phase B not verified on device or cut to TestFlight (Task 8 device-smoke + TestFlight are deploy-gated).
- Minor: `WeatherKitRefiner.fetchForecast` uses `precipitationAmount` (deprecated in favor of `precipitationAmountByType`) — a warning, not an error; fine to leave or modernize later.
- Hosted tier still feature-flagged off (`AppPreferences.isHostedTierEnabled = false`); unflag = App Store Connect products + Fly secrets. Pending-photo-upload offline queue still deferred.

## Next concrete step

1. **Deploy Phase A** (`seedkeep-server`) — see `seedkeep-server/.docs/ai/current-state.md`. Until then the iOS recommendation features can't be exercised end-to-end.
2. **Enable WeatherKit** for `app.seedkeep.ios` in the Apple Developer portal.
3. **Push `main`**, bump `CURRENT_PROJECT_VERSION`, **cut a 0.2.0 TestFlight build**, verify the smart-planting-window surfaces on a real device against the live server.

Earlier Phase 2 surface still open (lower priority):

1. **Extension-calendar integration** — deferred to 0.3.0+ per the smart-planting-window spec. (WeatherKit-driven planting windows: done — that's the Phase B work above.)
2. **TestFlight feedback triage** — TestFlight builds 11–16 shipped Phase 2 features over ~2 weeks. Worth pulling tester feedback / crash logs from App Store Connect.
3. **Hosted tier unflag** — purely a configuration step (App Store Connect product setup + two `fly secrets set` calls + a one-line iOS code change). Could ship as 0.1.1 once products are approved.

Pre-existing follow-ups still open:

- Live two-device test of real Sign in with Apple — needs Apple bundle ID + provisioning profile in `AppConfig.local.xcconfig`. (Last documented 2026-05-04.)
- Offline-photo queueing decision — ship in 0.2.0 or stay deferred.
