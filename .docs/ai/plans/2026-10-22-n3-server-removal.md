# N3 — Remove the server code, prepare release (contract)

Status: approved (2026-10-22) after two rounds of Sol's critique. Owner decisions are in the
umbrella `decisions.md` ([2026-10-22] N3). Branch
`redesign/r2-design-system`. Inputs: the N3 row of
`~/git/seedkeep/.docs/ai/phases/2026-10-20-apple-only-plan.md` and the N3
survey (summarised under "Keep" and "Remove" below).

## Owner decisions (fixed)

- **Delete account deletion and garden transfer entirely,** including the
  startup recovery and quarantine. A device with a paused checkpoint loses
  that transfer state.
- **Prepare the server-retirement runbook now:** export Postgres, revoke
  the Sign in with Apple tokens, delete the server accounts, tear down Fly
  (in that order; see D). The owner runs it; starting Fly is their external
  action.
- **The App Store privacy answer is "Data Not Collected", provisionally.**
  The policy discloses that BYOK sends packet photos from the device to the
  user's own provider account, and that WeatherKit receives the ZIP area.
  The answer stays provisional until the assessment in D; any unresolved
  finding blocks submission.
- **The policy's contact is support@finklea.dev.**

## Lead defaults (recorded in the same decision)

- Keep through 1.0:
  - the legacy identity rebind (`AuthController.resolveLegacy`)
  - the one-time server-to-iCloud migration (`HouseholdMigrationPlanner`
    and `HouseholdMigrationExecutor`, `hasMigratedDurable`)
  - `ParticipantRowRecovery`
- No SwiftData `@Model` is removed; unused models stay until a store-upgrade
  test exists. No CloudKit schema change.
- Hidden pets stay, since `PetDeparture` and `PetMoodSnapshot` sync through
  iCloud. Old changelog entries stay as history. SeedkeepKit is trimmed, not
  deleted. Herbarium's remaining pieces move later.
- The invite retirement notice (`InviteAcceptView`) stays for 1.0, so old
  invite links say what happened.

## Keep (looks server-era but is live)

- **`CloudSharingControllerView.swift`** (`CloudSharingPresenter`) drives
  "Share garden via iCloud". R2's dead-file list wrongly marks it dead; fix
  that list.
- **Sharing:** `AppEnvironment.prepareOwnerShare`, `processPendingShare`,
  `leaveSharedHousehold`, and the "Leave shared garden" Settings row.
- **CloudKit:** all of `Core/CloudKit/*` and the SeedkeepCloudKit package,
  plus `ActiveGardenContext` and `LiveCloudIdentityProvider`.
- **BYOK:**
  - `BYOKExtractor`, `APIKeyStore`, `APIKeysSettingsView`,
    `AIProviderSettingsView`, and the `KeychainService` key in Info.plist
  - `KeychainTokenStore` stays because it holds BYOK keys; only the
    server bearer-token account goes
- **On-device recommendations (N2):** `PlantingEngine`,
  `RecommendationStore`, `WeatherKitRefiner`, `ZoneFrostDates`,
  `ClimateLookup`, `PlantSuggestionRanker`.
- **Types the live code uses:**
  - the SeedkeepClient input structs used by `SyncEngine.enqueue*`:
    `CreateSeedInput`, `UpdateSeedInput`, `CreateBedInput`,
    `UpdateBedInput`, `CreatePlantingEventInput`,
    `UpdatePlantingEventInput`
  - `WireResponses.ExtractionFields`
  - `SeedkeepError` and `humanizeError`
  - `UserDTO` and `HouseholdDTO`, as used by `AuthController.State`
  - Move these into a small SeedkeepKit file before the client goes.
- **Herbarium:** `Solar` and `SunArc` are used by Today, and the types
  `WBComponents` depends on stay where they are.

## Invariants

- **Shipping behaviour doesn't change,** except that dead screens, flows and
  settings disappear. Every live screen and write path works as before.
- **No data-model or CloudKit schema change.** `SyncEngine.enqueue*` keeps
  its signatures and local writes. Under CloudKit it stops creating
  `LocalPendingWrite` rows, which nothing sends. Existing rows are left
  alone; the model stays.
- **Live seams to keep:**
  - Keep the exact-account bearer-token cleanup in the legacy rebind.
  - Never clear the whole Keychain service or change the BYOK service or
    account identifiers.
  - Remove the API URL resolver and its launch call before removing the
    API plist keys, on both platforms.
  - Keep the `KeychainService` plist key, `auth.restoreSession`,
    `ParticipantRowRecovery`, the frost backfill, fixture isolation, inert
    startup under XCTest, and macOS running startup only once.
  - Remove only the checkpoint gating. Keep the identity verification,
    the share-adoption gating and the coordinator's epoch and pause checks.
