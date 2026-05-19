# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

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

- `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build` last verified green at build 16 cut (2026-05-19).
- `cd SeedkeepKit && swift test` — 11/11 last documented at F4 completion; no SeedkeepKit-touching changes since (Phase 2A/B/C and 2C.1 work was app-target + server side).
- `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 16` in `project.yml`.
- Garden feature surface: `Seedkeep/Features/Garden/{GardenView, AddBedView, BedDetailView, AddPlantingEventView, BedLayoutCanvas}.swift` + SwiftData `LocalBed` and `LocalPlantingEvent`.
- TestFlight: 0.1.0 build 16 is the latest uploaded; build 16 is the current top of `main`.

## Blockers

- Hosted tier still feature-flagged off (`AppPreferences.isHostedTierEnabled = false`). To unflag: register `app.seedkeep.ios.hosted.{monthly,yearly}` in App Store Connect, set `APPLE_IAP_SHARED_SECRET` + `ANTHROPIC_API_KEY` on Fly via `fly secrets set`. Bundle ID is `app.seedkeep.ios`. (Carried over from F4.)
- F5 end-to-end real-device verification across all three tiers still notionally open, but Free + BYOK have shipped to TestFlight builds 11+ without regressions — the remaining gap is the Hosted-tier path, which is gated by the flag above.
- Pending-photo-upload offline queue still deferred post-Phase-1 (documented in roadmap).

## Next concrete step

Phase 2A/B/C and 2C.1 shipped through TestFlight build 16. The remaining Phase 2 surface still to scope:

1. **Garden plan completion** — the Plan tab placeholder is gone (Garden tab is real now), but the documented Phase 2 surface includes WeatherKit-driven planting windows beyond frost dates, and extension-calendar integration. Neither has a tracked task yet — needs a brainstorming session to decide what ships in 0.2.0.
2. **TestFlight feedback triage** — six TestFlight builds (11–16) shipped Phase 2 features over ~2 weeks. Worth pulling tester feedback / crash logs from App Store Connect before scoping the next chunk.
3. **Hosted tier unflag** — purely a configuration step (App Store Connect product setup + two `fly secrets set` calls + a one-line iOS code change). Could ship as 0.1.1 once products are approved.

Pre-existing follow-ups still open:

- Live two-device test of real Sign in with Apple — needs Apple bundle ID + provisioning profile in `AppConfig.local.xcconfig`. (Last documented 2026-05-04.)
- Offline-photo queueing decision — ship in 0.2.0 or stay deferred.
