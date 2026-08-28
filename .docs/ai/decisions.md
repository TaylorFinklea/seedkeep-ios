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

---

## 2026-06-30 — CloudKit push state: per-record ledger, not a global watermark (R1 p3, bead 8ck.1)

**Context**: `HouseholdCloudCoordinator` decided what to push to CloudKit using a single global `watermark: Int64` (max clock of locally-pushed records). The applier copies a peer's clock onto the local row, and the watermark only advances over LOCAL pushes (a deliberate clock-skew-poisoning fix), so every peer-edited record had `clock > watermark` and re-uploaded once per cold launch (the session-scoped echo guards reset on relaunch). In an active multi-device household that approached the whole zone every launch.

**Decision**: Replace the global watermark with a durable per-record ledger `[recordName: {clock, tombstoned}]` = the state we KNOW CloudKit holds, written on BOTH push-success and apply-success (the apply-path writer is the actual fix). Stored as a Codable JSON file in Application Support (path DERIVED from householdID/zoneName, env-namespaced), mirroring `HouseholdSyncEngine.loadState/saveState`. Push gate is per-record (no shared ceiling → clock-skew poisoning gone by construction). The `tombstoned` bit lets a local tombstone push over a higher-clock live peer (sticky-deletedAt) AND prevents a tombstone relaunch residual. Ledger committed strictly after `sendUntilDrained`/`context.save` succeeds.

**Alternatives considered**: (a) a dirty boolean per Local* model — rejected (SwiftData schema migration + touch every mutation site). (b) UserDefaults-backed map — rejected: a years-old garden is thousands of entries and `UserDefaults.standard` rewrites the whole shared plist per write. (c) keeping two parallel structures (`syncedClocks` + a tombstone `Set`) — rejected: a single `{clock, tombstoned}` struct also compares tombstone clocks (a re-tombstone at a higher clock still pushes).

**Rationale**: Smallest change that kills the residual without regressing convergence/tombstone/clock-skew invariants; stays entirely inside the coordinator (applier/gate/planner untouched); the derived (not injected) path is what makes the relaunch unit tests work. Deferred (pre-existing, bead 8ck.8): reseed-from-local-graph can mark an unpushed local edit as synced.

## 2026-07-15 — Gate server photo bytes while CloudKit garden sync is active

**Context**: CloudKit mirrors seed and journal photo metadata, but the existing server byte endpoints address the signed-in server household. Running those endpoints for an active owner or participant garden could refresh/delete local projections or create server objects outside the active CloudKit garden.

**Decision**: Keep photo metadata models, CloudKit migration, apply, and deletion projection active so existing server objects remain preserved. Gate only server-backed photo refresh, upload, thumbnail, and delete seams behind the CloudKit household flag. Replace the photo galleries/actions with explicit temporary-limit copy; flag OFF follows the existing server paths unchanged.

**Rationale**: This is reversible and preserves the CloudKit source-of-truth path without silently deleting or duplicating photo objects. The same flag follows owner, participant, and rollback active-garden resolution.

## 2026-07-15 — CloudKit account switches use epoch-tagged fetch buffers and fail-closed cleanup

**Context**: An account switch can occur while `fetchChanges`, migration drain, or push drain is suspended. A post-wipe callback from the old fetch could append to the untagged shared buffer after cleanup, then be projected by the replacement account's next pass. The coordinator also swallowed SwiftData and outbox cleanup failures, allowing fetch/migration/push to continue with a partly wiped store.

**Decision**: Capture the reconcile epoch in each fetched callback batch; a projection drains only its own epoch and irreversibly discards all other batches. Fence startup, fetch/apply, migration, and push continuations after every suspension point. Retire the current `CKSyncEngine` generation synchronously at sign-out/account-switch and reject staging until cleanup explicitly rearms its replacement; `.signIn` is not an abandonment boundary and does not invalidate the epoch. Make household and outbox cleanup throwing. Write a cleanup-pending marker beside the engine token before the MainActor cleanup hop, preserve it across every failure, and clear it only after rows, outbox, token, and synced-state cleanup all succeed. A fresh coordinator that sees the marker permits “Sync now” only to retry cleanup before CloudKit work resumes.

