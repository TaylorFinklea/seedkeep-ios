# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

iOS client for Seedkeep. Phase 1: a household seed library with offline-first inventory, scan-to-catalog flow, and Sign in with Apple. Pairs with the `seedkeep` Workers API.

## Now / Next / Later

### Now
- [x] B1: seedkeep-ios repo bootstrap (.gitignore, README, .docs/ai/, project.yml)
- [x] B2: SeedkeepKit Swift package — Envelope, SeedState, Wire DTOs, SeedkeepClient (4 tests passing)
- [x] B3: Xcode app target — Sign in with Apple, AppConfig.example.xcconfig, /api/me + household round-trip wired
- [x] B4: Household auto-create rolled into AuthController; empty Library tab + You tab placeholders ship

### Next
- [ ] C-ios: Library with delta sync — locations, tags, seeds CRUD against the API
- [ ] D-ios: Scan flow — camera, barcode, front/back photo capture, extraction trigger
- [ ] E: Universal-link invite accept + offline polish (queued writes, retry photo uploads)

### Later
- [ ] Phase 2 — Garden plan with WeatherKit + extension calendars
- [ ] Phase 3 — Journal
- [ ] Phase 4 — AI assistant
- [ ] Phase 5 — Tomagachi + sensors

## Milestones

### M1: Phase 1 — Seed Library
- [ ] App boots, signs in, hits the Workers backend
- [ ] Library lists active / wishlist / saved / archived seeds
- [ ] Scan flow extracts a packet via the API
- [ ] Household-shared with one invite

## Constraints

- iOS 18+ only (target raised to iOS 26 simulator for development).
- No CloudKit — backend is the source of truth (matches `seedkeep` API).
- `.xcodeproj` is generated from `project.yml`; do not hand-edit it.

## Backlog

<!-- Self-contained items any agent can execute. Each entry: Scope, Files, Acceptance, Verify, Tier hint. -->
