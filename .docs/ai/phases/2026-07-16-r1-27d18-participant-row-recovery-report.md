# Participant Row Recovery (R1 27d.18) — Report

## Delivered

- `ParticipantRowRecovery` (`Seedkeep/Core/CloudKit/ParticipantRowRecovery.swift`): pure `plan()`
  (candidate rows in → rehome/quarantine disposition out, host-testable with no container) plus a
  small runner. Five queue-backed types (seeds, beds, planting events, tags, locations) re-home
  unconditionally; a journal entry re-homes automatically only when its FK resolves into the
  owner-zone garden AFTER the five-type re-home (pre-existing owner rows ∪ rows just re-homed this
  same pass); everything else journal-shaped is quarantined with a faithful snapshot.
- New SwiftData model `LocalJournalRecoveryItem` — durable review-inbox registry, in
  `SeedkeepSchema.all` (wiped on sign-out) but deliberately outside
  `HouseholdCloudCoordinator.wipeHouseholdSwiftData`'s fixed 10-type list, so it survives a future
  adopt wipe.
- Trigger wired into `AppEnvironment.syncIfPossible()`'s participant branch, before the sync pass;
  durable one-time marker `seedkeep.ck.recovery27d18.<env>.<scopeKey>` written only after the atomic
  `context.save()` succeeds. Fires `noteHouseholdMutation()` on a successful run so re-homed rows
  push immediately.
- Review inbox UI: Settings ▸ CloudKit section participant branch gets a "Journal items need review
  (N)" row (visible only while pending items exist for the current scope) opening
  `JournalRecoveryReviewView` (mirrors `PendingWritesView`'s list idiom) with per-item Share to
  garden / Keep private plus a bulk Keep-all-private action.
- Share to garden re-homes the live row in place when one exists, else recreates it from the
  snapshot through `JournalStore`'s existing CloudKit authoring path (minting a fresh
  `journal_local_` id; the original FK is intentionally not reattached — it never resolved into the
  owner-zone garden by definition).
- `ParticipantRowRecoveryTests.swift` — 12 tests covering all 10 spec invariants (two are the
  spec-marked repro tests; empirically verified to fail when the migration call is stashed out).
- ADR appended to `.docs/ai/decisions.md` (2026-07-16) recording the FK-evidence rule, why
  timestamps were unusable, and the snapshot-registry survivability design.

## Mandatory gate

Verified via git history at commit `637a9c2` (build 49): `LibraryView`/`GardenView`/
`LocationsView`/`TagsView` only call `appEnv.syncIfPossible()` (refreshable) or
`appEnv.sync.flushPending()` (push-only) — no direct server-import call. `SyncEngine.syncAll`
guards all 7 household pull feeds (including the five types) behind `if !cloud`, landed in
`ed7e89f` before the default-ON cutover `d0fc7c0`. No view-driven server import path existed for
the five types under CloudKit-ON in builds 47–49 — no STOP condition.

## Verification

- Focused `ParticipantRowRecoveryTests`: 12 passed (including empirical repro-fail check on the two
  marked tests with the migration call stashed out, then restored).
- Focused `HouseholdCloudCoordinatorTests` (flagged as a one-off flaky test-runner crash mid-gate,
  unrelated to this change): 43 passed in isolation.
- `scripts/test-gate.sh --simulator-udid FDDFB511-272B-40DD-8927-5E71311E96BA`: SeedkeepKit package
  70 passed, SeedkeepCloudKit package 67 passed, legacy CloudKit-OFF app tests 453 passed (49
  suites, up from the 441/48 baseline by exactly the 12 new tests), production-default CloudKit-ON
  contract 1 passed — all required tests passed.
- Full bead `verify_cmd` (`xcodebuild test`, no skips): 453 tests across 49 suites passed.
