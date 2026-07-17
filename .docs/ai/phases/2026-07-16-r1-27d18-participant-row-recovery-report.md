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
- Share to garden re-homes the live row in place when one exists, else recreates it atomically via
  `ParticipantRowRecovery.recreateFromSnapshotAtomically` (minting a fresh `journal_local_` id; the
  original FK is intentionally not reattached — it never resolved into the owner-zone garden by
  definition).
- `ParticipantRowRecoveryTests.swift` — 12 tests covering all 10 spec invariants (two are the
  spec-marked repro tests; empirically verified to fail when the migration call is stashed out).
- ADR appended to `.docs/ai/decisions.md` (2026-07-16) recording the FK-evidence rule, why
  timestamps were unusable, and the snapshot-registry survivability design.

## Hardening pass (2026-07-16, bead `seedkeep-27d.18.1`)

Two adversarial reviews of the original commit (`87196cc`) found three gaps, closed here without
touching `flushPending`, `wipeHouseholdSwiftData`, or the migration's core disposition logic:

1. **Atomic share-recreate.** The original post-wipe path in `AppEnvironment.shareJournalRecoveryItem`
   called `JournalStore.create` + one `addChecklistItem`/`updateChecklistItem` pair per snapshot row +
   `ParticipantRowRecovery.markShared`, each its own `ModelContext` + `save()`. A save failure after
   `create` succeeded left the registry item `pending` while a `journal_local_` entry already existed;
   a retap of the (unconditionally re-enabled) Share button would recreate a SECOND entry, duplicating
   content in the owner zone. Fixed with a new `ParticipantRowRecovery.recreateFromSnapshotAtomically`
   that inserts the entry + every checklist item + flips the registry item to `shared` in ONE
   `context.save()`, mirroring `runIfNeeded`'s existing `saveOperation` DI seam for failure injection.
   **Placement: `ParticipantRowRecovery`, not a new `JournalStore` method** — `ParticipantRowRecovery`
   already owns the snapshot format (`EntrySnapshot`) and already sets the precedent of a multi-row
   atomic save in `runIfNeeded` (rehomes + registry insert in one `context.save()`); `JournalStore`'s
   CloudKit-authoring convention is the opposite — one entity, one `ModelContext`, one `save()` per
   call, with no existing multi-entity-atomic-save idiom to mirror, and its per-call guard chain
   (`validateParentScope`/`requireActiveEntry`) doesn't apply here since the FK is intentionally left
   nil on recreate. Test: `atomicRecreateRetryAfterInjectedFailureProducesExactlyOneEntry` — injects a
   save failure, confirms nothing persisted and the item stayed `pending`, then retries successfully
   and asserts exactly ONE entry exists.
2. **Scope re-validation (defense-in-depth).** `shareLiveEntryIfPresent`/`markShared`/`keepPrivate`
   (and the new `recreateFromSnapshotAtomically`) now take a required `currentScopeKey` and refuse
   (throw `SeedkeepError(code: "scope_mismatch", ...)`, no mutation) when the registry item's own
   `scopeKey` doesn't match it — protecting against a stale/foreign-scope item reaching these actions
   from a future call site or a captured item across a garden switch. `AppEnvironment`'s wrappers
   (`shareJournalRecoveryItem`, `keepJournalRecoveryItemPrivate`) re-derive the current scope from
   live auth state on every call. Test: `scopeMismatchRefusesAndMutatesNothing` — item with scopeKey
   `"O1|S"` invoked under scope `"O2|S"` for all three actions → each throws, nothing mutated.
   **Accepted consequence (no code change):** a stale cross-scope registry item survives (it is never
   deleted) but stays unreachable through the UI unless that exact garden (`ownerZoneHouseholdID`) is
   re-adopted, since `participantRecoveryScopeKey`/the review sheet only ever filter and act on the
   CURRENT scope.
3. **Tombstone filter.** The quarantine loop in `plan()` no longer registers an already soft-deleted
   (`deletedAt != nil`) ambiguous entry — previously the inbox would offer to "Share" an already-deleted
   entry, and the share path would resurrect it. Now such entries get NO registry item and are left
   completely untouched (not destroyed, not re-homed, not registered). FK-evidenced entries continue to
   re-home with an intact tombstone regardless (unchanged). Test:
   `strandedTombstonedNoFKEntryIsNotRegisteredAndStaysParked`.
4. **Test honesty rename.** `flagOffEquivalentGuardIsNoOp` → `sameIDGuardIsNoOpForAFlagOffEquivalentValue`,
   with a comment clarifying it does NOT exercise the flag-OFF call site (`AppEnvironment` is
   un-instantiable in this suite) — the real gate is `AppEnvironment.swift:227-243`.
5. **Byte-identity breadth.** Added `rehomePreservesPlantingEventFieldsIncludingNeverSyncPetColumns`
   (full-field preservation for `LocalPlantingEvent`, including the never-sync
   `petWiltedStreakDays`/`petLastMoodTickAt` columns) and `fkEvidencedRehomePreservesJournalEntryFields`
   (full-field preservation for a `LocalJournalEntry` re-homed via FK evidence), alongside the existing
   `LocalSeed` coverage.

`shareRecreatesFromSnapshotPostWipe` (invariant 8) was updated to exercise the new atomic function
directly instead of hand-rolling the superseded `JournalStore.create`/`addChecklistItem` sequence, since
that sequence is no longer the production code path.

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

### Hardening pass verification (2026-07-16)

- `ParticipantRowRecoveryTests` grew from 12 to 17 tests (the 5 hardening tests above).
- Full bead `verify_cmd` (`xcodebuild test`, no skips): 458 tests across 49 suites passed (up from
  the 453/49 baseline by exactly the 5 new tests).
- `scripts/test-gate.sh --simulator-udid FDDFB511-272B-40DD-8927-5E71311E96BA`: SeedkeepKit package
  70 passed, SeedkeepCloudKit package 67 passed, legacy CloudKit-OFF app tests 458 passed (49
  suites), production-default CloudKit-ON contract 1 passed — all required tests passed, all green.
