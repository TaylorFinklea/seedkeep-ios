# R1 27d.18 — Participant stranded-row recovery (evidence-gated + review inbox) — SPEC (LOCKED)

Bead: `seedkeep-27d.18` (umbrella repo beads). Product policy: umbrella `decisions.md` 2026-07-16
"Ambiguous pre-fix participant journal rows recover via evidence gating plus a review inbox"
(hdeck `seedkeep/20260715-participant-journal-recovery`).

## Problem

Default-ON builds 47–49 (post `d0fc7c0` 2026-06-29, pre `b0c2eee`/`ed409ff` 2026-07-15) stamped
participant-created garden rows with the **signed-in server household ID** instead of the adopted
owner-zone household ID. `HouseholdMigrationPlanner.fetchInput` filters by `householdID`
(`Seedkeep/Core/CloudKit/HouseholdMigrationPlanner.swift:73-79`), so those rows are excluded from
the CloudKit export forever, and journal children are excluded transitively (`:83-91`).
Additionally, pre-fix `JournalStore` both authored to and refreshed from the parked solo Postgres
feed under the same signed-in ID, so stranded journal/checklist rows have two indistinguishable
origins (authored vs imported).

## Decision constraints (fixed, from the ADR)

- Five queue-backed types (**seeds, beds, planting events, tags, locations**) re-home automatically.
- Journal entries + checklist items move ONLY with trustworthy post-adoption evidence.
- Every ambiguous row is quarantined, hidden from the shared garden, surfaced in a one-time review
  inbox where the user chooses; nothing destroyed; collisions fail closed with recoverable evidence.
- Owner mode, flag-OFF rollback, and the participant parked solo CloudKit zone stay untouched.

## Evidence rule (spec-derived, exact)

A stranded row = `householdID == signed-in server household.id` while a participant marker is
present AND `activeGardenHouseholdID != signed-in id` (resolver:
`AppEnvironment.activeGardenHouseholdID`, `Seedkeep/App/AppEnvironment.swift:306-313`).
Rows whose `householdID` matches neither ID are out of scope — leave untouched.

1. **Five types** — unambiguous: the adopt wipe (`wipeHouseholdSwiftData`,
   `HouseholdCloudCoordinator.swift:554-567`) destroyed all prior local rows, and flag-ON builds
   47–49 never re-imported these types from the server (`syncAll` household-feed gate landed
   `ed7e89f`, before the default-ON cutover). **Implementer MUST verify in git history that no
   view-driven server import path existed for these five types under CloudKit-ON on builds 47–49
   (check `LibraryView`/`GardenView`/`LocationsView`/`TagsView` refresh paths at `637a9c2`). If one
   existed, STOP and report — do not guess.** Re-home: set `householdID` to the owner-zone ID;
   preserve `id`, relationships, timestamps, `deletedAt` tombstones byte-for-byte.
2. **Journal entries — trustworthy evidence = FK resolution into the active garden.** After step 1,
   an entry whose `seedID`/`bedID`/`plantingEventID` (see `parentKind`,
   `Seedkeep/Core/Models/LocalJournalEntry.swift:47-52`) resolves to a row whose `householdID` is
   the owner-zone ID was authored post-adopt (solo imports can only reference solo-household object
   ids; ids are globally unique server/UUID strings — no coincidental matches). Auto re-home it and
   its children (checklist items + journal photos via `entryID`).
3. **Everything else journal-shaped** (no FK, or FK not resolving into the owner-zone garden) —
   ambiguous → **quarantine**: leave `householdID` unchanged (already hidden: views filter on
   `activeGardenHouseholdID`; planner filter excludes from export) and register a review item.
4. **Checklist items / journal photos** always follow their parent entry's disposition. A checklist
   item whose parent entry is not stranded is not touched.

## Quarantine registry (survives future adopt wipes)

New SwiftData model `LocalJournalRecoveryItem` (add to `SeedkeepSchema.all` — additive, mirrors how
`LocalCloudKitDeletion` was added in `ed409ff`):

- `@Attribute(.unique) id: String` (= stranded entry id), `scopeKey: String`
  ("<ownerZoneHouseholdID>|<signedInHouseholdID>"), `snapshotJSON: String` (entry fields + its
  checklist items — payload snapshot, mirroring the `LocalPendingWrite.payloadJSON` idiom,
  `Seedkeep/Core/Models/LocalPendingWrite.swift:27-45`), `detectedAt: Int64`,
  `status: String` (`pending` | `shared` | `kept`).

Rationale: `wipeHouseholdSwiftData` wipes all 10 garden types on any future adopt, including
quarantined rows; the registry is NOT a garden type so it survives, and the snapshot lets "share"
recreate the entry after such a wipe. `eraseAllLocalData()` (SeedkeepSchema.all-generic,
`SyncEngine.swift:63-69`) wipes it on sign-out automatically once it's in the schema — verify.

## Migration runner

- New `ParticipantRowRecovery` (pure core + small runner), living beside
  `HouseholdMigrationExecutor` in `Seedkeep/Core/CloudKit/`. Pure planning function
  (SwiftData rows in → disposition lists out) so it is host-testable like
  `HouseholdMigrationPlanner.plan()`.
