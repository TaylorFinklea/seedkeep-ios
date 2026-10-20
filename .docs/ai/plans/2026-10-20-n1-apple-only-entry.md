# N1 — Apple-only entry (contract)

Plan: umbrella `.docs/ai/phases/2026-10-20-apple-only-plan.md` (approved
2026-10-20, N1 + N2). Decision: umbrella `decisions.md` [2026-10-20].
Branch: `redesign/n1-apple-only`, based on `redesign/r1-shell-seeds`.

Parent-owned contract files (do not change their shape; ask the parent):
- `Seedkeep/App/CloudIdentity.swift`: `CloudAccountStatus`,
  `GardenDatabaseScope`, `GardenZoneSummary`, `CloudIdentityProviding`,
  `DeterministicHouseholdID`, `CloudEntryBlock`, `GardenChoice`
- `Seedkeep/Core/ServerRetirement.swift`: `ServerRetirement.isRetired`,
  `makeRefusingSession()`, the lock-protected `refusals` snapshot (logged
  under `app.seedkeep` / `ServerRetirement`), `RefusingURLProtocol`
- `AuthController.isIdentityVerified` (slice A sets it)
- `AppEnvironment.canUseCloudKit` and `pausedDeletionCheckpointCount`
  (slice B sets the count)

Revised after GPT-6.1 Sol's contract critique: verified-identity gate,
failing eraser, deletion quarantine of CloudKit, internal access, unavailable
shared garden, own garden kept through the chooser, transition generation,
automatic catalog fetches, handoff root in slice A, synchronous refusal
count, retryable `.signedOut`, and stronger tests.

## Invariants (both slices)

1. **No request ever reaches the Seedkeep server.** `SeedkeepClient` uses
   `ServerRetirement.makeRefusingSession()`. Every server caller on a live
   path is also gated on `ServerRetirement.isRetired`, so nothing even
   tries; that keeps error banners away and the refused-request counter at
   zero.
2. **No silent data loss.** A failed wipe blocks binding: the eraser throws,
   and the controller enters `.failed` with Retry instead of adopting the new
   identity. Only these wipe local data:
   - a confirmed different iCloud user (`userRecordName` differs from the
     cached one)
   - the user explicitly choosing another garden in the chooser, after a
     confirmation that warns about unsynced changes
   - CKSyncEngine's own sign-out and switch-accounts events, unchanged
   Transient failures, missing zones and listing errors never wipe.
3. **`.signedIn(user:household:)` keeps its shape.** `user.id` is the iCloud
   user record name (for a legacy cache before rebind, the old server ID).
   `household` is the user's OWN household. A shared garden stays the
   participant marker (`ActiveGardenContext` keys), as today.
4. **CloudKit is the only sync path in the app.** Outside XCTest,
   `FeatureFlags.cloudKitHouseholdSyncEnabled` is always `true`; an explicit
   stored `false` is ignored. XCTest keeps its two lanes until N3.
5. **Test-host inertness on both platforms.** No live CloudKit identity call
   under XCTest; the startup guard covers iOS as well as macOS.
6. No CloudKit schema change: no new record types or fields.
7. **CloudKit only on a verified identity.** Entering `.signedIn` from a
   cache without confirmation sets `isIdentityVerified = false`. Local
   editing works, but `AppEnvironment.canUseCloudKit` is false: no
   coordinator creation, sync, save, photo recovery or sharing. The next
   resolution, on foreground or sync, verifies and sets it true, or handles
   the account switch. While deletion checkpoints exist (slice B),
   `canUseCloudKit` is also false.
8. **One transition at a time.** Every identity transition (restore, retry,
   revalidate, choose, keep, signOut) takes a new generation number. A pass
   whose generation is stale when it resumes from an `await` publishes
   nothing and wipes nothing.

---

## Slice A — identity, entry and sharing gates (worker-opus)