**Rationale**: A return-only epoch check cannot protect against callback data that arrives after a wipe, and an in-memory retry bit cannot survive process death. Binding the generation to the callback closes the projection handoff; retiring the engine closes the staging gap before the MainActor runs; the write-ahead marker makes the same precondition survive relaunch. Together they prevent old-account rows, migration receipts, pending deletes, or queued CKSyncEngine state from leaking into a replacement account.

## 2026-07-15 — Release gates select the CloudKit production default with a test-only compile condition

**Context**: XCTest-hosted app tests historically resolve the CloudKit flag OFF so legacy server-path regressions remain deterministic, while shipping app code must default ON. Shell environment variables are not forwarded by `xcodebuild` into the simulator test runner.

**Decision**: Keep explicit UserDefaults precedence, production default ON, and ordinary XCTest default OFF. The shared gate's ON lane passes the visibly test-scoped `SEEDKEEP_TEST_CLOUDKIT_ON` Swift compilation condition and compiles only its production-default contract suite; the OFF lane runs the legacy suite.

**Alternatives considered**: Shell environment variables; changing the release default; making all existing tests CloudKit-aware in one migration.

**Rationale**: The compile condition crosses the xcodebuild-to-test-runner boundary reliably, cannot affect a normal release build, and makes a missing or zero-test ON lane fail closed.

## 2026-07-16 — Participant row recovery: FK resolution as evidence, a survivable snapshot registry (R1 27d.18)

**Context**: Default-ON builds 47–49 stamped participant-created garden rows with the signed-in server household ID instead of the adopted owner-zone ID, stranding them outside `HouseholdMigrationPlanner.fetchInput`'s householdID filter forever. The five queue-backed types (seeds, beds, planting events, tags, locations) are unambiguous after the adopt wipe + the verified absence of any view-driven CloudKit-ON server import path for them in builds 47–49 (`LibraryView`/`GardenView`/`LocationsView`/`TagsView` all route only through `syncIfPossible`/`flushPending`, and `SyncEngine.syncAll` gates all 7 household pull feeds off when the flag is ON — landed `ed7e89f`, before the default-ON cutover `d0fc7c0`). Journal entries are NOT unambiguous: pre-fix `JournalStore` both authored to and refreshed from the parked solo Postgres feed under the same signed-in ID, so a stranded journal/checklist row has two indistinguishable origins.

**Decision**: Implements the umbrella `decisions.md` (seedkeep repo) 2026-07-16 "Ambiguous pre-fix participant journal rows recover via evidence gating plus a review inbox" policy (bead `seedkeep-27d.18`). `ParticipantRowRecovery` re-homes the five types unconditionally, then re-homes a journal entry automatically ONLY when its `parentKind` FK (seedID/bedID/plantingEventID) resolves into the owner-zone garden AS OF AFTER the five-type re-home (pre-existing owner rows ∪ the rows just re-homed this same pass) — that FK could only have been set by code running against the adopted garden, i.e. post-adopt authorship. Everything else journal-shaped (no FK, or an FK that still doesn't resolve) is quarantined: `householdID` is left unchanged (already hidden — the active-garden filter and the planner's householdID filter both exclude it) and a new SwiftData model, `LocalJournalRecoveryItem`, registers a `pending` review item keyed by the stranded entry's own id, carrying a `snapshotJSON` payload (entry fields + its checklist items, mirroring `LocalPendingWrite.payloadJSON`) and a `scopeKey` of `"<ownerZoneHouseholdID>|<signedInHouseholdID>"`. **[Hardening, 2026-07-16]** An ambiguous entry that is ALSO already soft-deleted (`deletedAt != nil`) gets NO registry item — it is left parked with its tombstone intact instead, so the inbox can never offer to "Share" (and thereby resurrect) already-deleted content; FK-evidenced entries still re-home with an intact tombstone regardless, unchanged. `LocalJournalRecoveryItem` is in `SeedkeepSchema.all` (so `eraseAllLocalData` wipes it on sign-out) but deliberately NOT in `HouseholdCloudCoordinator.wipeHouseholdSwiftData`'s fixed 10-type list, so it survives a future adopt wipe — "Share to garden" re-homes the live row in place when one still exists, else recreates it **atomically** (entry + every checklist item + the registry flip to `shared`, in ONE `ModelContext.save()` via `ParticipantRowRecovery.recreateFromSnapshotAtomically`, added in the 2026-07-16 hardening pass after adversarial review found the original per-row `JournalStore` calls non-atomic — a save failure partway through could leave the registry item `pending` while a duplicate-creating retry target already existed) through the same id-minting convention as `JournalStore`'s CloudKit authoring path (a fresh `journal_local_` id; the entry's original FK is intentionally NOT reattached on recreate, since a quarantined entry's FK by definition never resolved into the owner-zone garden). Every review-inbox action (`shareLiveEntryIfPresent`/`markShared`/`keepPrivate`/`recreateFromSnapshotAtomically`) also re-validates the registry item's `scopeKey` against the caller's current scope and refuses on mismatch (hardening #2, defense-in-depth) — a stale cross-scope item survives undeleted but stays unreachable through the UI unless that exact garden is re-adopted.