- **Launch order:**
  - Startup no longer reads `SeedkeepAPIScheme` or `SeedkeepAPIHost`
    (remove `resolveBundleDefaultURL` before removing the Info.plist keys).
  - Startup no longer runs account-deletion recovery or quarantine.
  - It still runs `auth.restoreSession()`, `ParticipantRowRecovery` and the
    frost backfill.
- **Tests:**
  - Tests that only exist for removed code are deleted with it. Mixed
    tests are edited, not dropped.
  - Each slice reports a per-test inventory: retain, rewrite or delete,
    with the replacement coverage named.
  - The gate's CloudKit-OFF lanes retire with the server path (in T).
    `ProductionDefaultCloudKitGateTests` is compile-guarded today, so
    removing the define would silently drop it. Its replacement, a
    production-path suite, compiles unconditionally.
  - **That suite covers:**
    - every `enqueue` create, update and delete, and explicit clears
    - the persisted local values
    - exactly-once mutation callbacks
    - no new `LocalPendingWrite` rows, with existing ones left unchanged
  - **Coverage that stays,** using fake CloudKit engines (an in-memory
    store alone doesn't prevent network access): photo staging, deletion
    and cache recovery; identity and the rebind; sharing; migration.
  - The gate runs the packages and the full iOS and macOS suites, with
    nonzero counts.
  - "Zero server transport" is structural (no client type, no API host),
    with a test that Info.plist has no `SeedkeepAPI*` keys and the app
    target has no server base URL.
- **Docs:** every removed type or file is greppable in the slice's report,
  and the iOS `decisions.md` records anything non-obvious.

## Slices

**Order:**
1. U and D may proceed independently.
2. A comes before T, because the account-deletion code still uses the
   client, the transfer DTOs and `AppEnvironment.client`.
3. T includes every affected test migration and retires the CloudKit-OFF
   lane.
4. F finishes the remaining flags and configuration.

Each intermediate commit must compile and pass its applicable gate. Each
slice gets the gate, an Opus review and a Sol review before its commit. A
and T go to Opus workers, because they carry data and launch risk. (Sol
suggested lighter workers; the owner's routing keeps Opus for stages that
need it.)

### U — Dead UI (worker)

- **Delete the unmounted screens:**
  - `YouView`, `ContributionDetailSheet`, `CatalogDetailView`,
    `CorrectionStatusPill`
  - `MCPSettingsView`, `AssistantKeySettingsView`, `ServerSettingsView`,
    `SubscriptionSettingsView`, `PendingWritesView`
  - `SproutFAB`, `TopBarSparkleButton`, and `Features/Assistant/*`
- **Remove `publishesAssistantContext`:** its 8 call sites and
  `PageContextPublisher`.
- **Remove the catalog-correction UI:** the "Correction outcomes" toggle,
  and the notification-centre code that only serves it. Keep the
  notification settings screen.
- **Remove the `CatalogFeedbackSheet` path** and its gate.
- **Tests:** delete the tests that only cover these, and fix the audit
  allowlist entries that name removed labels.

### D — Docs, site and release prep (worker)

Files: `seedkeep-ios/web/src/routes/privacy`, `web/src/routes/support`,
`.docs/ai/app-store-submission-notes.md`, the R2 plan's dead-file list,
`ChangelogData` (no new entry until R5), and a new runbook.
- **Privacy page:**
  - replace "You → Settings" paths with the current Settings paths
  - contact support@finklea.dev, removing the personal address
  - disclose BYOK (photos go from the device to the user's own Anthropic
    or OpenAI account; the provider's terms apply) and WeatherKit (the ZIP
    area)
  - deletion is the in-app "Delete data" path once N2-E lands. Until then,
    explain deleting the iCloud data in Settings → Apple ID → iCloud.
  - keep the effective date current
- **Support page:** current paths and contact.
- **Submission notes:** remove Sign in with Apple, IAP, the server and
  "collects data"; add BYOK and WeatherKit for review.
- **Runbook** (`~/git/seedkeep/.docs/ai/phases/2026-10-22-server-retirement-runbook.md`):
  1. Start only the database resources needed, with the API and worker
     ingress kept stopped.
  2. Export and restore-verify a protected local backup, and set how long
     it is kept.
  3. Revoke the users' Sign in with Apple authorizations while their tokens
     still exist. Apple's revoke endpoint needs each user's access or
     refresh token as well as the signing key.
  4. Then delete the server accounts.
  5. Tear down the exact named resources.
  - Missing tokens or failed revocations are explicit blockers.
  - No secrets in arguments, output or logs.
  - Removing the App ID capability and retiring the IAP products each need
    their own exact-target owner authorization.
  - Every step is the owner's, with verification commands.
- **Before submission:** document the BYOK and WeatherKit assessment against
  Apple's definition of "collect", which includes third-party partners, and
  escalate any conflicting evidence. WeatherKit receives home-location
  coordinates, which may come from the ZIP.
- **Verify the deletion instructions** on both platforms. Publication and
  release wait for N2-E's tested deletion.
- **Not published.** Deploying the Worker is a separate owner go-ahead.

### T — Server transport and sync (worker-opus)

- **First, extract the survivors.**
  - Extract the six inputs as top-level SeedkeepKit types, and update
    every qualified reference.
  - Preserve their fields, initializers, and the difference between an
    omitted field and an explicit null.
  - Retain every type the live code uses, directly or through other types,
    including `SeedState`, `SeedSource`, `PhotoRole`, `PlantingEventKind`
    and the pet value types.
  - Trim `Wire.swift` symbol by symbol, never wholesale. `UserDTO`,
    `HouseholdDTO` and `ExtractionFields` live there; `SeedkeepError` lives
    in `Envelope.swift`.
- **Then delete:**
  - the client and its endpoints, wire DTOs and maps (`Mapping.swift` DTO
    parts)
  - SyncEngine's legacy pull, push, flush, upserts and delta cursors
  - JournalStore's server branches
  - `AIAssistantCoordinator`, `SubscriptionManager`,
    `SystemWateringStateClient`, and the pet server calls
  - `AppEnvironment`'s client wiring, `setServerURL`, `refreshTier` and
    `resolveBundleDefaultURL`
  - the bearer-token account in `KeychainTokenStore`
  - the server prefs (`serverURL`, `cachedTier`)
- **`SyncEngine(client:)` callers and test support** are rewritten for the
  new initializer.
- **Server-only tests are deleted** (the survey's list). Mixed tests are
  edited.

### A — Account deletion and transfer (worker-opus)

- **Delete:**
  - `Core/AccountDeletion/*` and `Features/AccountDeletion/*`
  - `TransferredGardenCutover`, `adoptTransferredGarden`, and the handoff
    link parsing for `/garden-handoff`
  - the checkpoint store and quarantine, the launch recovery call, and the
    paused-checkpoint diagnostic row
- **CloudKit is never paused by a checkpoint again.** The CloudKit pause
  logic that only served checkpoints goes; any other pause reason stays.
- **Losing transfer progress isn't the same as reviving a garden.** The
  owner accepted losing a paused device's transfer progress, not
  resurrecting deleted data or uploading partial state.
  - Before removing the quarantine, define and test what happens to:
    - retained local rows
    - pending CloudKit saves and deletions
    - migration receipts and markers
    - participant state
    - transfer-workspace bytes
    - the checkpoint JSON files on disk, including damaged ones. They live
      outside SwiftData, so removing the store code leaves them behind.
  - If the safe outcome needs any re-provisioning or re-upload, stop and
    bring the conflict to the lead for owner acceptance before
    implementing it.
- **Delete the tests that only cover these;** edit `AuthLifecycleTests` and
  the others that also cover live behaviour.

### F — Flags, test lanes, config (worker-opus)

- **Collapse the flags:**
  - `FeatureFlags.cloudKitHouseholdSyncEnabled` and
    `serverGardenFeaturesRestricted` become always-on and are removed.
  - `ServerRetirement` and its gate sites go.
- **Tests:**
  - Retire `SEEDKEEP_TEST_CLOUDKIT_ON` and the CloudKit-OFF lanes in
    `scripts/test-gate.sh`.
  - Tests that relied on CloudKit-OFF behaviour are rewritten for the
    CloudKit path with in-memory stores, or removed if they only covered
    server mode.
  - **The gate becomes** the packages plus the iOS and macOS app tests. The
    CloudKit production-default contract stays as a test.
- **Config:**
  - Remove the `SeedkeepAPIScheme`/`Host` keys from Info.plist (iOS and
    macOS), `project.yml` and `AppConfig.example.xcconfig`.
  - Remove the Sign in with Apple entitlement from `project.yml` and both
    entitlement files; the App ID capability is a runbook step.
  - Remove server comments in the entitlements.
- **Tests:** the structural zero-transport test, and the per-platform
  gate.

## Verification

- **Gate** after each slice; the Mac app builds.
- **Screenshots and audit:** the R3 and R4 screenshot scripts still reach
  every step (UI unchanged); rerun the audit and compare with R4's 339.
- **Store compatibility:**
  - Open and exercise a disk-backed fixture produced by pre-N3 code,
    keeping its pending writes, tombstones, relationships and photo
    references.
  - Test upgrades from a legacy identity, and from interrupted deletion
    and transfer states, including missing migration markers and staged
    changes.
  - Real-device upgrade, sharing and convergence checks stay separate from
    the automated evidence.
- **Owner checks:**
  - an upgrade install on a device that ran an older build: the garden is
    intact and sharing works
  - the published privacy and support pages (after go-ahead)
  - the runbook steps
