# N2-E — Never recreate a deleted garden (contract)

Status: draft 7, approved by Sol on round 7 (2026-10-23) with no open
findings. Owner decisions are in the umbrella `decisions.md` ([2026-10-22]
N2-E). The owner accepted the residual limits below on 2026-10-24. Branch `redesign/r2-design-system`.

## Owner decisions (fixed)

- **Scope for 1.0 is the guard only.** No N2-E code path may create or
  write into a garden zone that was deleted, and every device handles a
  garden deleted elsewhere: by another device, from iCloud Settings, by the
  owner ending sharing, or by removing the participant. In-app "Delete
  Seedkeep data" is after 1.0.
- **A device whose garden is gone offers a choice:** discard its copy, or
  keep the copy as a new garden under a new ID. Neither writes into the gone
  garden. This applies to every deletion reason, including `.purged` (data
  deleted in iCloud Settings), although Apple suggests also deleting local
  caches then: the owner chose to let the user decide, and the screen says
  the data was deleted from iCloud.

## Why gardens come back today

Code survey at `afc1a5a`:
1. `HouseholdCloudCoordinator.ensureStarted` calls `ensureZone` (an
   idempotent zone save), `ensureHousehold` and `ensureShare` once per process
   and again after `wipeAndClear`, with no check that the zone existed.
2. `HouseholdSyncEngine.save()` stages `.saveZone` on each engine
   generation's first save, and restored engine state can already hold one.
3. A record save failing with `zoneNotFound`/`userDeletedZone` re-stages
   `.saveZone`: a silent recreate.
4. Share preparation calls `ensureZone`.
5. Fetched zone deletions, zone fetch errors and zone save results are
   ignored.
6. New gardens use a deterministic ID, so a garden made after a deletion
   reuses the deleted zone's name.
7. A revoked participant keeps its marker and sees a generic sync banner.

## Design

### 1. The guard store

- One file, `Application Support/GardenGuard/guard.json`, versioned and
  rewritten as a whole for every transition (temp file, `fsync`, atomic
  rename).
  - There is no fallback to an older copy. A fallback could roll authority
    back (an `attempting` grant reverting to `pending`), and that is a
    resurrection path.
  - Keyed by **account** (iCloud user record name plus CloudKit
    environment). Each account entry holds:
  - `binding`: the bound garden (household ID, zone name, owner name,
    scope);
  - `grants`, `seen` (each with its generation), `gone` (each with its
    journal), `retired` and `acknowledged`.
  - A retired ID stays retired for this account for as long as the safety
    record is retained. A later invitation to the same shared garden ID does
    not revive it; shared listings, stale chooser answers and direct share
    adoption both exclude it before local data is wiped or rebound.
- **Local-store ownership stays where it is.** The identity cache in
  UserDefaults keeps recording which account owns the local store, and
  `resolve(recordName:)` keeps its different-account wipe.
- **The guard's `binding` is the account's latest binding.** Every binding
  change writes it to the guard first, then the identity cache and
  participant marker. That covers keep, discard (binding cleared), the
  silent re-home, and ordinary resolution in `AuthController`.
  - A newer binding **supersedes** any open journal's target in the same
    guard write.
  - A journal stays until a later launch confirms that the defaults match
    the guard's **latest** binding. If they don't (UserDefaults persists
    asynchronously), the runner rewrites them from that latest binding.
  - It never replays an older journal target.
