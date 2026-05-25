# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-25 (afternoon) — Phase 4 (Sprout) shipped to TestFlight (build 20, 0.4.0)

- Inline-executed the 10-task plan at `.docs/ai/plans/2026-05-25-phase-4-sprout-ios.md` on worktree branch `phase-4-sprout-ios`. ~6 commits (some tasks bundled where their boundaries blurred — T6/T7/T8 became one commit since the UI surface is coherent and the coordinator was already streaming-ready from T5).
- **SeedkeepKit** — `Models/Assistant.swift` (8 DTOs + `AssistantStreamEvent` enum + SSE-payload decoder), 9 thread/key client methods on `SeedkeepClient`, `AssistantStream.swift` with URLSessionDataDelegate-based SSE streaming (URLSession.bytes buffers HTTP/2 frames — bad UX for typewriter streaming, so we use the delegate pattern from SimmerSmith). 27 kit tests (was 18; +9 assistant decode + parser tests).
- **Four new SwiftData models** (13th-16th): `LocalAssistantThread`, `LocalAssistantMessage`, `LocalAssistantToolCall`, `LocalAssistantKeyStatus`. The API key itself is NEVER stored locally — only a configured/not-configured flag.
- **AIAssistantCoordinator** (`Core/Assistant/AIAssistantCoordinator.swift`) — @Observable state machine: `currentThreadID`, `streamingState` (idle / streaming / awaitingConfirmation / error), `pageContext` bus, `keyConfigured` flag. `send()` / `confirmToolCall()` / `cancelToolCall()` drive the SSE event loop and persist deltas to SwiftData as they arrive; @Query re-renders give the typewriter effect with no view-side animation code.
- **SyncEngine** drains `assistant_threads` via the existing delta-sync flow; cascade-cleans messages + tool_calls when a thread is soft-deleted. `refreshAssistantThread(_:)` pulls full thread detail (server has no top-level messages endpoint — messages come down nested in `GET /threads/:id`).
- **MainTabView** now 7 tabs (Library | Garden | Journal | Random | **Sprout** | Settings | You). Tab routing via `AppEnvironment.requestedTab` so the sparkle button can switch tabs programmatically.
- **AssistantView** — thread list + 4 starter prompts ("What did I plant in May 2024?" / "Help me plan Bed A for June" / "Did peppers do well last year?" / "Add a journal entry for today"). Empty state when the key isn't configured points to Settings.
- **AssistantThreadView** — message list + composer + auto-scroll-to-last. Streaming-aware: composer disables while a stream is in flight, "Sprout is thinking…" hint while idle-streaming.
- **AssistantToolCallCard + ProposedChangeCard** — inline tool-call status + Confirm/Cancel buttons for destructive ops. Was→Becomes diff renderer is functional but minimal (T8 polish item).
- **TopBarSparkleButton** + `.publishesAssistantContext(...)` view modifier — global "ask Sprout" affordance. Mounted on Library, Garden, SeedDetail. Other detail views can opt in with one line of view modifier.
- **AssistantKeySettingsView** — Settings → "Sprout (AI assistant)" → AI assistant key. SecureField for write, Replace + Revoke for re-management. Privacy disclosure explains AES-256-GCM server-side encryption and that Anthropic bills directly.
- **TestFlight build 20** (commit `02c02eb`) — `release.sh --minor` bumped 0.3.0 → 0.4.0 / 19 → 20. `** ARCHIVE SUCCEEDED **` + `** EXPORT SUCCEEDED **`. Uploaded to App Store Connect; processing.
- Companion server work — see `seedkeep-server/.docs/ai/current-state.md` for Fly v17 (4 tables + 5 routes + tool registry + smoke 18/18).
- Pending: on-device verification of every surface against `seedkeep-server.fly.dev`. Builds 17-20 all need device exercise; 20 is the latest.

**Date**: 2026-05-25 — Phase 3 (Journal) shipped to TestFlight (build 19, 0.3.0)

