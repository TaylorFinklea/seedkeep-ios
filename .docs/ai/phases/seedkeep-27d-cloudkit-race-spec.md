# CloudKit Account-Change Race Hardening

## Goal

- An old iCloud account's in-flight fetch cannot project into or export from the replacement account's local garden.
- Incomplete local cleanup fails closed and is retried through the existing Settings error + “Sync now” path.

## Scope

- Fence `HouseholdCloudCoordinator` startup, fetch/apply, migration, and push transitions with the active account epoch.
- Tag queued fetch callbacks with the epoch that started their pass; discard stale entries rather than applying them later.
- Replace best-effort coordinator wipe operations with throwing cleanup and observable blocked/retry state.
- Persist a cleanup-pending latch before the MainActor account-change hop; a relaunch must finish the
  wipe before any replacement-account CloudKit work.
- Add deterministic Swift Testing coverage for owner and participant gated fetches plus injected cleanup failures and recovery.

## Boundaries

- Retain the existing `@MainActor` coordinator and `PendingApplyBuffer` locking pattern; do not introduce app-wide coordinator recreation.
- Reuse the Settings CloudKit error surface and “Sync now” retry affordance; no new UI flow.
- Do not alter server-sync, sharing, or feature-flag policy.

## Acceptance

- A fetch suspended before an account switch cannot repopulate SwiftData or cause an export after it resumes.
- Failed row or outbox cleanup prevents all subsequent fetch, migration, and push work until a complete cleanup retry succeeds.
- A process death during or immediately before cleanup relaunches blocked; the latch clears only after
  rows, outbox, engine token, and synced-state cleanup all succeed.
- Existing owner and participant behavior remains green.

## Verify

```bash
xcodebuild test -project /Users/tfinklea/git/seedkeep-ios/Seedkeep.xcodeproj -scheme Seedkeep -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
