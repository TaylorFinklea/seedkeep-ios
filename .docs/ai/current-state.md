# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-04

- Shipped F3: iOS Server URL picker + on-device extraction.
- Bumped deployment target 18.0 → 18.1 (FoundationModels gate is iOS 26+ at runtime, availability-checked).
- New `AppPreferences` (Observable) with persisted `serverURLOverride`, `aiProvider` (`free` / `byok` / `hosted`), and a `cachedTier` snapshot from the server.
- `AppEnvironment` now constructs the live `SeedkeepClient` from `effectiveServerURL`. `setServerURL(_:)` validates the URL against `/api/health` before mutating the client. `refreshTier()` calls `/api/subscriptions/me`.
- Settings → Server: URL picker that saves only after the health check passes; supports reset to bundle default.
- Settings → AI provider: picker for Free / BYOK / Hosted with help text + a tier-mismatch warning when the picker disagrees with the server-reported tier.
- `OnDeviceExtractor` (`Seedkeep/Core/AI/OnDeviceExtractor.swift`): two-stage. Stage 1 = Vision `VNRecognizeTextRequest` OCR on front + back JPEGs (iOS 13+). Stage 2 = `FoundationModels.LanguageModelSession` structured-fields extraction (iOS 26+, gated by `SystemLanguageModel.default.isAvailable`). Falls back to OCR-only on older / non-AI-capable devices.
- `ScanFlow` now branches on `appEnv.preferences.aiProvider`. Free + BYOK call `OnDeviceExtractor.extract(...)` then POST `/api/extractions/pre-extracted`. Hosted keeps the multipart server-vision path. New `.preExtracted` `ScanResult` case threads back to `AddSeedView.Prefill.preExtraction` with its own review banner ("Extracted on-device — Self-confidence 0.xx").
- SeedkeepKit: added `WireResponses.PreExtractedResult`, `SeedkeepClient.PreExtractedInput`, `submitPreExtracted(_:)`, plus `SubscriptionMeResponse` / `SubscriptionDTO` and `subscriptionMe()`. Four new `EnvelopeTests` cover round-trip decoding (including no-photos and free-tier-no-subscription edges). 10/10 SeedkeepKit tests pass.
- F0/F1/F2 (server side, in `~/git/seedkeep-server`) shipped earlier in the session: tagged `f1-bootstrap-complete` and `f2-tier-subscriptions-complete`.

**Date**: 2026-05-03

- Shipped Phase 1 steps D (scan flow) and E (polish) on iOS in the same session.
- D-ios: `submitExtraction` multipart upload, `CameraView` over AVFoundation, `ScanFlow` state machine, `AddSeedView` Prefill banner, viewfinder toolbar button on Library.
- E1: universal-link + custom-URL-scheme invite handling. `seedkeep://invite/<code>` and `https://seedkeep.app/invite/<code>` both route to a presentable `InviteAcceptView` that calls `acceptInvite` and refreshes the household state.
- E2: write-queue hardening. `LocalPendingWrite` carries `nextAttemptAt` and `isDeadLettered`; `flushPending()` skips backed-off and dead-lettered rows. Settings → Pending writes lists every queue row with last error + retry/forget actions. Backoff: 2/4/8/16/32/64s capped at 5 min, dead-letter after 6 attempts.
- E3: online-only photo attach. `SeedkeepClient.uploadSeedPhoto` posts raw JPEG; `fetchSeedPhotoData` streams binary. `SyncEngine.refreshSeedPhotos` fetches `GET /api/seeds/:id` and reconciles `LocalSeedPhoto` rows. `AuthedImage` renders with Bearer header (since `AsyncImage` can't add it). SeedDetailView gets a horizontal photo strip + PhotosPicker → JPEG (75% quality) → upload.
- Offline photo queue is **deferred** post-Phase-1; documented in roadmap.

## Build Status

- `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED** (after F3).
- `cd SeedkeepKit && swift test` → 10/10 tests passing.
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

F3 complete. Remaining for the F1–F5 tier-aware Phase 1 sequence:

1. **F4** — iOS BYOK key fields (Anthropic + OpenAI keychain entries with a Settings → API keys form) + StoreKit 2 subscription flow. The Hosted-tier purchase + restore + receipt validation against `POST /api/subscriptions/verify`.
2. **F5** — End-to-end verification across Free / BYOK / Hosted on a real device against the new `seedkeep-server`, plus updates to all three repos' handoff docs.

Pre-existing follow-ups from earlier phases:

- Live two-device test with real Sign in with Apple — needs your Apple bundle ID + provisioning profile in `AppConfig.local.xcconfig`.
- Decide whether offline-photo queueing ships in v1 or is a fast-follow.