Files you own:
- `Seedkeep/App/AuthController.swift`
- new `Seedkeep/App/LiveCloudIdentityProvider.swift`
- `Seedkeep/App/SeedkeepApp.swift`
- `Seedkeep/App/MacAppDelegate.swift`
- `Seedkeep/App/ActiveGardenContext.swift`
- new `Seedkeep/Features/Entry/*`
- delete `Seedkeep/Features/SignIn/SignInView.swift`
- `Seedkeep/Features/You/YouView.swift` (identity rows only)
- in `Seedkeep/App/AppEnvironment.swift`, ONLY: `live()`'s `AuthController`
  construction, the share gates (`prepareOwnerShare`, iOS adoption,
  `processPendingShare`/macOS acceptance), and the new account-change
  observer
- `Seedkeep/Core/FeatureFlags.swift` (invariant 4)
- tests: `SeedkeepTests/AuthLifecycleTests.swift` (rewrite) and new tests

### A1. `LiveCloudIdentityProvider: CloudIdentityProviding`

Container `iCloud.app.seedkeep` (use `SeedkeepZoneProvisioner().container`).
- `accountStatus()`: bounded to 10 s (copy the detached-task timeout pattern
  in `HouseholdCloudCoordinator.accountStatus`).
  - `.available` → `.available`
  - `.noAccount` → `.noAccount`
  - `.restricted` → `.restricted`
  - anything else, or a timeout → `.unverified`
- `currentUserRecordName()`: bounded; `container.userRecordID().recordName`.
  Throws on failure or timeout.
- `listGardenZones(_:)`:
  1. `allRecordZones()` on the private or shared database, bounded.
  2. Keep zones whose name has the `seedkeep-` prefix; the household ID
     comes from `SeedkeepRecordNames.householdID(fromZoneName:)`.
  3. Batch-fetch each zone's root record
     `SeedkeepRecordNames.household(id)` and read `name` (String),
     `createdAt` and `updatedAt` (Int64 milliseconds). A missing or
     unreadable root leaves those fields nil; it is not an error.
  4. Any zone-listing failure throws.

### A2. `AuthController` (same class, new resolution)

Make `AuthController` and its members **internal**: drop `public`. Nothing
outside the app module uses it, and its state carries internal types.

```swift
enum State: Equatable, Sendable {
    case signedOut                       // not resolved yet (launch), or after signOut()
    case authenticating                  // resolving
    case signedIn(user: UserDTO, household: HouseholdDTO)
    case needsICloud(CloudEntryBlock)
    case choosingGarden(GardenChoice)
    case failed(message: String)
}
init(identity: any CloudIdentityProviding, tokenStore: any TokenStoring,
     defaults: UserDefaults = .standard)
func wireLocalDataEraser(_ eraser: @escaping @MainActor () async throws -> Void)  // now throws
```

The controller no longer takes a `SeedkeepClient`. The public API:

| Method | Behaviour |
|---|---|
| `restoreSession()` | Resolve, as below. Single-flight: concurrent calls await the same pass (iPad and Mac have several windows). |
| `retry()` | Same resolution, from `.needsICloud` or `.failed`. |
| `chooseGarden(_ c: GardenZoneSummary, discardingDeviceData: Bool)` | Binds the choice. `c` is a candidate or `choice.ownGarden`. When `discardingDeviceData`, run the eraser first; the chooser UI sets it only after the user confirms. That happens for any choice under `.deviceGardenNotFound`, other than keeping the device garden, and under `.sharedGardenUnavailable`. |
| `keepDeviceGarden()` | `.deviceGardenNotFound`: rebind to the device's household with no wipe. |
| `revalidateAfterAccountChange()` | Called on `.CKAccountChanged`. |
| `signOut()` | Kept, for the deletion seam; no UI calls it in N1. |
| `adoptHousehold(_:)`, `wireLocalDataEraser(_:)`, `loadCachedIdentity()` | Kept. |

Remove `adoptBearerToken`, `resolveHousehold`, `loadIdentity` and every
`SeedkeepClient` use.

