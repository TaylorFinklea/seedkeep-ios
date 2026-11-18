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

## 2026-10-20 — The iCloud account is the identity; no Seedkeep server (N1)

**Context**: The Fly server was stopped on 2026-10-15, and the owner chose an Apple-only app (umbrella `decisions.md` [2026-10-20]). Garden data already lived in CloudKit, but sign-in, `/api/me` and the server-minted household ID (which names the zone `seedkeep-<householdID>`) still gated entry.

**Decision**:
- `AuthController` resolves the iCloud user (`CKContainer.userRecordID()`) and the user's own household from CloudKit zones. It still publishes `.signedIn(user:household:)`; a shared garden stays the participant marker.
- Existing installs rebind their cached server identity to the iCloud user in place, crash-safely, keeping household ID, cursors, markers and pending writes. Nothing is wiped unless the iCloud user is confirmed different, or the user confirms a chooser discard. A chooser discard uses a narrower garden-switch eraser that keeps device-only recovery items.
- A new account with no garden gets a household ID derived from its iCloud user record name, so devices bootstrapping together converge. Ambiguity (several gardens, a missing device garden, an unavailable shared garden, own plus one shared garden) is always a chooser, never a guess.
- CloudKit work runs only on a verified identity with no paused account-deletion checkpoint (`AppEnvironment.canUseCloudKit`). It stops at pass boundaries when that changes. Share adoption re-checks the identity and a pending-share epoch after every await.
- The server is unreachable by construction: `SeedkeepClient` uses a refusing transport, and server-only features are gated off and hidden (`ServerRetirement`).

**Alternatives considered**: Keep Sign in with Apple as a gesture (no benefit without a server); a pointer record naming the active garden (needs a CloudKit schema deploy, and cannot pick between legacy zones); recency-based zone adoption (cannot prove which zone is current).

**Rationale**: CloudKit already held the data. Making the iCloud account the identity removes the last server dependency without a schema change and without touching existing users' data.

## 2026-10-20 — On-device climate, recommendations and scanning (N2)

**Context**: With the server retired (N1), home location, planting windows, packet scanning and random pick had no backend.

