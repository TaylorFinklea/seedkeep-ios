# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-03

- Shipped Phase 1 steps D (scan flow) and E (polish) on iOS in the same session.
- D-ios: `submitExtraction` multipart upload, `CameraView` over AVFoundation, `ScanFlow` state machine, `AddSeedView` Prefill banner, viewfinder toolbar button on Library.
- E1: universal-link + custom-URL-scheme invite handling. `seedkeep://invite/<code>` and `https://seedkeep.app/invite/<code>` both route to a presentable `InviteAcceptView` that calls `acceptInvite` and refreshes the household state.
- E2: write-queue hardening. `LocalPendingWrite` carries `nextAttemptAt` and `isDeadLettered`; `flushPending()` skips backed-off and dead-lettered rows. Settings → Pending writes lists every queue row with last error + retry/forget actions. Backoff: 2/4/8/16/32/64s capped at 5 min, dead-letter after 6 attempts.
- E3: online-only photo attach. `SeedkeepClient.uploadSeedPhoto` posts raw JPEG; `fetchSeedPhotoData` streams binary. `SyncEngine.refreshSeedPhotos` fetches `GET /api/seeds/:id` and reconciles `LocalSeedPhoto` rows. `AuthedImage` renders with Bearer header (since `AsyncImage` can't add it). SeedDetailView gets a horizontal photo strip + PhotosPicker → JPEG (75% quality) → upload.
- Offline photo queue is **deferred** post-Phase-1; documented in roadmap.

## Build Status

- `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**.
- `cd SeedkeepKit && swift test` → 5/5 tests passing.
- Backend round-trips verified via curl + synthetic Bearer tokens: PATCH `/api/seeds/:id`, PATCH `/api/tags/:id`, DELETE `/api/tags/:id` all return correct envelopes.
- C-ios surface area:
  - `Seedkeep/Core/Models/` — six `@Model` types + `Mapping.swift`.
  - `Seedkeep/Core/Sync/SyncEngine.swift` — `syncAll(householdID:)` and `flushPending()`; optimistic enqueue methods.
  - `Seedkeep/Features/Library/{LibraryView, SeedRow}.swift`, `SeedDetail/SeedDetailView.swift`, `Add/AddSeedView.swift`, `Random/RandomPickView.swift`, `Settings/{SettingsView, LocationsView, TagsView}.swift`.
  - `MainTabView` is now 5 tabs; `YouView` slimmed to identity + sign-out.
- `AppEnvironment.live()` configures the `ModelContainer` over the six `@Model` types and instantiates the `SyncEngine` once.
- `SeedkeepApp` triggers `appEnv.syncIfPossible()` from a `.task(id:)` keyed on the auth state, so we sync once per sign-in transition rather than every state change.

## Blockers

- Sign in with Apple still requires a real bundle ID + provisioning profile to actually log in (the build succeeds; auth round-trip on a real device requires user-supplied keys via `AppConfig.local.xcconfig`).
- Backend `seedkeep` repo must be running locally for the app to connect (`npm run dev` in `~/git/seedkeep`).

## Next concrete step

Phase 1 is feature-complete on the iOS side. Remaining work before declaring v1 ready:

1. Live two-device test with real Sign in with Apple — needs your Apple bundle ID + provisioning profile in `AppConfig.local.xcconfig`.
2. Live extraction smoke test in the iOS app (needs `ANTHROPIC_API_KEY` configured in the backend `.dev.vars`).
3. Decide whether offline-photo queueing ships in v1 or is a fast-follow.