**Caches.**
- **New:** UserDefaults key `seedkeep.identity.icloud.v1`, JSON
  `CachedIdentity(user: UserDTO(id: userRecordName, name: nil, email: nil),
  household:)`.
- **Legacy:** `seedkeep.auth.lastIdentity`, read for migration only.
  `loadCachedIdentity()` returns the new cache, else the legacy one.

**Resolution (`restoreSession` / `retry`).** `state = .authenticating`
unless already `.signedIn` from a prior pass, then:

1. `status = accountStatus()`.
   - `.noAccount` → `.needsICloud(.noAccount)`. Restricted →
     `.needsICloud(.restricted)`. No wipe either way.
   - `.unverified` → if there is a new or legacy cache, enter
     `.signedIn` from it as-is with `isIdentityVerified = false` (no rebind;
     legacy stays legacy). Otherwise `.needsICloud(.couldNotVerify)`.
   - Every path that ends in a confirmed `.signedIn` sets
     `isIdentityVerified = true`.
2. `recordName = currentUserRecordName()`. On failure, apply the
   `.unverified` rule.
3. **New cache:**
   - same `userRecordName` → `.signedIn(cache)`. No listing.
   - different → wipe (eraser); if the eraser throws, `.failed` with Retry
     and stop. Otherwise clear the new cache and the participant marker,
     then step 5.
4. **Legacy cache only** (household `H`):
   - With a participant marker: list `.shared`. If the marker's zone (name
     and owner) is present → **rebind**. If it is absent after a successful
     listing → `.choosingGarden(GardenChoice(reason:
     .sharedGardenUnavailable(zoneName:), candidates: <other shared zones>,
     ownGarden: <owned zone H if listed, else a summary for H>))`. Leaving
     the unavailable garden discards this device's copy, after confirmation.
   - Without one: list `.owned`. If `seedkeep-H` is present → **rebind**.
   - Listing throws → enter `.signedIn` from the legacy cache as-is; retry
     the rebind on the next resolution.
   - Not found after a successful listing:
     - list both scopes (excluding `H`)
     - no other candidates → **rebind** to `H` (keeps the device's data;
       the owner coordinator provisions the zone at first sync, as before)
     - other candidates → `.choosingGarden(GardenChoice(reason:
       .deviceGardenNotFound(householdID: H), candidates:, ownGarden: nil))`
   - **Rebind**, crash-safe:
     1. write the new cache `{recordName, legacy household}`
     2. remove the legacy key
     3. `tokenStore.clear()`
     4. `.signedIn`

     No eraser, no marker change; household ID, cursors, markers and
     pending writes are untouched. If the new cache exists while the
     legacy key also does, use the new one and remove the legacy key.
5. **No cache** (fresh install or new device). List `.shared` and `.owned`;
   either throwing → `.needsICloud(.couldNotVerify)`. Never mint on a
   failed listing.
   - **Own household first:**
     - one owned zone → it
     - none → `DeterministicHouseholdID.make(userRecordName:)`, named
       "My garden", timestamps now (a synthetic owned summary)
     - several owned → `.choosingGarden(.multipleOwnGardens)` over the
       owned zones (`ownGarden: nil`). After that choice, continue with the
       shared step below, using the chosen own garden.
   - **Then participant:**
     - no shared zone → owner
     - exactly one → write the participant marker (`ActiveGardenContext`
       keys) before entering
     - several → `.choosingGarden(.multipleSharedGardens)` over the shared
       zones, with `ownGarden` = the own garden resolved above. Choosing a
       shared zone keeps that own household.
   - Then write the new cache and enter `.signedIn`.
   - No eraser on this path: there is no cached owner.
6. `HouseholdDTO` from a summary: `name ?? "My garden"`,
   `createdAt ?? nowMillis`, `updatedAt ?? nowMillis`.

**Choosing.**
- An owned choice (a candidate under `.multipleOwnGardens` or
  `.deviceGardenNotFound`, or `ownGarden`) sets the own household and clears
  any marker.