**Decision**:
- Bundle a ZIP → coordinates + USDA zone table (built from the server's `zip_locations.csv` by `scripts/build-climate-resources.py`) and a zone → frost-date table. Home location is ZIP only, offline, stored per device.
- Port the server's rule baseline and projection to Swift exactly, computed on read per seed from its growing-info snapshot and the user's local date. Drop the AI fallback and the unreviewed extension calendars.
- Scans save locally; both packet photos become seed photos with stable IDs, through scoped, resumable staging.

**Alternatives considered**: CoreLocation (needs a permission prompt; ZIP is enough); keeping the server catalog for barcode lookup (needs a server); persisting recommendations in `LocalRecommendation` (stale by design; it stays unused until N3 removes it).

**Rationale**: Everything these features need fits on the device. The same inputs give the same windows as the server, without hosting.

## 2026-10-20 — Workbench components, contrast rules and a debug sample garden (R2a)

**Context**: The owner chose one look, Workbench everywhere, with no Herbarium flourishes (umbrella `decisions.md` [2026-10-20]). Herbarium fonts never scaled with Dynamic Type, and its colours mixed status and text.

**Decision**:
- Live screens use `Font.wb*` (built on system text styles) and the `WB*` components. Herbarium code stays compiled until N3, only in dead files, hidden features and the screens R2b migrates. `HerbSpace` counts as layout and stays until N3.
- Text is `WBColor.ink` or `muted`. Verdict and warn colours mark icons, dots and bars, never text. Interactive labels may use `accent`. `faint` is decoration only.
- Touch targets use `WBMetrics.minTouchTarget`: 44pt on iOS, intrinsic size on Mac.
- The planting chart compares the user's local day, read in Gregorian and rebuilt at UTC midnight (`RecommendationPanel.plannedDay`), with its UTC anchor. That's the day the picker shows and the day that's saved, whatever the system calendar.
- A `#if DEBUG` sample-garden mode (`-SeedkeepFixture`) gives screenshot runs an in-memory garden with CloudKit off. It fails closed outside a debug, non-test run, and the release archive check rejects it.

**Alternatives considered**: Keeping Herbarium on iPhone (the owner chose one look); restyling everything in one phase (Sol judged it too large, so R2 is split into R2a, R2b and R2c); screenshotting against the owner's real garden (personal data, and it needs a signed iCloud build).

**Rationale**: Text that scales and readable contrast are release requirements. Shared components keep the three phases consistent, and the sample garden makes visual review repeatable.

## 2026-10-20 — Settings replaces the You tab; one Seeds model on every size (R2b)

**Context**: You held two live rows and a link to Settings; its server-era rows were already hidden. The iPhone Seeds grid kept its own search, grouping and counts in the view, with no tests, while iPad and Mac used R1's tested table model.

**Decision**:
- The compact tabs are Today, Seeds, Garden, Journal and Settings (`AppEnvironment.AppTab`). Both interfaces render `NavigationStack { SettingsContent() }` for Settings. YouView stays compiled but unreferenced until N3.
- The compact Seeds list uses `SeedTableRow` and R1's search. Its counts follow the search on every size. Its titles match iPad and Mac (Wishlist, Archived).
- Loading states use `AppEnvironment.isSyncingForDisplay`, an observed count of CloudKit passes plus the coordinator's flag. The legacy `sync.isSyncing` never turns on in the CloudKit path.
- At accessibility text sizes, side-by-side layouts (the daylight readings, due rows, seed rows, and the state filter as a menu) switch on `dynamicTypeSize.isAccessibilitySize`. `ViewThatFits` doesn't work for segmented controls, whose text doesn't grow.

**Alternatives considered**: Keeping You as a slim tab (two rows don't justify a tab); a separate iPhone list model (it would drift from R1's); `ViewThatFits` for every fallback (it misjudges segmented controls).

**Rationale**: Fewer roots, one tested model for seeds, and loading states that reflect the sync that actually runs.

## 2026-10-20 — Appearance, device preferences and contrast as tests (R2c)

**Context**: R2c turned on dark mode with a Light / Dark / System override, and its sample-garden screenshots needed real settings and notifications left alone.

**Decision**:
- The appearance (`seedkeep.appearance`) is a per-device preference, never synced. A view modifier at each window root applies it; `@AppStorage` on the `App` struct didn't re-render the scene.
- `DevicePreferences.store` is the one place this device's preferences live (the appearance, the What's New baseline, the notification toggles). Sample-garden mode uses the fixture suite and never touches the system notification center.
- Colours come from one `WBPalette` table, and tests check WCAG contrast for the real combinations, not just the tokens.
- The bed canvas is a to-scale drawing, so its text stops growing at `xxxLarge`. Each name stays in VoiceOver and in the events list. It's the only Dynamic Type cap in the app.
- On iPad, a Seeds layout too narrow for the table and the inspector starts with the inspector closed. Mac keeps the user's inspector state.

**Alternatives considered**: syncing the appearance through CloudKit (people expect it per device); scaling canvas labels without limit (they covered the plantings at accessibility sizes); the inspector rule on Mac too (most Mac windows would start without it).

**Rationale**: Dark mode and large text should work without surprises, and a fixture session must never change a developer's real device.

## 2026-10-21 — Garden grid editing limits (R3 G2)

**Context**: R3 replaced the bed canvas with a square-foot grid and new New/Edit bed sheets, without changing the sync path or the CloudKit schema.

**Decision**:
- A stored bed size can't be cleared. `UpdateBedInput` has no explicit null, and plain nil means "unchanged", so clearing a size blocks Save with an explanation. A new bed, or a bed with no stored size, can stay blank (no grid).
- "Place in bed" in Add Planting may pick a square that already holds a planting. Painting and Move refuse such a square, but "empty square" is a local UI rule (sync allows several plantings per square), and adding a harvest or note to a planted square is normal. The picker shows and speaks what the square holds.
- The sample garden keeps its ZIP's real frost dates; only its frost-flagged sowing's date follows the launch day.

**Alternatives considered**: an explicit null for bed sizes (`.some(nil)`, as planting events already use for `completed_at`), which changes the encoded patch, coalescing and the push path; refusing occupied squares in Add Planting.

**Rationale**: R3's invariant is no sync or schema change. Clearing a size is rare and can follow as its own change.

## 2026-10-21 — CSV import safety and Mac Settings scope (R4)

