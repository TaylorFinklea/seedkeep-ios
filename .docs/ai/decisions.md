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

## [2026-04-30] Household auto-create on first sign-in

**Context**: After Sign in with Apple, the user has zero households. We can either gate the rest of the app on a "Create or join household" wall, or auto-create one and let them invite later.

**Decision**: Auto-create. `AuthController.loadIdentity()` calls `POST /api/households` (idempotent on the server side) right after `/api/me`. The server returns the existing household if there's already a membership.

**Alternatives considered**: Onboarding wall with create/join choice.

**Rationale**: Phase 1's primary user is the solo gardener replacing a Google Sheet. They shouldn't see a screen explaining a household before they see seeds. The household is invisible plumbing until they create an invite.