- Subagent-driven implementation of the 10-task plan at `.docs/ai/plans/2026-05-24-phase-3-journal-ios.md`. All 9 build commits executed on worktree branch `phase-3-journal-ios` (one task per commit, two-stage review per task), fast-forward merged to main, pushed, release cut.
- **SeedkeepKit** — `Models/JournalEntry.swift` with 6 DTOs (`JournalEntryDTO`, `JournalEntryPhotoDTO`, `JournalChecklistItemDTO`, `RetrospectiveYearDTO`, `RetrospectiveResponseDTO`) + `typealias JournalFeedResponseDTO = DeltaPage<JournalEntryDTO>` to reuse the existing delta-sync envelope. 13 client methods on `SeedkeepClient` (feed, CRUD, photos list/upload/delete/binary-fetch, checklist list/add/update/delete, retrospective). 4 new decode tests; total **18/18** (was 14).
- **Three new SwiftData models** (the 10th–12th) — `LocalJournalEntry` (with derived `parentKind` enum), `LocalJournalEntryPhoto`, `LocalJournalChecklistItem`. Mapping extensions in `Mapping.swift`. Registered in `AppEnvironment` schema.
- **SyncEngine** drains `journal_entries` via `pullJournalEntries(householdID:)` + `upsertJournalEntries(_:)`; on server soft-delete, hard-deletes the local entry AND cascade-cleans its photos + checklist items via `cleanupJournalEntryChildren(...)`.
- **New top-level Journal tab** between Garden and Random — 6 tabs now. `JournalView` is the chronological feed (`@Query` sorted by `occurredOn DESC`, filtered by `deletedAt == nil`) with an optional `filterParent` for entity-scoped views.
- **`JournalEntryView`** — Form-based create/edit with `DatePicker`, multi-line `TextField` body, `AttachedEntityPicker` (None/seed/bed/planting-event), photo gallery (`PhotosPicker`, off-MainActor resize copied from `ScanFlow`, async upload with `X-Photo-Width`/`X-Photo-Height` headers, context-menu delete, thumbnail subview that fetches binary on appear), and checklist UI (tappable rows with strikethrough on completed + `.swipeActions` delete + TextField with `+` button to add).
- **`EntityScopedJournalSection`** — collapsible "Journal" section showing the last 3 entries scoped to a parent entity. Mounted in `SeedDetailView` and `BedDetailView`. Skipped in `AddPlantingEventView` because it's create-only — flag for future planting-event detail surface.
- **`RetrospectiveCard`** — top-of-feed card calling `/api/journal/retrospective?on=<today MM-DD>`. Hidden when no prior-year entries. Server-side current-year filter (added during server T8 smoke debugging) means first-year gardeners see nothing here until they have history.
- **TestFlight build 19 cut** (commit `06f0459`) — `release.sh --minor` bumped 0.2.0 (18) → 0.3.0 (19). `** ARCHIVE SUCCEEDED **` + `** EXPORT SUCCEEDED **`. Uploaded to App Store Connect; processing.
- Companion server work — see `seedkeep-server/.docs/ai/current-state.md` for Fly v15 (3 tables + 10 routes + smoke 11/11).
- Pending: on-device verification of every surface against `seedkeep-server.fly.dev`. Build 17 + 18 + 19 all need device exercise eventually; 19 is the latest.

**Date**: 2026-05-23 — TestFlight build 18: out-of-window warning on Plan event screen

- User reported the Plan event screen gives **no signal** when the planned date is months outside the recommendation window — picking Oct 13 for an Apr 15 – Jul 25 outdoor window saved silently with no warning. Root cause: the verdict badge is today-anchored (not date-anchored), and the 60-day gradient's "Your date" marker clips dates outside the score span — so a far-future date got zero visual feedback.
- **Added strict in-window check** in `AddPlantingEventView` (`Seedkeep/Features/Garden/AddPlantingEventView.swift`, commit `8e079e5`). When `plannedFor` is outside `[rangeStart, rangeEnd]` (UTC-day comparison to match how the server emits the window):
  - DatePicker tints orange (`.tint(.orange)` + `.foregroundStyle(.orange)`)
  - Caption row beneath says `Window opens MMM d` (before window) or `Window closed MMM d` (after)
  - Save remains enabled — power-users planning late successions shouldn't be blocked