**Context**: R4 added a bulk CSV import that writes into a shared CloudKit garden, and a Mac Settings window outside the main window's scope handling.

**Decision**:
- One import runs per app (`SeedCSVImportCenter`), never orphaned by leaving the screen. It plans off the main actor and writes in short slices. Between slices it checks the garden and a fingerprint of every seed (id, `updatedAt`, deleted flag, identity fields), so any edit by any device forces a fresh preview. Each update also re-checks its target by id.
- Matching needs all four identity columns. Without them every row adds a seed, and the preview warns about re-importing after an interruption (the ledger is in memory).
- All-empty rows (`,,,`) and whitespace-only lines are skipped. Spreadsheets append them.
- `activeGardenHouseholdID` is observable across share adoption and leaving (`participantMarkerRevision`). The Mac Settings window keys its stack on it, so a garden change drops stale screens and drafts.
- A stored "Hosted" AI choice reads as Free (on-device), as before.

**Alternatives considered**: refusing all-empty rows as errors; a per-create identity re-check instead of a whole-garden fingerprint; a sync apply-generation counter (exact, but it touches the sync code).

**Rationale**: an import must not duplicate or overwrite seeds because of edits from another device in the meantime, and the checks have to stay cheap enough for a 5,000-row file.

## 2026-10-22 — Dead UI removed; correction-outcome reminders go too (N3 U)

**Context**: N3 retires the server. Slice U removes the screens and flows that only the server or the catalog-correction feature could reach.

