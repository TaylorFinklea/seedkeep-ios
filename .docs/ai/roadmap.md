# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

iOS client for Seedkeep. Phase 1 ships a household seed library with offline-first inventory, scan-to-catalog flow, Sign in with Apple, and a tier-aware extraction pipeline (Free on-device, BYOK direct-to-provider, Hosted via the server). Phase 2 builds the garden plan on top of that inventory. Pairs with the `seedkeep-server` API.

## Now / Next / Later

### Now (Phase 2: Garden plan — partially shipped)
- [x] 2A: Garden tab — beds CRUD + planting events timeline (TestFlight build 10)
- [x] 2B: Frost-date awareness in planting events (TestFlight build 11)
- [x] 2C.1: Bed layout canvas — measured grid, `xFeet` / `yFeet` position on events (TestFlight build 12)
- [x] 2C: Spacing rings on canvas, drag-and-drop reposition, zone-based auto-fill, sow-recommendation chips (TestFlight build 13)
- [x] Editable seed identity (name / variety / company) from `SeedDetailView` (build 15)
- [x] Transplant frost warnings for tender plants scheduled before last frost (build 15)
- [x] `GrowingInfoSnapshot` on `LocalSeed` — snapshots catalog growing info onto the seed so manual / offline entries carry growing info too (build 15)
- [x] Scan-confirm hang eliminated — UIImage resize + base64 encode moved off MainActor (build 16)
- [x] Per-seed Type field with `LibraryView` "Group by type" toggle (build 16)
- [x] **Smart planting window** (Phase B, merged to `main` 2026-05-20) — server-driven recommendations: home-ZIP location, `RecommendationStore`, `WeatherKitRefiner`, `RecommendationPanel`, four UI surfaces (Library dot, seed detail, planting event, "What to plant" view). Replaced the old local `SowRecommendation` engine. Not yet TestFlight-cut (gated on the Phase A server deploy + a 0.2.0 build).
- [ ] **Extension-calendar integration** (regional planting calendars from state cooperative-extension feeds) — deferred to 0.3.0+ per the smart-planting-window spec.
- [ ] **TestFlight feedback triage** — pull tester feedback / crash logs from App Store Connect for builds 11–16.

### Next
- [ ] **Hosted-tier unflag** — register `app.seedkeep.ios.hosted.{monthly,yearly}` products in App Store Connect, set `APPLE_IAP_SHARED_SECRET` + `ANTHROPIC_API_KEY` on Fly, flip `AppPreferences.isHostedTierEnabled = true`. Ships as 0.1.1.
- [ ] **F5 closing the loop**: real-device verification of the Hosted tier path once unflagged (Free + BYOK already proven via builds 11+).
- [ ] **Offline photo upload queue** (deferred from Phase 1) — `LocalPendingPhotoUpload` model, byte storage, retry orchestration. Probably ships in 0.2.0 alongside any remaining Phase 2 surface.
- [ ] **Two-device real Sign in with Apple test** — needs bundle ID + provisioning profile in `AppConfig.local.xcconfig`.

### Later
- [ ] Phase 3 — Journal
- [ ] Phase 4 — AI assistant
- [ ] Phase 5 — Tomagachi + sensors

### Shipped — Phase 1 (Seed Library)
- [x] B1–B4: Repo bootstrap, SeedkeepKit package, Xcode app target, Sign in with Apple, household auto-create
- [x] C1–C10: Sync engine, optimistic local writes, Library / Add / Detail / Random / Settings, 5-tab MainTabView
- [x] D1–D5: Multipart extraction submit, AVFoundation camera, ScanFlow coordinator, Prefill banner, viewfinder toolbar button
- [x] E1: Universal-link + custom-URL-scheme invite handling
- [x] E2: Write-queue retry hardening (exponential backoff, dead-letter at 6 attempts, Pending Writes diagnostic view)
- [x] E3: Online-only photo attach (`PhotosPicker` → JPEG → upload → `AuthedImage`)
- [x] F3: Server URL picker + AI provider picker + `OnDeviceExtractor` (Vision OCR + Foundation Models)
- [x] F4: BYOK keys in Keychain, `BYOKExtractor` direct-to-provider, StoreKit 2 `SubscriptionManager`, receipt validation
- [x] F5: Free + BYOK proven on TestFlight (Hosted gated behind feature flag)

## Milestones

### M1: Phase 1 — Seed Library — ✅ shipped to TestFlight
- [x] App boots, signs in, hits the API
- [x] Library lists active / wishlist / saved / archived seeds
- [x] Scan flow extracts a packet via the API or on-device
- [x] Household-shared with one invite
- [x] Tier-aware extraction (Free, BYOK, Hosted-gated)

### M2: Phase 2 — Garden Plan — 🚧 in progress
- [x] Beds CRUD + planting events timeline (2A)
- [x] Frost-date awareness (2B)
- [x] Bed layout canvas + spatial position (2C.1)
- [x] Spacing rings, drag-and-drop, zone auto-fill, sow recs (2C)
- [ ] WeatherKit-driven planting windows
- [ ] Extension-calendar integration
- [ ] 0.2.0 release on TestFlight

### M3: 0.1.1 — Hosted tier on
- [ ] App Store Connect products approved
- [ ] Fly secrets configured
- [ ] `isHostedTierEnabled = true`

## Constraints

- iOS 18.1+ floor (FoundationModels gated behind `if #available(iOS 26.0, *)`).
- No CloudKit — `seedkeep-server` is the source of truth.
- `.xcodeproj` is generated from `project.yml`; do not hand-edit it.
- Bundle ID: `app.seedkeep.ios`.

## Backlog

<!-- Self-contained items any agent can execute. Each entry: Scope, Files, Acceptance, Verify, Tier hint. -->
