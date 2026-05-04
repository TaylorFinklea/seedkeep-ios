# Decisions

> Architecture decision records. Append-only — one entry per decision.

## [2026-04-30] XcodeGen for the project file

**Context**: The `.xcodeproj/project.pbxproj` is fragile when hand-edited and large diff churn discourages reviewing changes. Three real options: hand-craft, XcodeGen, or have a human author the project in Xcode.

**Decision**: Use XcodeGen. The single source of truth is `project.yml`. The `.xcodeproj` is gitignored and regenerated with `xcodegen generate` after pulling.

**Alternatives considered**: Hand-crafted `.xcodeproj`; manually authored Xcode project; SPM-only iOS app (still experimental).

**Rationale**: XcodeGen is the lowest-friction CLI-friendly option for a single-target iOS app and matches the workflow of agent-assisted development — every change is reviewable as a YAML diff. `brew install xcodegen` is a one-time setup tax.

## [2026-04-30] SeedkeepKit Swift package, separate from app target

**Context**: Where to put the API client, models, sync logic? Inline in the app target, or in a Swift package that the app target depends on?

**Decision**: Standalone `SeedkeepKit` package under `SeedkeepKit/`. The app target depends on it via XcodeGen's `package` resolution.

**Alternatives considered**: Inline in the Seedkeep app target; multiple smaller packages.

**Rationale**: A package is testable on macOS via `swift test` without spinning up a simulator — much faster iteration. It also makes the boundary between "pure logic" (kit) and "iOS-specific UI" (app) hard to accidentally cross.

## [2026-04-30] Bearer token in Keychain (no CloudKit)

**Context**: Token storage options: `UserDefaults` (insecure), Keychain (secure, local), iCloud Keychain (synced).

**Decision**: Local Keychain via `KeychainTokenStore`. Service name comes from `KEYCHAIN_SERVICE` xcconfig var so dev/staging/prod can coexist.

**Alternatives considered**: Synced Keychain; rolling our own AES-encrypted file.

**Rationale**: Local Keychain is the standard. Sync would mean a token issued on iPhone could authenticate on iPad — fine on its face, but couples session lifetime to iCloud account state. We can revisit if cross-device convenience becomes a complaint.

## [2026-05-03] Pending-write retry: exponential backoff with dead-lettering

**Context**: The Phase 1 sync engine retried failed pending writes on every `syncAll()` pass with no backoff or cap, which would hammer the server during transient outages and deadlock against permanent failures.

**Decision**: Each `LocalPendingWrite` carries `nextAttemptAt` and `isDeadLettered`. `flushPending()` skips rows whose backoff window hasn't elapsed and ignores dead-lettered rows. Backoff is `2 * 2^(attempt-1) seconds`, doubled up to attempt 9, capped at 5 minutes. After 6 failed attempts the row is dead-lettered until the user manually retries it from Settings → Pending writes.

**Alternatives considered**: Linear backoff; immediate dead-letter on any 4xx; permanent retry forever.

**Rationale**: 6 attempts × exponential progression covers ~2 minutes of cumulative wait — enough to ride through brief network blips without being so aggressive that a permanent failure runs forever. Surfacing the dead-letter state in Settings keeps the user in control without blocking the rest of the app.

## [2026-05-03] Online-only photo attach for Phase 1

**Context**: Seed photos are multi-MB and can't fit comfortably in the existing `LocalPendingWrite` JSON payload. Building an offline photo upload queue (separate `@Model`, byte storage, retry orchestration) is real work.

**Decision**: Phase 1 photo attach is online-only. The PhotosPicker → JPEG → `uploadSeedPhoto` flow surfaces an inline error if offline. Catalog-extraction photos (the AI flow) are unaffected because they're inherently online.

**Alternatives considered**: Build the offline queue now; defer photo attach entirely until v1.1.

**Rationale**: The high-leverage offline cases are inventory edits (the "I'm in the seed aisle" job), not attaching photos to existing seeds. Document the gap, ship Phase 1, revisit if real users complain.

## [2026-05-02] SwiftData stays in the app target, not in SeedkeepKit

**Context**: Where should the `@Model` types live? Inside `SeedkeepKit` (so other targets could share them) or inside the app target?