**Decision**:
- The correction-outcome reminder goes with its Settings toggle. `CatalogCorrectionNotifier`, the catalog ping code in `NotificationsCenter` and `Names.swift` are deleted. The toggle controlled only those pings, so keeping them would leave outcome notifications with no switch.
- `SyncEngine.upsertCatalogCorrections` no longer posts or cancels notifications, and its `isInitialSync` flag is gone. Rows still land locally until slice T removes the pull.
- `CatalogFieldBounds` (the iOS mirror of the server's bounds), its `fieldBounds.canonical.json` resource and its parity test are deleted. Nothing reads them once the sheet is gone; the server keeps its own copy.

**Alternatives considered**: keeping the notifier and removing only the toggle, which would leave the pings on with no way to turn them off.

**Rationale**: the outcomes come from corrections filed on the server, which is being retired. Removing the switch and the pings together keeps the notification settings honest.

## Beads retired (2026-09-29)

Beads (`bd`) is no longer used. The cross-repo backlog lives in
`~/git/seedkeep/.docs/ai/roadmap.md`; this repo's older standalone Beads
backlog is archived in `beads-archive.jsonl` and its Backlog section here.
Earlier entries that mention Beads are historical.

## [2026-10-22] N3 A: delete leftover deletion files at launch, no classification

**Context**: Account deletion and garden transfer were removed with the server. Older builds could leave checkpoint JSON in `Application Support/AccountDeletion` and staged photo bytes in `HouseholdSync/TransferWorkspace`; N1 paused CloudKit while any checkpoint existed. A first design classified each checkpoint and erased the local store for some, but Sol showed that was unsafe without a guard against re-creating a deleted CloudKit zone (the coordinator re-provisions missing zones).

**Decision**: The owner confirmed no device ever started a deletion or transfer (umbrella decision 2026-10-22). `LegacyAccountDeletionCleanup` deletes both folders at launch, whatever they contain, before identity resolution. No erase, no identity or garden change; checkpoints no longer pause CloudKit. It is best effort, retried next launch, and inert under XCTest and in sample-garden mode. `PhotoByteStore.purgeHousehold` removes the legacy transfer folder without recreating it.

**Alternatives considered**: Classify checkpoints and erase or pause per role and phase (rejected: unsafe without the zone guard, and moot given the owner's answer); keep the quarantine until N2-E (rejected: no device needs it).

**Rationale**: Simplest safe behaviour for the real device population. The general "never recreate a zone this device has seen deleted" guard lands in N2-E.

## [2026-10-22] N3 T1: what deleting the server sync left behind

**Context**: T1 deleted `SeedkeepClient` and the server sync. Production already ran CloudKit-only, so the deletions were meant to change no live behaviour.

**Decision**:
- Where a method had a server branch and a CloudKit branch (JournalStore, SyncEngine photo upload/fetch), the CloudKit body is kept as is, rather than adding a new error for the flag-off case.
- `SyncEngine.enqueue*` no longer create `LocalPendingWrite` rows. The model and existing rows stay; nothing reads or sends them.
- `JournalStore.refresh` stays as a no-op, so the Journal's pull-to-refresh and `.task` calls are unchanged.
- The pet depart RPC and its wilted/departed notifications are gone. They had been gated off since N1, and pets are hidden.
- The `seedkeep.serverURL` and `seedkeep.cachedTier` UserDefaults values are no longer read and are not cleaned up.
- `KeychainTokenStore` has no default account. `legacyBearerTokenAccount = "bearer-token"` names the item the legacy rebind deletes, and a test pins it.
- The flag collapse (`cloudKitHouseholdSyncEnabled`, `serverGardenFeaturesRestricted`, `SEEDKEEP_TEST_CLOUDKIT_ON`) moves from F to T2, so the tests move to the CloudKit path once.

**Alternatives considered**: Keep the flag-off branches until F (rejected: they describe a configuration no user can reach, and would be migrated twice).

**Rationale**: The smallest deletion that keeps every shipping path identical. The pre-N3 store fixture (generated at c632a33) guards the on-disk store against later model removals.

## [2026-10-22] N3 T2: tests run the shipping CloudKit path through a coordinator factory

**Context**: Until T2 the unit-test host defaulted `FeatureFlags.cloudKitHouseholdSyncEnabled` to OFF, a configuration no shipping build could reach, and the full suite ran only in that mode. With the flag removed, a test with a verified identity would build a real `HouseholdCloudCoordinator` and reach CloudKit.

**Decision**: `AppEnvironment` builds its coordinators through `CloudCoordinatorFactory`. The app uses `.live`; `makeForTesting` requires an explicit factory (no default), and tests pass `FakeCloudCoordinators`, which builds coordinators over the fake engine with no provisioner and no state URL and records what it built. The flag, its stored kill-switch and `SEEDKEEP_TEST_CLOUDKIT_ON` are gone; `ProductionPathTests` always compiles. Under unit tests a coordinator's one-time migration marker still lives in `UserDefaults.standard`, so suites that build coordinators remove the markers for every household they built.

**Alternatives considered**: Keep the OFF default for tests and add an ON lane (rejected: it tests a mode no user has); give `makeForTesting` a default factory (rejected: a test could fall back to live CloudKit by accident).

**Rationale**: The tests now exercise the code users run, and the required factory argument makes reaching real CloudKit from a test a compile error rather than a convention.

## [2026-10-22] N3 F: the release verifier forbids Sign in with Apple; zero transport is checked on the built app

**Context**: F removed the last server configuration: the `SeedkeepAPI*` Info.plist keys and the Sign in with Apple entitlement. `scripts/verify-release-archive.sh` required that entitlement, so every release would have failed. The contract asked for a structural "zero server transport" test.

**Decision**: The release verifier now fails an archive that carries `com.apple.developer.applesignin`, as it already did for `aps-environment`. `ZeroServerTransportTests` runs in the hosted app on iOS and macOS: the app's Info.plist (checked to be the app's, by its `KeychainService` key) has no `SeedkeepAPI` key or server host, and the app executable and the dylibs beside it carry no `fly.dev` or `seedkeep-server` string. Entitlements are checked only on signed archives, because gate builds are unsigned. A scan save's "stays local" proof is now that structural test plus "no `LocalPendingWrite` rows". The Sign in with Apple App ID capability is removed by the owner (runbook).

**Alternatives considered**: A source grep for server names (rejected: it checks text, not what ships); checking entitlements in the unit test (rejected: the unsigned test host has none to read).

**Rationale**: The checks run against what ships, and a release cannot regain the entitlement unnoticed.


## [2026-11-05] N2-E guard authority, journal lifetime and local copy policy

**Context**: G1 and G2 landed before the website experiment; G3 resumes the
approved October 22 contract. This records their implementation choices and
the owner's accepted copy behavior. G3 is local commit `cf64db0`; automated
results and remaining acceptance limits are in the contract's Results.
`seedkeep-ios-eee` tracks this resumption; accessibility triage remains open
as `seedkeep-ios-65p`.

**Decision**:
- The account-keyed guard binding is authoritative over cached identity and
  participant defaults. Resolve the verified account and any different-account
  wipe before repairing defaults. A cleared binding retains the cached local-
  store owner until a successor bind or complete wipe commits; it routes to
  fresh discovery and never reopens the cleared cached garden. A newer binding
  supersedes an older open
  journal's target; never replay an obsolete target.
- A completed or superseded journal stays until a later launch confirms the
  defaults against the latest binding. A kept copy also waits for its creation
  grant to be consumed. An open failed journal stays durable for retry.
- Discard clears the binding and then re-runs session resolution, which can
  select an existing garden, show the chooser or grant a fresh garden ID.
- Quiesce and await scan resumption and weather refresh before journal effects.
  Account/store replacement must cancel and await journal tasks before erasing
  local data. The originating identity transition supplies a synchronous
  validity permit, checked immediately after the wait before destructive
  effects. Execution must validate verified account and scope ownership
  after suspension; unfinished journals continue to fence writes after failure.
- A failed gone-record commit fences that account/garden in memory for the
  process. It does not block another account using the same shared garden ID.
- Permission and ambiguous save failures hold the current send pass and retain
  queued records for a later pass, without a permanent retry cap. They do not
  prove deletion. Creation abandonment has its separate three-in-24-hours cap.
- During Keep and silent re-home, seed and journal photo rows with absent or
  hash-invalid local bytes are dropped in the same SwiftData save as row
  re-homing. The choice-screen missing count uses the same eligibility rule.
  The kept garden does not retain a missing-photo placeholder. Enumeration
  errors stop copying before its checkpoint; they never mean an empty photo
  list. Inventory errors keep Keep disabled and offer a count retry.
  Pending recovery entries still present locally use their actual source
  households for photo copying and the same unavailable-photo disclosure.
  Missing children are deleted in the save that moves their parent and marks
  the recovery item shared. Private/kept and unrelated recovery items stay;
  snapshot-only items do not imply orphan photos.
- After Keep or Discard of a shared garden, that ID stays retired for this
  account on this device, including after another invitation. Discovery,
  stale chooser results and both platform share-adoption paths must enforce
  it before replacing the current garden. Retirement is local, not synced.
- Initial launch resume preserves a silent re-home already started by legacy
  binding. True account/binding and journal start/end transitions invalidate
  epochs; launch resumption adds no redundant invalidation over that journal.

**Rationale**: A deleted garden must not be resurrected, partial copy work must
not admit competing writes, and a journal for one account must never mutate
another account's local store. The seven owner-accepted residual limits remain
in the contract. This does not add in-app deletion of all iCloud data.

## [2026-11-05] Resume project-local task tracking without importing the archive

The current working agreement restores Beads for actionable tracking. A fresh
embedded project-local Dolt store is local-only with no remote; the retired
20-row export and older Markdown roadmap are preserved without import. Earlier
tracker retirement and issue statuses remain historical. The umbrella roadmap
continues to hold product direction; Beads holds current actionable work.

## [2026-11-09] Match navigation shortcuts to sidebar order

The owner reported that ⌘4 and ⌘5 were opposite to the visible sidebar order
and requested numbered hints while holding Command. The historical choice
that kept Journal on ⌘4 is superseded: Today, Seeds, Garden, Windows and
Journal use ⌘1 through ⌘5 in displayed order. Settings keeps its separate ⌘,
window. The shared Go-menu mapping also supplies the Mac sidebar hints.

On Mac, SwiftUI modifier-key handling reveals the numbers while Command is
held in the active window. Scene/window inactivity and disappearance clear
the hints; no event monitor, new permission or global keyboard setting is
needed. Other sidebar content, selection behavior and seed-count labels stay
as before. Verification and limits are recorded in the R5 local acceptance plan.

## [2026-11-09] Bridge successful numeric edits until the row feed catches up

A traced Mac table race cleared a successful draft before SwiftData delivered
the updated row. The old fallback then entered the text binding as a new
draft and masked the saved value. The window's existing `SeedEditing` object
now receives the current row projection and retains a normalized, confirmed
save until that row acknowledges it or a superseding row arrives. Genuine
active input wins over this handoff value. Unchanged native setter echoes
are no-ops; changed input remains editable.

Undo/redo releases pending handoffs, including an undo coalesced before a row
feed update. Cancel retains a successful save while dropping only active
input. Scope reset and departing rows clear the corresponding transient
state. Writes and their garden fence continue through the existing writer.
Regression tests and real sample-app Return/Escape/blur/undo/redo checks are
recorded in the R5 acceptance plan.

## [2026-11-16] Roshar test without backup or pre-upgrade comparison

The owner explicitly waived the recent-backup prerequisite for this device
test and approved the prepared in-place update despite unknown old source,
iCloud environment/account comparison and recovery state. When the old app
could not pass Apple sign-in, the owner separately approved proceeding if a
pre-upgrade garden baseline was unavailable. Temporary Sel-only direction
was superseded by explicit Roshar availability; Sel was left stopped.

These are bounded test decisions, not permission to uninstall/clear data,
choose Reset/Keep/Discard, edit a garden, switch accounts or release. They
do not establish data preservation or waive release acceptance. The observed
post-update/relaunch samples and the unresolved photo are recorded in
`plans/2026-11-16-roshar-update-check.md`.

## [2026-11-16] Preserve the current photo file by directory-entry name

`PhotoByteStore.write` compares candidate filenames within its one enumerated
directory, rather than comparing complete URL objects. Foundation can return
equivalent file locations using unequal URL representations; the old cleanup
could therefore remove the file it had just published. Standardization alone
did not cover every tested symlink case. Filename comparison preserves the
current content-addressed file while removing prior versions for that record.
Production environment/lifetime/household paths remain the default; a scoped
internal directory seam supports isolated real-filesystem regression tests.

The owner authorized this fix and its Sel test. Focused cache tests passed on
iOS/Mac, and the original Sel photo rendered with matching persistent bytes
across a controlled relaunch. Code/artifact/device evidence received separate
native Terra review. Detailed results and limits are in
`plans/2026-11-16-photo-loading-diagnosis.md`; work is tracked by
`seedkeep-ios-8ii`. This does not change photo rows, the deleted-garden contract
or release approval boundaries.

## [2026-11-17] Sort row indices while preserving table comparison rules

The Seeds table precomputes its sort values as before, but sorts original-array
indices instead of moving complete `SeedTableRow` snapshots. The synchronous
call keeps the input array unchanged and projects complete rows at the end.
Indices and keys live only for that call; no cross-call cache or data-model
change is introduced. Localized comparison, blanks-last rules, comparator
priority and ascending ID ties remain in place.

The owner approved resolving the timing gate under `seedkeep-ios-219`.
Paired warm synthetic measurements supported the smaller sort representation;
the original 1,000-seed workload and 50 ms assertion remain unchanged. The
measurements do not prove historical failure cause or general load reliability.
Actual focused/main checks and their limitations are recorded in
`plans/2026-11-17-seed-table-timing.md`.

## [2026-11-17] Keep the strict timing check separate from functional concurrency

The R1 1,000-seed workload remains a mandatory, one-shot, under-50-ms wall-clock
check. A dedicated XCTest case runs before Swift Testing in the tested SDK's
harness, while functional tests retain their parallel execution. The existing
ten-row warmup now initializes mapping and both sort paths; the measured full
workload and strict assertion are unchanged. This measures warmed operations,
not first-use latency, and does not replace the separate manual scroll check.

App gates require positive counts from both frameworks so a lone benchmark
cannot mask missing functional tests; package-mode count behavior remains as
before. Earlier failed checks remain in the timing report, and their historical
cause is not inferred. Source and gate reviews plus actual framework counts
and final validation are recorded in `plans/2026-11-17-seed-table-timing.md`.

## [2026-11-17] Use OS 27 evidence for the current compatibility pass

After the minimum-OS preflight found only OS 27 environments and limited
local storage, the owner answered “os 27 is good enough.” This pass therefore
uses the existing OS 27 regression/runtime evidence and 26.0 build/link
metadata. The declared iOS/macOS 26.0 floors remain unchanged; actual OS 26
execution is untested and is not represented as passing. No runtime download,
VM, cache cleanup or floor change is part of this decision. Broader R5 and
release approval remain separate. Evidence: `plans/2026-11-17-minimum-os-26.md`.