- A shared choice keeps `ownGarden` (or the cached own household) as the own
  household and writes the marker.
- After a chooser decision, write the new cache and enter `.signedIn`.

**`revalidateAfterAccountChange()`**: a new generation; fetch status and
record name.
- the same user → nothing
- `.noAccount` or `.restricted` → `.needsICloud` (no wipe from here)
- a different user → eraser (throws → `.failed`), clear the caches and
  marker, resolve fresh
- unverified → nothing

`ActiveGardenContext` gains `recordParticipant(zoneName:ownerName:in:)` and
`clearParticipant(in:)`. They use the same two keys, and AuthController
calls them with its injected `defaults`.

### A3. Entry UI (Workbench tokens: `WBColor`, `WBMetrics`, `Font.wb*`)

`RootView` switches on `auth.state`:
- `.signedOut` and `.authenticating` → a centered progress view, "Opening
  your garden…". `.signedOut` also runs `.task { guard
  FeatureFlags.canRunLiveAppStartup else { return }; await
  auth.restoreSession() }`, so it is never a dead end. Single-flight makes
  this safe alongside the startup task.
- `.needsICloud(block)` → `CloudEntryView(block:)`:
  - `noAccount`: "Sign in to iCloud to use Seedkeep. Your garden is stored
    in your iCloud account." On Mac, a button opens System Settings
    (`x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane`);
    on iOS, a short instruction (Settings ▸ your name).
  - `restricted`: an explanation.
  - `couldNotVerify`: "Couldn't reach iCloud." Every state has Retry, which
    calls `auth.retry()`.
- `.choosingGarden(choice)` → `GardenChooserView(choice:)`:
  - a list of candidates with name, "Shared by someone" or "Yours", and the
    updated date
  - "Keep this device's garden" when `canKeepDeviceGarden`
  - choosing a candidate that discards device data (only for
    `.deviceGardenNotFound`) asks for confirmation first: "This device's
    garden will be removed from this device. Changes not yet synced to
    iCloud will be lost."
- `.failed(message)` → `CloudEntryView` with the message and Retry.
- `.signedIn` → unchanged, except the `.task(id:)` runs
  `await appEnv.processPendingShare()` before `syncIfPossible()` on **both**
  platforms. A share tapped on a fresh device is adopted before any solo
  sync.
- Update the `snapshotID` switch for the new cases. Remove `SignInView`.
- **Handoff root (slice A owns it, in `SeedkeepApp.swift`).** RootView no
  longer presents `AccountDeletionHandoffAcceptView` or the successor-resume
  sheet, and no longer touches `appEnv.accountDeletionFlow`. Drop the
  eager `.reload()` and `hasHandoffInProgress`. An incoming handoff link
  shows an inline retirement notice in the style of `signedOutInviteView`:
  "Garden handoff links are no longer supported." Leave
  `AccountDeletionRootRoute` itself to slice B.

### A4. Launch and gates

- `SeedkeepApp` startup `.task`:
  - `guard FeatureFlags.canRunLiveAppStartup else { return }` on both
    platforms
  - keep the macOS `didRunStartup` guard
  - keep the order: `recoverCommittedAccountDeletion()` (slice B makes it
    a quarantine), then `auth.restoreSession()`, then the pending-share
    drain
- **Apply `canUseCloudKit` in `AppEnvironment`** wherever a coordinator is
  created or used: `noteHouseholdMutation`; both `cloudKitScopeIDProvider`s
  and the photo-cache-miss recovery (return nil); `prepareOwnerShare`; iOS
  share adoption and `processPendingShare` (keep the share pending); and
  the CloudKit branch of `syncIfPossible`. Put one guard at the top of that
  branch: `if !auth.isIdentityVerified { await auth.restoreSession() };
  guard canUseCloudKit else { return }`. Slice B edits other lines of that
  function; the parent merges.
- **The eraser seam** (`AppEnvironment.init`'s `auth.wireLocalDataEraser`)
  becomes throwing: rethrow `eraseAllLocalData` failures, and throw when the
  coordinator's `wipeAndClear()` leaves `requiresWipeRetry`. Don't nil the
  coordinator in that case.
- `MacAppDelegate.processPendingShares` and the AppEnvironment share gates
  keep requiring `.signedIn`. That now means a resolved iCloud identity,
  so the gates need no code change beyond what resolution provides. Verify
  `prepareOwnerShare`, iOS adoption and macOS acceptance work with the new
  states, and that `.choosingGarden` and `.needsICloud` never drain a share.
- `AppEnvironment` observes `.CKAccountChanged` and calls
  `auth.revalidateAfterAccountChange()`. Main actor; register once.
- `YouView`: remove "Sign out". The identity row shows "iCloud account"
  instead of the server name or email.

### A5. Tests (Swift Testing, `FakeCloudIdentityProvider`, an isolated `UserDefaults` suite, fake token store, eraser spy)

One test at least per branch:
- the same user from the new cache: no listing, no wipe
- a different user: wipe, then fresh resolution
- `noAccount`, `restricted`, and `unverified` with each of new cache,
  legacy cache and no cache
- the record-name fetch throws
- legacy rebinds:
  - owner zone found
  - participant zone found
  - listing throws (legacy kept, rebind on the next pass)
  - not found with no other candidates (rebind, no wipe)
  - not found with candidates (chooser; `keepDeviceGarden` makes no wipe;
    `chooseGarden(_, discardingDeviceData: true)` wipes once)
- crash mid-rebind: new cache plus legacy key present → new cache wins,
  legacy removed, no wipe
- the token is cleared only after the rebind
- no cache:
  - one shared zone → marker written
  - one owned zone
  - no zones → deterministic ID, the same for the same record name
  - several owned → chooser
  - several shared → chooser that includes the own garden
  - listing throws → `couldNotVerify`, nothing minted
- single-flight: two concurrent `restoreSession` calls make one listing
- a stale generation: a resolution suspended in listing while
  `revalidateAfterAccountChange` binds another user publishes nothing and
  never wipes
- the eraser throws → `.failed`, the old caches kept, no binding; Retry
  then succeeds
- `unverified` with a cache → `.signedIn` with `isIdentityVerified ==
  false`; the next resolution with the same user → true
- `.sharedGardenUnavailable`: choosing `ownGarden` wipes once (confirmed)
  and clears the marker
- `.multipleSharedGardens` with one owned zone: choosing a shared zone keeps
  that owned household (not the deterministic one)
- `revalidateAfterAccountChange`: same user, different user, `noAccount`
- `DeterministicHouseholdID` is stable, UUID-shaped and lowercase

Delete or rewrite the server-identity cases in `AuthLifecycleTests` and
`SignInSyncOrchestrationTests` that no longer apply. Keep the assertions
about what wipes and what must not.

---

## Slice B — zero server transport, gating and quarantine (Luna; the parent builds and tests)

Files you own: everything not listed under slice A, except the contract
files. In `AppEnvironment.swift` you own `live()`'s client and session,
`syncIfPossible`, the notifier and listener startup, the watering wiring,
`recoverCommittedAccountDeletion`, the transfer cutover and the
deletion-coordinator wiring.

### B1. Transport

- `AppEnvironment.live()`: `SeedkeepClient(configuration: .init(baseURL:
  prefs.effectiveServerURL, session: ServerRetirement.makeRefusingSession()))`.
- Remove the raw `URLSession.shared` server call; it lives in `SignInView`,
  which slice A deletes.

### B2. Close every live server path (gate on `ServerRetirement.isRetired` at the call site; change component internals only where the work starts inside the component, as listed)

- `AppEnvironment.syncIfPossible`, CloudKit branch: skip
  `sync.syncAll(householdID:)` and the "Server sync — …" banner, so the
  banner comes only from CloudKit. The non-CloudKit branch is unreachable
  outside XCTest (invariant 4); leave it.
- Skip `PetStateEngine.performSideEffects` server departures. Keep the
  local `tickAll`.
- Do not start `CatalogCorrectionNotifier`.
- `SubscriptionManager`: no transaction-listener verify POST and no tier
  fetch (`refreshTier` and the like). The listener starts inside `init`,
  so gate it there.
- Automatic catalog fetches: `SeedDetailView` and `BedDetailView` (`.task`
  catalog loads), and any other view that fetches on appear.
- `RecommendationStore`: no fetches.
- `JournalStore`: no server feed (already CloudKit-gated; verify).
- `AIAssistantCoordinator`: no calls (already gated; verify).
- Settings health probe, server URL override, MCP, assistant key,
  subscription and tier rows: hidden.
- `WeatherWarningsService`: replace `SystemWateringStateClient(client:)`
  with a new `LocalWateringStateClient: WateringStateClient`, persisted
  per household ID in UserDefaults. Same semantics, device-local.

### B3. Hide server-only UI (do not delete code; N2 re-adds on-device versions)

- **Scan entry points:** the Library and Today add menus, the Workbench
  Seeds toolbar scan (iOS), and any "Scan packet" button. Manual Add Seed
  stays.
- **Barcode lookup.**
- **Catalog:** detail links from seed and bed detail, `CatalogDetailView`
  entry points, `CatalogFeedbackSheet`, contributions and corrections in
  You.
- **Recommendations:** the seed detail section, What to plant, Today's
  planting verdicts, and any verdict column or badge in the Workbench
  table. Cached `LocalRecommendation`s are stale, so don't show them.
- **Random pick** entry in the Library.
- **Home location:** keep showing the cached value; hide editing or saving.
  Weather keeps using cached coordinates.
- **Sprout and assistant entry points**, if any are reachable.

### B4. Account deletion quarantine

- `recoverCommittedAccountDeletion()`: no server call and no coordinator.
  If checkpoints exist, record their count for diagnostics and return.
  Never erase, sign out or recreate zones.
- Set `pausedDeletionCheckpointCount` from the checkpoint store. While it
  is above 0, `canUseCloudKit` is false; that is the quarantine against
  re-provisioning a deleted garden.
- Hide the "Delete account" UI. `AccountDeletionRootRoute.decide` never
  presents. RootView's presentation and the handoff notice belong to slice
  A.
- `adoptTransferredGarden` and `TransferredGardenCutover` are never invoked
  from a live path.
- Settings diagnostics show "Account deletion: N pending checkpoint(s)
  paused" when N > 0.

### B5. Tests

- `RefusingURLProtocol`: a request through `makeRefusingSession()` fails
  with `.cannotConnectToHost`, makes no network request, and increments
  the counter.
- The live path stays at zero refused requests, through a testable seam
  that runs the CloudKit-branch post-sync orchestration with a fake
  coordinator, or a structural test of the gates:
  - after `syncIfPossible`'s CloudKit branch, the counter is still 0
  - the pet side-effect gate
  - the notifier not started
  - the subscription listener not posting
- `LocalWateringStateClient` round-trips per household.
- The quarantine: with a checkpoint on disk, the launch sweep makes no
  server call, erases nothing, sets `pausedDeletionCheckpointCount`, and
  `canUseCloudKit` is false.
- `AccountDeletionRootRoute` never presents.
- The automatic catalog fetches and the subscription listener make no
  request (refusal count stays 0) when the views or manager are created.

---

## Gate (parent)

- `scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171`
  green: packages, iOS (CloudKit OFF and ON), macOS (OFF and ON).
- The new AuthController and ServerRetirement tests run in the default
  lanes. They don't depend on the CloudKit flag.
- A signed Mac build launches. The parent exercises launch, Seeds, settings
  and sharing screens while watching the `ServerRetirement` log category
  and the network log for `seedkeep-server.fly.dev`; both must stay empty.
  The owner's real-account check comes after N2.
- Opus and Sol review the merged N1 diff before commit.