- **Resolution order** in `resolve(recordName:)`:
  1. verify the iCloud account;
  2. finish any different-account wipe (the identity cache still names
     the local store's owner);
  3. **reconcile the defaults from the guard's latest binding** for this
     account, if there is one;
  4. only then may garden selection (the fast path, `resolveFresh`, the
     legacy rebind or the chooser) commit a binding.

  So a bound but not-yet-created successor, with its `pending` grant, is
  re-entered rather than replaced.
- A journal is removed only after a later launch has confirmed the identity
  cache and participant marker against the latest binding (and, for keep,
  after its grant is consumed), never earlier.
  - The repair runs only after resolution has verified the iCloud account
    and finished any different-account wipe, and only for that account's
    journal.
  - It never runs before resolution, and never for another account.
- Other accounts' entries are kept, never erased by an identity switch. They
  hold only IDs and zone names.
- **Fail closed:** when the file exists but can't be read or decoded,
  nothing is sent to iCloud for any garden. Every window shows "Seedkeep
  can't read its iCloud safety record", with **Try again** and **Reset**
  (confirmed).
  - Reset starts an empty record, and nothing is sent until the start
    checks (§3) have run. Every grant is gone with it: a bound creation
    candidate without its grant has no zone, so the start checks treat it
    as gone, and it is never created.
  - Reset is safe against resurrection, because an absent zone without a
    grant is always treated as gone (§3) and never created: an interrupted
    keep or discard then returns as a gone garden and asks again.
  - What Reset loses is the recorded generations and retired gardens (see
    Limits).
  - A keep interrupted between re-homing its rows and binding (§7) leaves
    those rows under a household that is no longer bound. Nothing syncs an
    unbound household, so they stay on the device, unseen and never sent.
    This is disclosed in Limits.

### 2. Zones are created only through a creation grant

- A **grant** is written only when this device decides to create a
  brand-new garden (§4). States: `pending` → `attempting` → consumed.
- Before the first zone request, the grant moves to `attempting` (durable).
  The provisioner then saves the zone and the `Household` root. **Only a
  confirmed success counts:** the per-item save results confirm both, and
  the server-returned root has a non-nil `creationDate`. In one guard write,
  the grant is consumed and the garden is added to `seen` with that
  `creationDate` as its **generation**. The app's own `createdAt` is never
  substituted.
- **A request that was never dispatched keeps its grant.** Examples are
  offline (`networkUnavailable`), the account not being available, or the
  check failing before the request. The grant stays `pending`, and creation
  waits for the next pass.
- **Any other outcome abandons the ID.** That covers a crash while
  `attempting`, an error after dispatch, an uncertain result, or missing
  metadata. The ID is retired, and the device's rows move to a fresh ID with
  a new `pending` grant through the silent re-home (§7).
  - An abandoned zone is never inspected or completed. At most it leaves an
    empty or root-only garden zone in iCloud (see Limits).
- **Bounded:** after an abandonment, creation waits for the next app launch
  or a user's **Sync now**. After three abandonments for one account within
  24 hours, creation pauses, and Settings shows "Seedkeep couldn't create
  your garden in iCloud" with **Try again**. The garden keeps working on
  the device.
- **No other path creates a zone:**
  - `ensureStarted` never calls `ensureZone` without a grant; it runs the
    start checks (§3).
  - `HouseholdSyncEngine` never stages `.saveZone`. On every initialization
    and rollback it strips pending database changes from the restored state.
    A record save into a missing zone is a gone signal (§5), never a retry.
  - Share preparation requires a seen garden and never calls `ensureZone`;
    `ensureShare` and the share save run only after the batch check (§3).
  - Migration only writes records, behind the batch check.
  - DEBUG spike zones (`seedkeep-spike-*`) keep their own paths and are
    excluded from every garden rule.

### 3. Checks before anything is sent

- **Start checks** at each coordinator start (once per process, and after
  `wipeAndClear`), for the bound garden, in this order:
  1. **a `pending` grant** for it: the bound garden is a **creation
     candidate**. It is provisioned through the grant (§2), and none of the
     checks below apply.
  2. **an `attempting` grant:** abandon and re-home (§2).
  3. **otherwise,** an established garden: one zone listing of its database
     (owned: private, which also feeds discovery, §4; shared: shared, with
     the participant rules in §5).
     - zone missing → **gone**. This covers a zone that never existed, so a
       creation interrupted before its grant, or Reset, is never completed
       silently.
     - the `Household` root missing, or with a `creationDate` different from
       the recorded generation → **gone (recreated)**.
     - no recorded generation (a garden predating N2-E, or after Reset): the
       first fetched root's non-nil `creationDate` is recorded (**trust on
       first use**).
  - network, account or ambiguous errors are not "gone": nothing is sent,
    and the pass retries as today.
