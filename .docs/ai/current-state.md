# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-02

- Bootstrapped `seedkeep-ios` repo (commit `5cfc739`) and shipped the C-ios slice (commits `7d5198a` + this one).
- C-ios now end-to-end: SwiftData mirror of the wire DTOs, SyncEngine for delta pull + queued push, full UI for Library / Add / SeedDetail / Random / Settings / Locations / Tags.
- Optimistic local writes go through `enqueueCreate / enqueueUpdate / enqueueDelete` and drain on next sync (or immediately via `flushPending()`).
- Conflict policy: last-write-wins by `updated_at` (server values overwrite local on next pull). No conflict UI in Phase 1.

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

D-ios — scan flow: `VNBarcodeObservation` for barcode, `AVCaptureSession` for the camera, multipart upload to `/api/extractions`, "extracting…" UI, accept-or-edit confirmation that lands in a `LocalSeed`.
