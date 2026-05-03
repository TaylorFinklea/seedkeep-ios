# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-03

- Continued through Phase 1 step D (scan + catalog) on iOS.
- `SeedkeepClient.submitExtraction` now does multipart upload to `/api/extractions`; envelope test added (6 kit tests passing).
- New `Seedkeep/Features/Scan/` module: `CameraView` (AVCaptureSession + barcode metadata + photo capture, Swift 6 nonisolated delegates) and `ScanFlow` (state machine: scan → catalog lookup → catalog hit OR fallback to two-shot photo capture → /api/extractions).
- `AddSeedView` now accepts a `Prefill` (catalog hit or AI extraction); shows a review banner when AI-sourced. Library toolbar gets a Scan (viewfinder) button alongside "+".
- Conflict policy unchanged (last-write-wins by `updated_at`).

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

E — Phase 1 polish: universal-link invite accept screen (`/invite/<code>`), write-queue retry hardening (exponential backoff + dead-letter visibility in Settings), photo upload queue for seed-attached photos, and a two-device live test against a real backend.