**Alternatives considered**: A timestamp-based evidence rule (e.g. "authored after the adopt moment") — rejected, no adopt timestamp is durably persisted anywhere on-device, and both the true post-adopt rows and the pre-fix solo-refresh rows round-trip through the server with ordinary server-clock `updatedAt` values, so no clock-based split could separate them. Auto-moving every wrong-ID journal/checklist row — rejected, a refresh-imported private solo entry would become visible to every CKShare member. Never auto-moving any journal row — rejected, it knowingly strands genuine post-adoption participant work with no in-product recovery path. A transient (session-only) quarantine list — rejected, a subsequent adopt wipe would silently destroy the only record of what needed review, with no way to recreate it.

**Rationale**: FK resolution is the only signal in the data that distinguishes "authored against the adopted garden" from "imported from the parked solo feed" — ids are globally unique server/UUID strings, so a resolving FK cannot be a coincidental match. Making the registry survive `wipeHouseholdSwiftData` (by keeping it out of that fixed type list while still living in `SeedkeepSchema.all`) is what makes "Share to garden" possible after a second adopt wipes the live rows out from under a still-pending review item. Source: umbrella `decisions.md` 2026-07-16, hdeck `seedkeep/20260715-participant-journal-recovery`; closes `seedkeep-27d.18`.

## 2026-07-16 — Gate the legacy pending-write flush at its single choke point, park-then-drain (R1 27d.2)

**Context**: `SyncEngine.flushPending()` dispatches queued `LocalPendingWrite` rows to the legacy Postgres server regardless of the CloudKit household-sync flag. CloudKit already owns household garden data when the flag is ON (`syncAll` skips the 7 pull feeds + push at SyncEngine.swift:131-133), but `flushPending()` is also fired directly from 18 UI call sites (SeedDetail field edits, Locations/Tags views, AddSeed, PendingWritesView) outside `syncAll`, so those still POST/PATCH/DELETE straight to the server — a second writer racing CloudKit's own mutation path and able to double-apply edits server-side.