- **Batch check:** at every outgoing request:
  - **Where:** in `nextRecordZoneChangeBatch`, for every batch CKSyncEngine
    asks for, including the repeated calls within one `sendUntilDrained`.
    Also before the share save and before each migration write.
  - **How:** the coordinator reads the root directly from the database (not
    through the engine), with a 10-second timeout, and then re-checks the
    account and epoch.
  - **On failure:** a mismatch, a missing root or zone, a timeout or an
    error returns no batch, and the hook records a **typed check failure**.
  - The drain loop (`sendUntilDrained`) stops on that failure instead of
    sending again, and returns it to the coordinator. Pending changes stay
    queued.
  - A mismatch reports gone. Anything else ends the pass and retries on the
    next one, with today's backoff.
  - **Cost:** one small record read per batch; G2 measures it.
- **Incomplete zones** (no root) are never adopted by resolution, offered
  in a chooser, or trusted by any device. The only exception is this
  device's own creation candidate, which holds a `pending` grant.

### 4. New gardens and discovery

- Every garden created from now on gets a **random household ID** with a
  distinct prefix (`hhr_` plus a UUID; G1 checks zone-name limits). An
  N2-E build therefore never reuses a deleted garden's name, and a
  random-format ID always marks a garden made by an N2-E build. Existing
  gardens keep their IDs; `DeterministicHouseholdID` stays only to resolve
  gardens that already use it.
- Creation points, each writing a `pending` grant first:
  - `resolveFresh` with no eligible owned garden (replacing
    `deterministicGarden`);
  - every legacy-rebind or chooser path that keeps the device's garden while
    its zone is absent, including the chooser's "keep" action. These go
    through the silent re-home (§7);
  - "Keep a copy" (§7) and an abandoned grant (§2).
- **Discovery:** at each start, the owned listing may show an eligible
  garden this device has neither seen nor acknowledged. Eligible means
  complete (has a root) and not retired; two devices creating gardens in the
  same seconds is the typical case. The app then shows the existing chooser
  once, with every eligible owned garden. All copies stay until the user
  picks; the others become acknowledged.
- **First N2-E launch:** listed owned gardens with pre-N2-E IDs
  (deterministic or legacy format) are acknowledged without a prompt, so
  users who chose before aren't asked again. Random-format gardens are
  never auto-acknowledged.

### 5. Gone signals while running

Each reports **gone** for the coordinator's garden; a deletion outranks
any other change in the same event batch:
- `.fetchedDatabaseChanges` deleting this zone, for any reason (`.deleted`,
  `.purged`, `.encryptedDataReset`);
- `.didFetchRecordZoneChanges` with `zoneNotFound` or `userDeletedZone`;
- a failed record save with `zoneNotFound` or `userDeletedZone`;
- a batch-check generation mismatch.

**Participants:**
- **Access lost** (gone): a **seen** shared zone is missing from the
  shared-database listing, or a deletion or zone error above concerns it and
  the listing confirms it.
- **Not yet available:** a just-accepted share not yet seen is never "gone".
  It keeps today's propagation-delay handling. If its zone is deleted or
  missing past that window, the existing "shared garden unavailable" path
  clears the participant marker and the pending share.