**Decision**: SwiftData `@Model` types live in `Seedkeep/Core/Models/`. `SeedkeepKit` stays SwiftData-free.

**Alternatives considered**: Co-locate `@Model` with the wire DTOs inside `SeedkeepKit`.

**Rationale**: `SeedkeepKit` is testable on macOS via `swift test` in 2 seconds. Adding SwiftData would force the kit to depend on a runtime that's only fully realized on iOS, slowing CI and making test-target builds heavier. Mapping at the boundary (`Mapping.swift`) is cheap.

## [2026-05-02] Single `@Query` sort key (not multi-sort) in SwiftData lists

**Context**: Swift 6 + SwiftData's macro-generated `@Query` + multi-`SortDescriptor` arrays + optional-comparison predicates triggered "compiler unable to type-check this expression in reasonable time" failures across multiple views.

**Decision**: Use the single-key `@Query(filter:, sort:, order:)` form. If the screen needs a secondary sort, do it in code after the query returns.

**Alternatives considered**: Tag every property with a `Bool isDeleted` to drop the optional comparison; switch off macros entirely.

**Rationale**: The single-key form is well-tested by Apple and short-circuits the type-checker explosion. The amount of data we sort on the iOS client (per-household) easily fits in memory, so a secondary in-code sort is free.

## [2026-05-04] Server URL picker + AI provider live in app preferences

**Context**: F3 introduces three independent moving parts that previously had no UI: which Seedkeep server to talk to, which extraction tier to use, and what the *server-reported* tier is. We needed a place to put them that didn't grow the AppEnvironment surface or force every view to reach into UserDefaults.

**Decision**: New `AppPreferences` (`@Observable`, `@MainActor`) holds three persisted values: `serverURLOverride: URL?`, `aiProvider: AIProvider` (`free` / `byok` / `hosted`), and `cachedTier: String?`. AppEnvironment owns one and exposes it; views read it via the environment. The bundled xcconfig URL is the *default*; `serverURLOverride` only fires when the user saves a non-default URL via Settings → Server (and only after `/api/health` succeeds against the candidate URL).

**Alternatives considered**: Inline UserDefaults reads in each settings view; one big NSUserDefaults wrapper without observation; rebuild the SeedkeepClient on every view appearance.

**Rationale**: Centralized observable preferences let SwiftUI re-render automatically when the URL or tier change, and make it trivial to write a "current state" diagnostic later. Validating the URL with `/api/health` *before* persisting prevents the app from silently breaking when a user typos a host.

## [2026-05-04] On-device extraction is OCR + Foundation Models, not vision-direct

**Context**: F3 needs a way to extract `common_name` / `variety` / `company` / `instructions` from packet photos *on-device*. Apple Foundation Models (iOS 26+) is the obvious target, but its public API surface is text-only — there's no `respond(to: image:)`.

**Decision**: Two-stage on-device pipeline. Stage 1 = Vision (`VNRecognizeTextRequest`, iOS 13+) OCRs front + back JPEGs into raw text. Stage 2 = `FoundationModels.LanguageModelSession` (iOS 26+) ingests the OCR text and returns a JSON object. We parse the JSON in Swift and clamp `self_confidence` to [0,1].

**Alternatives considered**: Wait for Apple to ship a vision-capable Foundation Models API; ship a small CoreML packet-classifier; ship without on-device extraction and force everyone to BYOK or Hosted.

**Rationale**: OCR + LLM is *good enough* for seed packets — the packet is structured text, and OCR quality on modern iOS is excellent. We get a real `self_confidence` rating from the model that the server uses verbatim as the catalog-publish gate (per the server-side ADR). On iOS < 26 (or iOS 26+ devices without Apple Intelligence), we surface OCR-only output with `selfConfidence = 0` so the user still has a manual-review path.

## [2026-05-04] iOS deployment target 18.1 (not 26.0) despite Foundation Models requirement

**Context**: Foundation Models is an iOS 26+ framework. We could either bump the floor to 26.0 (smaller install base, simpler code) or stay broader and gate the framework usage with availability checks.

**Decision**: Floor at iOS 18.1 (the minimum that ships a SwiftUI surface comparable to our usage). Wrap all `FoundationModels` references in `#if canImport(FoundationModels)` + `if #available(iOS 26.0, *)`. iOS 18.1–25.x devices fall through to OCR-only extraction or to the Hosted-tier server path.

