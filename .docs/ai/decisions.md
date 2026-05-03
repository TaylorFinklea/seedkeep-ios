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

## [2026-04-30] Household auto-create on first sign-in

**Context**: After Sign in with Apple, the user has zero households. We can either gate the rest of the app on a "Create or join household" wall, or auto-create one and let them invite later.

**Decision**: Auto-create. `AuthController.loadIdentity()` calls `POST /api/households` (idempotent on the server side) right after `/api/me`. The server returns the existing household if there's already a membership.

**Alternatives considered**: Onboarding wall with create/join choice.

**Rationale**: Phase 1's primary user is the solo gardener replacing a Google Sheet. They shouldn't see a screen explaining a household before they see seeds. The household is invisible plumbing until they create an invite.