- **View only:** shown only when the share's `currentUserParticipant`
  permission is read-only. Sends stop, and fetching continues ("You can view
  this shared garden but not change it.").
- **Ambiguous:** `permissionFailure` without a confirmed read-only
  permission, network or account errors, or nested partial errors. Sends
  stop for the pass, and nothing is retired.

The engine's event-to-signal classification is a pure function in
`SeedkeepCloudKit`, tested for every reason and error code. The live adapter
paths are covered too (§Slices).

### 6. The guard runner and the fence

- **`GardenGuardRunner`**, one per app, main actor, single flight, owns
  every guard transition: grant creation and abandonment, gone handling,
  keep, discard, the silent re-home and binding repair. Windows observe it;
  they never run it.
- **Writable garden.** `AppEnvironment.writableGarden` is the active garden
  plus a `gardenScopeEpoch`. It is nil while the bound garden is gone,
  awaiting a choice, or under a running journal.
  - The epoch is bumped on gone, on every binding change, and on every
    account transition.
  - Every writer captures `writableGarden` when it starts and re-checks
    both the garden and the epoch at its final mutation boundary. A stale
    or nil value does nothing. The writers:
    - UI writes through `SyncEngine.enqueue*` (refused when nil);
    - `JournalStore`'s direct saves;
    - `PetStateEngine` ticks (mood snapshots and streaks);
    - the scan-save attach (`scanBinding` gains this check);
    - share adoption's rebind and wipe;
    - notification scheduling;
    - the frost backfill;
    - `ParticipantRowRecovery`.
  - A notification added after its scope went stale is removed again.
- **On gone,** in one main-actor step before any await:
  1. write the `gone` entry (phase `awaitingChoice`). This is the commit
     point; if it fails, the coordinator stays stopped and detection repeats
     on the next start;
  2. bump the coordinator epoch, retire the engine generation and discard
     its pending changes;
  3. bump `gardenScopeEpoch` and `pendingShareEpoch`, and clear
     `writableGarden`.
- **Before keep or discard** mutates anything, the runner cancels the scan
  resume and the weather refresh and awaits them.
- **Launch ordering.** `SeedkeepApp` startup loads the guard first. If a
  journal or gone entry exists, nothing mutates until `restoreSession` has
  verified the iCloud account that owns it. Another account leaves the entry
  untouched and follows the normal identity flow. Then the runner resumes.
  Background services start and windows show a garden only after that.

### 7. The choice, keep, discard and the silent re-home

**Screen** (Workbench, every window, VoiceOver, large text):
- owner: "This garden was deleted from iCloud. It may have been deleted on
  another device or in iCloud Settings."
- participant: "You no longer have access to this shared garden. The owner
  stopped sharing it or removed you."
- What this device still has: seeds, beds and journal entries; photos,
  including how many aren't on this device and can't be kept.
- **Keep a copy as a new garden** and **Discard this copy** (destructive,
  confirmed). No dismiss.

**Journals.** Keep, discard and the silent re-home are journaled in the
`gone` entry:
- One guard write first fixes the action, the replacement ID and its
  `pending` grant, so a crash never mints a second ID.
- Every step is idempotent and writes its checkpoint after its effect. A
  crash between an effect and its checkpoint repeats the step safely.
- A failed step keeps its checkpoint and offers **Try again**.

**Keep** (the silent re-home does the same without the screen):
1. **Copy photo bytes** for every photo row into the new household's
   directories, and verify each hash. A photo whose bytes aren't on the
   device is counted and skipped; it doesn't block the rest.
2. **Re-target staged scans** to the new ID, in their manifests, before
   the new scope can be seen. `resumeStagedScans` deletes manifests for
   other households, so this order matters.
3. **Re-home the rows** in one SwiftData save, per the table below.
   - The data graph is kept as is: every row moves, live or tombstoned,
     with its IDs and references unchanged, so no reference points at a
     dropped parent.
   - Tombstoned rows upload as tombstoned records (`deletedAt` set), as
     `pushDirty` does today for rows with no confirmed state.
   - Photo rows whose bytes are not on the device (none, or failing their
     own hash) are **dropped** from the copy, in the same save, judged
     while the old bytes are still in place so a retry decides the same.
     The choice screen's count of photos that can't be kept equals what is
     dropped, and the first sync raises no notice for them.
4. **Recovery items.** Pending journal recovery snapshots for the old scope
   are restored as journal entries of the new garden, and then removed.
   - This uses `ParticipantRowRecovery`'s low-level restore helpers with the
     journal's original scope.
   - Their atomic status change lets a retry restore only what is still
     pending.
   - Recovery is participant-only today, and the new garden is owned.
5. **Old state:**
   - the old scope's durable CloudKit files are removed: engine state,
     synced state, rosters, the cleanup marker;
   - the old migration and recovery markers are removed;
   - the new ID's migration marker is set, so migration doesn't run and the
     ordinary first sync uploads everything (the new scope has no synced
     state);
   - per-household UserDefaults keys (the watering ledger) are moved.
6. **Remove the old photo bytes.**
7. **Bind** in one guard write: the new owned binding, the old garden
   retired, the journal marked done. The defaults are then derived from the
   binding (§1).
8. The first sync creates the zone through the grant (§2) and uploads the
   copy. The journal entry is removed only when both are true: the grant is
   consumed, and a later launch has confirmed the identity cache and
   participant marker (§1).

**Discard:**
1. **Delete everything of the old garden:**
   - its rows, per the table;
   - its photo bytes and staged scans;
   - its durable CloudKit files and markers, and its per-household keys;
   - its notifications.
2. **Clear the binding and retire the garden** in one guard write; the
   defaults are then derived from it.
3. **Then `restoreSession()`.** That leads to the other garden, the
   chooser, or a new garden (fresh ID, grant).

When `restoreSession()` binds a successor garden, that binding supersedes
the discard journal's cleared target (§1). The journal is removed after a
later launch confirms the defaults against the successor.

Journal execution is scoped to the verified account, garden and scope epoch.
It revalidates those after suspension points. Before an account or garden-switch
wipe, running journal work is cancelled and awaited; cancellation leaves the
durable journal open and fenced for retry or launch resumption. A completed or
superseded journal does not fence its successor.

**Disposition by model:**

| Model | Keep | Discard |
|---|---|---|
| `LocalLocation`, `LocalTag`, `LocalSeed`, `LocalSeedPhoto`, `LocalBed`, `LocalPlantingEvent`, `LocalJournalEntry` (by `householdID`) | every row re-homed, live or tombstoned | deleted |
| `LocalJournalEntryPhoto`, `LocalJournalChecklistItem` (by their entry), `LocalPetDeparture`, `LocalPetMoodSnapshot` (by their planting event) | unchanged; they follow the parent | deleted. Membership is captured before parents are deleted |
| `LocalCloudKitDeletion` for the old scope | deleted | deleted |
| `LocalJournalRecoveryItem` for the old scope key | restored into the new garden, then deleted | deleted |
| `LocalSyncCursor`, `LocalPendingWrite` (server era, inert since T1) | left alone | **all** deleted. This is an explicit global cleanup, not garden-scoped: their payloads can't always be tied to a household, they can hold garden names, and no code reads them |
| `LocalAssistantThread` for the old household, with its `LocalAssistantMessage` and `LocalAssistantToolCall` children; `LocalAssistantKeyStatus` rows whose household composite key names it (server era, inert) | left alone | deleted. Other households' assistant rows stay |
| `LocalRecommendation`, `LocalForecastSnapshot`, `LocalCatalogCorrection` (not garden data) | unchanged | unchanged |
| Photo bytes (pending uploads, cache, legacy transfer) | copied and verified, then the old bytes removed | purged |
| Staged scans of the old household | re-targeted | purged |
| Migration marker (`environment + household`) | old removed; new ID's set | removed |
| Recovery markers for the old scope | removed | removed |
| Watering ledger and other per-household keys | moved | removed |
| Durable CloudKit files for the old scope | removed | removed |

G3 starts by checking this table against the schema, the code's
per-household keys and the recovery restore path, and records any change.

## Limits (accepted by the owner, 2026-10-24)

1. **Older builds** still recreate zones. N2-E devices treat a recreated
   zone as gone, because its root has a new `creationDate`. The old build's
   device keeps using it until it updates.
2. **Trust on first use:** a garden recreated by an older build before an
   N2-E device first records its generation looks valid to that device. The
   same applies after **Reset** of the safety record.
3. **In-flight window:** a batch CloudKit already accepted when a deletion
   happens elsewhere can land. A recreation by an older build between the
   batch check and the send can also receive that one batch. A server-side
   condition would close this, but CloudKit offers none that doesn't
   conflict on every batch.
4. **An interrupted creation** can leave an empty or root-only garden zone
   in iCloud. It holds no garden data, and the user can delete it in iCloud
   Settings. Repeated failures pause creation (§2).
5. **Concurrent first launch** can make two gardens. Discovery (§4) shows the
   chooser.
6. **Photos missing from a device** are not in a kept copy: their rows
   are dropped.
7. **After Reset** (the safety record unreadable), a keep that was
   interrupted between re-homing and binding leaves its rows on the device
   under an unbound household: never synced, not shown. A creation
   candidate whose grant was lost shows as a gone garden, and the user
   chooses again.

## Invariants

- No CloudKit schema change; no `@Model` added or removed. Existing gardens
  keep their IDs and data.
- No zone is created without a grant on any path except DEBUG spike zones.
- From the gone commit point, this device starts no new send to that garden.
- Account changes keep today's epoch and pause behaviour.
- Sample-garden mode and XCTest stay inert.

## Slices (they ship together; none is release-safe alone)

1. **G1 — Guard store, binding authority, grants, fresh IDs, discovery**
   (`worker-sonnet`): §1, §2, §4. It adds a fake provisioner that records every
   zone save, root save and `.saveZone` staging. Tests:
   - existing gardens never create a zone (startup, first save,
     `zoneNotFound` retry, share, restored `.saveZone` in engine state);
   - a grant creates exactly once, and the generation is captured from the
     server result;
   - every dispatched non-success outcome abandons the ID and re-homes,
     while an undispatched one keeps the `pending` grant;
   - abandonment is bounded, and the pause appears after three;
   - the start checks run in order (pending, attempting, established);
   - fresh random IDs;
   - discovery and first-launch acknowledgement (pre-N2-E versus
     random-format);
   - a journal's defaults repaired after resolution, never before it, and
     a different-account wipe still running;
   - the store: atomic replacement, a corrupt file failing closed, Reset
     leading back to the start checks, and a lost `attempting` grant never
     recreating its zone;
   - a crash after grant consumption but before the defaults persist:
     repaired at the next launch from the latest binding, while the journal
     is still present;
   - discard, then a successor bind, then relaunch: the successor stays
     bound, and the discard journal is never replayed. This includes the
     case where the defaults are durably empty and the successor is
     unprovisioned: it and its grant survive the relaunch, and no other
     garden is created;
   - account entries kept across switches.
2. **G2 — Checks, signals, runner and fence** (`worker-sonnet`): §3, §5, §6.
   The fake engine gains zone deletions for each reason, zone fetch errors,
   permission failures, a recreated root, coalesced delete-then-modify
   batches, and multiple batches per send. Tests:
   - each signal fences with zero new sends afterwards;
   - a batch check on every batch, including a mismatch on the second
     batch;
   - a failed check stopping the drain loop with pending changes kept;
   - a cold relaunch with pending writes into a deleted zone detects before
     sending;
   - a crash before the gone write repeats detection;
   - the participant cases: view only by participant permission, access
     lost, not yet available, ambiguous;
   - late scan, share, notification, journal and pet-tick work does nothing
     for a stale or nil writable garden, and a late notification is
     removed;
   - two windows;
   - account switches during each await;
   - launch ordering;
   - the pure classifier for every event and error, and the batch hook
     through the real `HouseholdSyncEngine` delegate code with a stub
     database.
3. **G3 — Choice, keep, discard, silent re-home** (`worker-sonnet`): §7.
   Tests:
   - crash and resume between every effect and its checkpoint, for keep,
     discard and the silent re-home;
   - the disposition table, model by model, including:
     - tombstones uploaded as tombstoned records;
     - children;
     - recovery items restored through the helpers;
     - assistant rows scoped to the discarded household;
     - markers;
   - photo copy, verify and missing counts;
   - staged scans re-targeted before exposure;
   - a failed byte or model commit;
   - repeated taps and two windows;
   - the new garden uploads through its grant.

   Screenshots for owner and participant wording at default and AX sizes.

Each slice gets the gate, Opus and Sol reviews, and DeepSeek (the owner
approved this routing in the user-level instructions).

## Verification

- Gate per slice; Mac build; the R3/R4 screenshot runs still reach every
  step; the audit compared with N3's 309.
- **What the tests show:** with fakes and a stub database, no N2-E path
  creates a zone without a grant, and every batch is checked before it is
  sent.
- **What they can't show:** how real CloudKit delivers deletion events.
  The start and batch checks don't depend on those events, apart from the
  in-flight window (Limit 3). An optional, owner-approved spike on
  `seedkeep-spike-*` zones (never a garden) can confirm the live events.
- **Owner checks:**
  - on a throwaway garden, delete it from iCloud Settings and confirm
    another device shows the choice;
  - keep a copy;
  - stop sharing with a participant device.