- Trigger: participant path of coordinator startup/`syncIfPossible` in `AppEnvironment` — runs when
  flag ON + participant marker present + signed-in ≠ owner-zone, BEFORE the sync pass. Find the
  exact seam by reading `bootParticipant`/`syncIfPossible` (`AppEnvironment.swift:403-438`); mirror
  how the coordinator is rebuilt there.
- Durable one-time marker following the exact existing convention
  (`HouseholdCloudCoordinator.swift:580-584`):
  `seedkeep.ck.recovery27d18.<cloudKitEnvironmentTag>.<scopeKey>` (Bool, UserDefaults). Marker is
  written ONLY after the atomic save succeeds; failure → no marker → safe re-run next launch
  (detection is stateless/idempotent).
- Atomicity: one `ModelContext`, single `context.save()` covering all re-homes + registry inserts.
- After success: fire the existing debounced immediacy (`AppEnvironment.noteHouseholdMutation()`)
  so `pushDirty` exports re-homed rows (they now pass `fetchInput`; the uxc.1 ledger has no entries
  for them, so they are dirty by construction — that is the intended upload path).
- Cloud-side collisions (same recordName already in the owner zone, e.g. a second device ran
  recovery first) are resolved by the existing CKSyncEngine merge machinery
  (serverRecordChanged → resolver, sticky-deletedAt) — do not build new conflict handling; document
  this in the code only if a comment is needed for a non-obvious constraint.

## Review inbox UI

- Settings ▸ the existing CloudKit section (`Seedkeep/Features/Settings/SettingsView.swift:264-332`),
  participant branch: a row "Journal items need review (N)" visible while any `pending` item exists
  for the current scopeKey; opens a sheet (mirror the `PendingWritesView` list idiom,
  `Seedkeep/Features/Settings/PendingWritesView.swift`) listing snapshot date + body snippet, with
  per-item **Share to garden** / **Keep private** plus bulk actions.
- **Share to garden**: if live stranded rows still exist → re-home in place (entry + children) and
  fire `noteHouseholdMutation()`; else recreate from `snapshotJSON` through the 27d.17 CloudKit
  authoring path in `JournalStore` (minting `journal_local_` ids). Mark item `shared`.
- **Keep private**: mark `kept`; rows (if present) stay parked and hidden. No deletion anywhere.
- No nag: the row disappears when no `pending` items remain. No new onboarding/one-shot sheet
  machinery — the Settings row IS the surface (matches the CloudKit status-panel pattern).

## Non-negotiable invariants (test these; they must FAIL without the fix where marked)

1. Stranded five-type rows are re-homed and appear in `fetchInput`/`plan()` output for the owner
   zone; **repro test proves they are excluded pre-migration** (fails without migration).
2. FK-evidenced journal entry + its checklist items re-home together; **repro: excluded
   pre-migration** (fails without migration).
3. Ambiguous journal entry (no FK / solo FK) is NOT re-homed, NOT in export, and a `pending`
   registry item with a faithful snapshot exists.
4. Owner mode (no participant marker): migration is a no-op; zero writes.
5. Marker idempotency: second run after success performs zero writes; a failed save writes no
   marker and the rerun recovers.
6. Timestamps/ids/tombstones byte-identical across re-home (assert full field equality except
   `householdID`); a tombstoned (`deletedAt != nil`) stranded row re-homes with tombstone intact.
7. Flag-OFF: byte-identical behavior — migration never runs, no schema-visible behavior change
   (existing suites stay green in the OFF lane).
8. Share-to-garden recreates from snapshot when live rows are gone (post-wipe path).
9. Keep-private leaves rows parked and marks the item `kept`; nothing deleted.
10. The parked solo CloudKit zone and rollback data are untouched (no writes to any store other
    than SwiftData + UserDefaults marker + registry).

Test infra: `makeTestContainer` with `cloudKitDatabase: .none` (`SeedkeepTests/TestSupport.swift:11-20`),
`FakeEngine` seam + `makeCoordinator(provisioner: nil)`
(`SeedkeepTests/HouseholdCloudCoordinatorTests.swift`), direct `Local*` row seeding as in
`HouseholdMigrationPlannerTests.swift:68-112`. Baseline ~441 tests; both lanes of
`scripts/test-gate.sh` must pass.

## Verify (bead verify_cmd)

```
xcodebuild test -project /Users/tfinklea/git/seedkeep-ios/Seedkeep.xcodeproj -scheme Seedkeep \
  -destination 'platform=iOS Simulator,id=FDDFB511-272B-40DD-8927-5E71311E96BA' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## Out of scope

- Journal photo binaries in snapshots (photos are R1-hidden per the core-CRUD ADR; snapshot covers
  entry + checklist text only; live photo rows follow a live parent re-home, nothing more).
- 27d.2 (pending-write flush gating) — separate bead, do not touch `flushPending`.
- Server-side anything. Two-account device validation (user-gated; routes to device-verify.md).

## Acceptance (bead)

Idempotent one-time migration recovers every affected household-bearing type + relationships;
migrated rows are selected by CloudKit export and converge; collisions fail closed with recoverable
evidence; owner mode / flag-OFF rollback / parked solo zone byte-for-byte untouched; tests seed
distinct signed-in/owner IDs and fail without the migration; device check routed to
device-verify.md.

Commit message: `feat: recover participant rows stranded under pre-fix household ID (seedkeep-27d.18)`
with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do NOT push.