- The `RecommendationPanel` was kept read-only; the validation lives in the caller. Cheap to extend the warning to other planting surfaces if needed.
- **TestFlight build 18 cut** (commit `709c755`) — `release.sh` default (build-only bump), 0.2.0 (17 → 18). Archive succeeded, export succeeded, uploaded to App Store Connect. Same 0.2.0 review record.
- Companion server work — see `seedkeep-server/.docs/ai/current-state.md` for Fly v12 (Kansas added to extension calendars). With KS bundled, the user can finally test extension hits from their own ZIP (66109) without flipping to a VA/CA ZIP.
- **Build 17 device-verification is still open** — adding build 18 means there are now two builds on TestFlight needing on-device exercise of the planting-window surfaces.

**Date**: 2026-05-21 — 0.2.0 shipped: server live + TestFlight build 17

- **Server deployed** — `seedkeep-server` Phase A is live on Fly (release v9): migrations 0007/0008 applied, `zip_locations` seeded (33,751 rows), `/api/health` 200. The recommendation surfaces now have a live API.
- **WeatherKit** capability enabled for `app.seedkeep.ios` in the Apple Developer portal.
- **TestFlight build 17 cut** — `MARKETING_VERSION` 0.1.0 → 0.2.0, `CURRENT_PROJECT_VERSION` 16 → 17 via `scripts/release.sh --minor`; archived, uploaded to TestFlight (release commit `0c27e58`). `main` pushed to origin.
- **`release.sh` signing fix** (commit `cbbb991`) — the archive step now passes the App Store Connect API key so `-allowProvisioningUpdates` can regenerate provisioning profiles without an Apple ID in Xcode. Build 17 first failed to archive because the new WeatherKit entitlement forced a profile regeneration that needs portal auth; the API key satisfies it.
- **Still pending**: on-device verification of the four planting-window surfaces against the live server.

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
- `MARKETING_VERSION = 0.2.0`, `CURRENT_PROJECT_VERSION = 17` in `project.yml` — **TestFlight build 17 cut** 2026-05-21 (release commit `0c27e58`), uploaded to App Store Connect.
- SwiftData model count is now **9** (`LocalRecommendation` added).
- `main` is pushed to origin through the build-17 release commits (`0c27e58`, `cbbb991`).

## Blockers

- **Build 17 not yet verified on device.** The four planting-window surfaces talk to the live server (`seedkeep-server.fly.dev`, Fly release v9) but haven't been exercised on a real device via TestFlight — verify recommendations + WeatherKit refinement once build 17 finishes processing.
- Minor: `WeatherKitRefiner.fetchForecast` uses `precipitationAmount` (deprecated in favor of `precipitationAmountByType`) — a warning, not an error; fine to leave or modernize later.
- Hosted tier still feature-flagged off (`AppPreferences.isHostedTierEnabled = false`); unflag = App Store Connect products + Fly secrets. Pending-photo-upload offline queue still deferred.

## Next concrete step

1. **Verify build 17 on device** — once TestFlight finishes processing 0.2.0 (17), install it and exercise the four planting-window surfaces (Library verdict dot, seed-detail panel, Garden "what to plant", planting-event panel) + WeatherKit refinement against the live server (`seedkeep-server.fly.dev`).
2. **0.2.0 App Store release** — once device-verified, submit 0.2.0 for App Store review (M2 milestone).

Earlier Phase 2 surface still open (lower priority):

1. **Extension-calendar integration** — deferred to 0.3.0+ per the smart-planting-window spec. (WeatherKit-driven planting windows: done — that's the Phase B work above.)
2. **TestFlight feedback triage** — TestFlight builds 11–16 shipped Phase 2 features over ~2 weeks. Worth pulling tester feedback / crash logs from App Store Connect.
3. **Hosted tier unflag** — purely a configuration step (App Store Connect product setup + two `fly secrets set` calls + a one-line iOS code change). Could ship as 0.1.1 once products are approved.

Pre-existing follow-ups still open:

- Live two-device test of real Sign in with Apple — needs Apple bundle ID + provisioning profile in `AppConfig.local.xcconfig`. (Last documented 2026-05-04.)
- Offline-photo queueing decision — ship in 0.2.0 or stay deferred.