**Decision**: Add a single fail-closed early return at the very top of `flushPending()` (`SyncEngine.swift:320`, before the in-flight `flushTask` handling): when `FeatureFlags.cloudKitHouseholdSyncEnabled` is true, return immediately with no throw (every call site is a fire-and-forget `Task { try? await ... }`, so there's nothing to surface). `performFlushPass`, dispatch, retry/backoff, and the existing `syncAll` gate are untouched. Pending-write **creation** (`enqueueCreate*`/`enqueueOrCoalesceUpdate`/`enqueueDelete*`, the 15 entrypoints at SyncEngine.swift:648-1049) stays deliberately UNGATED — rows keep enqueueing (coalesced as before) while CloudKit is active. That is the bead's migrate/discard policy for pre-cutover pending rows: park while ON, drain automatically the next time `flushPending()` runs with the flag OFF (a manual rollback), wipe on sign-out (`eraseAllLocalData` already covers `LocalPendingWrite` via `SeedkeepSchema.all`, unchanged).

**Alternatives considered**: Editing all 18 fire-and-forget call sites to check the flag before firing — rejected, 18x the edit surface for the same outcome, and a future 19th call site could reintroduce the leak; gating at the single `flushPending()` choke point makes the invariant structural. Gating pending-write **creation** instead of the flush — rejected: a flag-OFF rollback would then have nothing queued to replay, silently losing every mutation made while CloudKit was ON instead of draining it back to the server.

**Rationale**: `flushPending()` is the only place all 18 UI call sites (plus `syncAll`) funnel through before touching the network, so gating there is provably complete without auditing every caller. Parking (not discarding) enqueued writes costs nothing while CloudKit is the source of truth and turns a flag-OFF rollback into a correct, automatic drain instead of a silent data-loss event. Closes `seedkeep-27d.2` (epic `seedkeep-27d`).

## 2026-07-16 — Retire the legacy server invitation surface; keep only the URL router for graceful landing (R1 27d.14)

**Context**: Implements the umbrella `decisions.md` (seedkeep repo) 2026-07-13 "CKShare is the sole R1 invitation model; server invitations retire" ADR (bead `seedkeep-27d.14`). iOS still minted, presented, and accepted legacy server household invites (`SettingsView`'s "invite" Section, `InviteAcceptView`'s accept flow) alongside CKShare, even though the server path was already unreachable for normally-onboarded users (sign-in auto-creates a household; accept rejects anyone with an existing membership; no leave endpoint exists).

**Decision**: Remove the mint surface entirely — `SettingsView`'s "invite" Section, its three `@State` vars, and `createInvite()` are deleted; the adjacent read-only "household" Section is untouched. Delete the client methods `SeedkeepClient.createInvite()`/`acceptInvite(code:)` plus the now-dead `InviteDTO` and `WireResponses.Invite` — this is the compile-time guarantee that no supported client can call the server invite endpoints again (a future accidental re-wire would fail to build, not silently ship). `InviteURLRouter` and every deep-link entry point (`SeedkeepApp`'s `.onOpenURL`/`.onContinueUserActivity`, `ShareSceneDelegate`'s URL forward, `AppEnvironment.routeIncomingURL`, the `incomingInviteCode` bridge) are kept exactly as-is, so an old `seedkeep://invite/<code>` link or universal link still lands somewhere deliberate instead of a dead route. `InviteAcceptView`'s accept flow (the `Phase` state machine, `POST /api/invites/:code/accept` call, `restoreSession`/`syncIfPossible` follow-up, and the "Joining replaces your current household" copy) is replaced with a static `InviteRetirementNotice` — SF Symbol + `HerbFont.display` title + `HerbFont.bodyItalic` body, the same idiom as `AssistantView.restrictedState` — reused by `SeedkeepApp`'s signed-out invite variant too, since prompting sign-in to redeem a dead flow is worse than just explaining it moved. The retirement copy lives in a new `FeatureFlags.legacyInviteRetirementMessage`, explicitly commented as a **permanent** retirement (unlike the CloudKit capability messages it sits beside, which describe temporary gates).

**Alternatives considered**: Repairing server invitations with an atomic membership state machine (rejected upstream — preserves a second sharing model with no chosen future). Deleting `InviteURLRouter` and the deep-link wiring too (rejected — an old shared link would then dead-end with no explanation instead of landing on a deliberate "moved to iCloud" notice). Keeping the client methods but simply not calling them from any view (rejected — that's a policy, not a guarantee; the compile-time deletion is what makes "no supported client can call this" true instead of merely true-today).

**Rationale**: Deleting the client methods (not just their call sites) turns "iOS doesn't call the legacy invite endpoints" from a code-review claim into something the compiler enforces. The server side is intentionally untouched during the retirement window — `tests/integration/inviteDoubleClaim.test.ts` and `invitePairingJourney.test.ts` already pin the compatibility contract for any still-installed old client, and route removal is gated on the umbrella ADR's 14-day/90% retirement window, not on this iOS-side cutover. Verified: `xcodebuild test` 460/50 (unchanged from baseline — no removed surface owned tests), `scripts/test-gate.sh` both lanes green, server `typecheck` + `test:all` green with `git status` clean throughout. Closes `seedkeep-27d.14` (epic `seedkeep-27d`).

## 2026-07-19 — Changelog is a Swift constant, not a bundled JSON (seedkeep-rdd)

**Context**: The in-app "What's New" changelog needs a source of truth for per-build release notes. Re-litigated at ship time: one agent session proposed a bundled `Changelog.json` (editable without recompiling the model), which conflicted with the already-approved spec's Swift-constant approach. The user chose the Swift constant.

**Decision**: Author releases as `enum ChangelogData { static let releases: [ChangelogRelease] }` in `Seedkeep/Core/Changelog/ChangelogData.swift`, mirroring `CatalogFieldBounds` (structured data as a Swift `static let`, no runtime file load). `release.sh` fail-closes on a missing entry for the new build; a `ChangelogData` integrity test guards well-formedness (unique/descending builds, non-empty changes).

**Alternatives considered**: Bundled JSON in `Seedkeep/Resources/` — rejected: the app has no runtime JSON-loading path (its one JSON resource, `fieldBounds.canonical.json`, is test-only), so JSON would introduce a decode + malformed-file error path the codebase otherwise doesn't have, for the marginal benefit of editing notes without a rebuild — which a per-build changelog never needs (the notes ship with the build). Server-fetched changelog — rejected: cuts against the serverless R1–R5 direction, needs network + caching, and can advertise a build the user doesn't have.

**Rationale**: The Swift constant ships in the binary, works offline, versions with the build, is compile-time checked, and matches an existing repo pattern — zero new infrastructure. Follow-up (roadmap, Minor): the Settings marker paths mark the newest *authored* build while auto-present clamps to `currentBuild`; they agree in every shipped binary but should be clamped to `AppInfo.currentBuild` to remove a dev-workflow footgun. Report: `phases/2026-07-18-whats-new-changelog-report.md`. Bead `seedkeep-rdd`.

## 2026-08-13 — Re-digest the shared source before taking the account-deletion lease (seedkeep-ld2)

**Context**: A CKShare participant can modify the source garden after the owner and successor publish matching verification documents but before the owner deletes the source zone. The server's deletion lease fences transfer state and cancellation, not CloudKit writes. CloudKit provides no operation that atomically reads, freezes, and deletes a shared zone.

**Decision**: At the last safe point before requesting the irreversible server lease, the owner re-fetches the complete source graph, recomputes its canonical hash and per-type census, and compares both with the durable owner verification document. Any difference throws `sourceChangedAfterVerification` while the checkpoint remains `.verified`; no lease is requested and no CloudKit or account deletion runs. The user must retry the handoff. A participant write can still race after this read while the lease request is in flight, so this is explicitly a narrowing fence, not an atomic closure.

**Alternatives considered**: Persisting and comparing a CloudKit change token — rejected for this fix because the canonical verified digest is already the durable content oracle and catches creates, edits, and deletes without a second persistence protocol. Taking the lease first and re-reading immediately before zone deletion — rejected because a mismatch would leave the transfer irrevocably in `source_deleting` with an intentionally preserved source and no cancellation path. Treating the server lease as sufficient — rejected because it has no authority over participant writes.

**Rationale**: The full-graph comparison converts the widest known silent-loss window into a safe retry while preserving the state machine's rule that every fallible content check happens before the point of no return. Stage D must provide asset observations to this new fifth digest site before CKAssets ship.

## 2026-08-18 — Pin every external CI action before granting cross-repo read access (seedkeep-27d.23.1)

**Context**: CloudKit schema parity CI adds a read-only SSH deploy key for the private umbrella repository. The workflow still referenced `actions/checkout@v5` and `maxim-lobanov/setup-xcode@v1`; either major tag can move, so a compromised upstream tag could run changed code in the job that receives the key. GitHub documents a full commit SHA as the only immutable external-action reference.

**Decision**: Pin all five external action uses to their verified current upstream commits while preserving behavior: `actions/checkout` v5.1.0 at `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09`, and `maxim-lobanov/setup-xcode` v1.7.0 at `ed7a3b1fda3918c0306d1b724322adc0b8cc0a90`. Keep version comments beside the SHAs. `scripts/check-ci-action-pins.sh` rejects mutable or abbreviated external refs, and its regression suite validates safe, mutable-tag, short-SHA, quoted, local-action, and actual-workflow cases.

**Alternatives considered**: Keep trusted major tags (rejected because trust does not make a movable tag immutable); upgrade checkout to another major while pinning (rejected as unrelated behavior change); use release-specific tags (rejected because repository tags can still move unless the upstream release is explicitly immutable).

**Rationale**: The workflow should not grant a private-repository credential to code selected by a mutable name. Full upstream SHAs make the executed action content reviewable and reproducible; the local policy check prevents an accidental regression while version comments keep updates discoverable.

## 2026-08-21 — Omit the APNs entitlement until push-driven synchronization exists (seedkeep-alm)

**Context**: The V1 App Store target still declared `aps-environment: development`. Seedkeep uses local notifications, including the time-sensitive entitlement, but has no `registerForRemoteNotifications` path. Both production `HouseholdCloudCoordinator` factories configure `CKSyncEngine` with `automaticSync: false`, so the app does not rely on silent push delivery. Leaving a development APNs declaration in an App Store archive advertises an unused capability and can conflict with distribution provisioning.

**Decision**: Remove `aps-environment` from canonical `project.yml` and the generated `Seedkeep.entitlements`. Preserve `com.apple.developer.usernotifications.time-sensitive: true` and `com.apple.developer.icloud-container-environment: Production`. Reintroduce `aps-environment: production` only in the same change that adds a real remote-notification registration or push-driven CloudKit synchronization path, with provisioning and physical-device verification.

**Alternatives considered**: Change the value directly to `production` now — rejected because there is no runtime consumer and it expands the declared capability surface. Keep `development` because the entitlement is inert — rejected because an unused development capability does not belong in the release archive. Remove time-sensitive notifications too — rejected because that independent entitlement is actively used by local frost, heat, and watering alerts.

**Rationale**: Minimum release entitlements are easier to audit and sign. Omitting APNs accurately describes current behavior while retaining every capability Seedkeep actually uses; the focused release-entitlement regression makes a future push implementation revisit this decision deliberately.

## 2026-08-28 — Recover unreadable fetched CKAssets by exact record identity (seedkeep-27d.32)

**Context**: A fetched `CKAsset` URL is temporary and can become unreadable before its bytes reach Seedkeep's durable cache. The surrounding record batch may still project and advance the CloudKit cursor; a later incremental sync then cannot redeliver that unchanged photo. The former cache-miss callback only requested another incremental sync, and its regression fixture hid the gap by writing cache bytes inside the callback.

**Decision**: Materialize every fetched photo asset inside one non-suspending MainActor receive step before the engine callback returns. If one asset is unreadable, persist its scope-specific record name, still project its metadata shell and unrelated records, and permit the batch checkpoint. On a later cache miss, fetch that exact `CKRecord.ID` through a generation-fenced `HouseholdRecordSyncing.fetchRecord`, materialize its asset, and clear the recovery roster only after durable success. Keep failures queued; clear names on confirmed local or remote deletion and purge the roster with account cleanup. Fence both receive and direct-recovery paths against account-generation changes, and fail exact recovery closed while the durable account-cleanup latch is set, so old-account bytes cannot reappear after a wipe or failed cleanup.

**Alternatives considered**: Reject and rewind the whole fetched batch (rejected because one persistently unreadable asset would wedge unrelated household changes); retry incremental fetch (rejected because an advanced cursor does not redeliver an unchanged record); treat the shell as permanently complete (rejected because the photo becomes unrecoverable on that installation); let the cache-miss callback populate test bytes directly (rejected because it does not exercise the production path).

**Rationale**: Record identity survives cursor advancement, while temporary asset URLs do not. A small durable retry roster preserves forward progress for the batch without silently abandoning photo bytes, and the generation/epoch fences preserve the existing account-switch privacy boundary.