**Alternatives considered**: Floor at iOS 26.0; floor at iOS 18.0 (but FoundationMacros pulled tooling toward 18.1 anyway).

**Rationale**: Phase 1's job is the daily-use seed library. Locking out everyone on iOS 18 to get one feature on iOS 26 trades the user base for the feature. The availability dance is mechanical and well-supported.

## [2026-05-04] BYOK keys live only in the device Keychain

**Context**: BYOK ("bring your own key") lets a user point Seedkeep at an Anthropic or OpenAI account they already pay for. The natural temptation is to store the key on the server so we can run extraction server-side with it — that gives us the same vision pipeline as Hosted, but billed to the user.

**Decision**: BYOK keys never reach our server. They live in the device Keychain, are read into `BYOKExtractor` at extraction time, and the vision call goes directly from the iPhone to api.anthropic.com / api.openai.com. The structured result is then POSTed to `/api/extractions/pre-extracted` (same path Free uses).

**Alternatives considered**: Store keys server-side (encrypted at rest); proxy BYOK calls through our server with the user's key passed in headers; ship a "we'll just charge you" tier instead.

**Rationale**: Keys-on-server is a security liability (compliance burden, breach blast radius, accidental logging). It also gives us nothing the device can't do itself — Anthropic and OpenAI APIs are reachable from iOS. Keeping the boundary clean — server never sees a third-party API key — also matches the self-host story: a self-hoster never has to worry about a third-party key in their database.

## [2026-05-04] StoreKit 2 + verifyReceipt as the IAP path

**Context**: F4 needs to take money for the Hosted tier. Apple's IAP options for an auto-renewable subscription: StoreKit 1 (legacy), StoreKit 2 (modern, async/await), App Store Server API (server-driven, requires JWT signing).

**Decision**: StoreKit 2 on the client + the legacy `verifyReceipt` endpoint on the server. The client base64-encodes `Bundle.main.appStoreReceiptURL` bytes and POSTs them to `/api/subscriptions/verify`; the server hits Apple's verifyReceipt with the configured shared secret and falls back from production → sandbox per Apple's recipe.

**Alternatives considered**: StoreKit 1 (deprecated for new code); App Store Server API + S2S notifications instead of verifyReceipt.

**Rationale**: StoreKit 2 gives us async/await + JWS-verified transactions client-side; verifyReceipt + shared secret is the simplest server path that doesn't require generating + signing JWTs. We can swap to App Store Server API + S2S notifications later (already noted as a TODO in the server roadmap) without changing the iOS surface.

## [2026-05-04] Device-side BYOK uses vision-LLM, not OCR + LLM

**Context**: Free uses two-stage extraction (Vision OCR → Foundation Models) because Foundation Models is text-only. BYOK could either follow the same shape (OCR → Anthropic-text) or send the raw images straight to a vision-capable LLM.

**Decision**: BYOK sends raw images to Anthropic's Claude vision (or OpenAI's GPT-4o vision). No on-device OCR step.

**Alternatives considered**: OCR + text-LLM via the user's key (cheaper per call, but needs an OCR pass); send images as data-URIs but use a text-only model (worse quality, no upside).

**Rationale**: Vision LLMs are *much* better than OCR + text-LLM at packet extraction — they can read color cues, logos, layout, partial text. The user is already paying for tokens; we should give them the best quality their key can buy. Free has to use OCR because Foundation Models can't see images; BYOK has no such restriction.

## [2026-04-30] Household auto-create on first sign-in

**Context**: After Sign in with Apple, the user has zero households. We can either gate the rest of the app on a "Create or join household" wall, or auto-create one and let them invite later.

**Decision**: Auto-create. `AuthController.loadIdentity()` calls `POST /api/households` (idempotent on the server side) right after `/api/me`. The server returns the existing household if there's already a membership.

**Alternatives considered**: Onboarding wall with create/join choice.

**Rationale**: Phase 1's primary user is the solo gardener replacing a Google Sheet. They shouldn't see a screen explaining a household before they see seeds. The household is invisible plumbing until they create an invite.
