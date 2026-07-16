# CloudKit Account-Change Race Hardening — Report

## Delivered

- Tagged fetched callback batches with their armed account epoch; stale batches are discarded before projection.
- Fenced coordinator startup, fetch/apply, migration, and push continuations across account changes.
- Made household SwiftData, outbox, engine queue, and durable-state cleanup fail closed; incomplete cleanup blocks CloudKit work and retries through Settings “Sync now”.
- Synchronously fence account-change callbacks before their MainActor cleanup task, and retire stale engine delegates after queue reset.
- Added a write-ahead cleanup marker beside the engine token so a crash or failed wipe relaunches blocked;
  it clears only after the complete cleanup transaction succeeds.
- Kept `.signIn` notifications on the active epoch; only sign-out and account-switch events invalidate it.
- Added an engine lifecycle gate so saves, deletes, batches, sends, and stale delegate events cannot stage
  into the replacement CKSyncEngine until cleanup explicitly rearms it.
- Made shared-garden adopt/leave preserve their current state when cleanup fails.
- Added deterministic owner and participant gated-fetch tests, injected fetch/save cleanup-failure retries,
  relaunch latch recovery, sign-in continuity, production lifecycle-gate coverage, and migration-drain account-switch tests.

## Verification

- Focused `HouseholdCloudCoordinatorTests`: 43 passed.
- `SeedkeepCloudKit` package: 67 passed.
- Full required `xcodebuild test`: 441 tests across 48 suites passed.
