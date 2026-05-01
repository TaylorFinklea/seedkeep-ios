# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-30

- Bootstrapped `seedkeep-ios` repo as the iOS client for the `seedkeep` Workers backend.
- Project file generated from `project.yml` via XcodeGen (chosen by the user as the bootstrap path).
- Bundle ID, server URL, and other deployment knobs live in `Seedkeep/Config/AppConfig.example.xcconfig`.

## Build Status

- Repo: initialized; first commit pending.
- `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED** (Debug, simulator, code-signing disabled).
- `swift test` in `SeedkeepKit/` → 4/4 passing (Envelope decode + DeltaPage + SeedDTO round-trips).
- App target wired:
  - `SeedkeepApp` SwiftUI entry → `RootView` (auth state machine) → `MainTabView` (Library / Plan / Random / You).
  - `AppEnvironment` resolves base URL + keychain service from Info.plist, instantiates `SeedkeepClient` and `AuthController`.
  - `SignInView` runs Sign in with Apple, exchanges the id_token at `/api/auth/sign-in/social`, and stashes the Bearer token via `KeychainTokenStore`.
  - `AuthController.loadIdentity()` calls `/api/me` then idempotently `POST /api/households` so a fresh user always lands inside a household.
  - `YouView` shows identity + household + creates household invites via `/api/households/me/invites`.
  - `LibraryView` is a placeholder with the four-state segmented picker locked in.

## Blockers

- Sign in with Apple will reject the bundle ID `com.example.seedkeep` outside a real provisioning profile. To run signed: copy `AppConfig.example.xcconfig` → `AppConfig.local.xcconfig`, set a real bundle ID and team ID, regenerate.
- Backend `seedkeep` repo must be running locally for the app to connect (`npm run dev` in `~/git/seedkeep`).

## Next concrete step

C-ios: replace the Library placeholder with a real list driven by `SeedkeepClient.seeds(...)`. Add the location/tag CRUD UIs in Settings. Wire the Random tab to `SeedkeepClient.randomSeed()`.
