# Current State

## Declared OS 26 floors; OS 27 verification accepted (2026-11-17)

The owner chose “os 27 is good enough” after minimum-OS resource preflight.
`seedkeep-ios-k97.12` therefore verifies current OS 27 and declared 26.0
build floors; actual OS 26 execution is untested. Floors remain unchanged.
Fresh unsigned generic iOS-device/simulator builds passed; all app Mach-O
and plist minimums are 26.0 with SDK 27.2. Inspected prior signed Mac metadata
also says 26.0. Comments now accurately retain model-availability/OCR fallback
and avoid stale host/CI claims; non-comment configuration is identical.

Main gate passed 25/176/iOS 1,449+1 skip/Mac 1,464+1 skip; signed Mac/strict
verification passed on host 27.0.1. Separate native Terra source/artifact
review passed. DD9 is verified Shutdown on iOS 27.0; the earlier audit report
now distinguishes this runtime from SDK 27.2 using preserved result metadata.
No OS download, cache cleanup, new simulator or VM was performed. This scope
choice does not grant release acceptance; R5 accessibility/device/CloudKit and
owner release work remain. Results: `plans/2026-11-17-minimum-os-26.md`.

## Prompt contrast verified; accessibility acceptance open (2026-11-17)

`seedkeep-ios-65p.1` repaired three Add Seed identity prompts with existing
`WBColor.muted` (product patch `ef82bdb0`). Measured dark contrast rises from
2.4016:1 to 5.96:1; light is 6.5289:1. All twelve captured prompts and four
configuration draft checks are verified across runs. Earlier private helper
failures are preserved. No palette, layout, driver, manifest or allowlist change.
Main gate passed 25 / 176 / iOS 1,449 + one skip / Mac 1,464 + one skip;
signed Mac and strict signature verification passed. Separate native Terra
review covered source, artifacts, pixel measurements and runtime evidence.

The unchanged baseline completed 124 checkpoints / 408 finding callbacks.
The post-repair full walk records 114 checkpoints / 384 callbacks / 170
suppressed / five unused entry-config pairs, with three navigation aborts:
API Keys in both default sizes and journal entry in light XXXL. Coverage is
incomplete; the desktop update lost the parent's exact outer exit receipt.
A fresh-fixture follow-up reached all three screens and completed each audit,
retaining nine unfiltered callbacks (exit 65, no setup/API error). This does
not resolve the original walk failures or establish an audit-wide pass.
Parent `seedkeep-ios-65p` and broader R5 remain open; counts are not bug deltas.

Results: `plans/2026-11-17-accessibility-remediation.md`. Full synthetic
results, failures, source patches and hash manifests are privately archived
in `.git/seedkeep-agent-patches/2026-11-17-a11y-remediation/`. DD9 is verified
Shutdown. Manual VoiceOver, minimum-26 runtime, device/data-preservation,
live CloudKit and release acceptance remain separate.

## Cold startup and scrolling — scoped checks verified (2026-11-17)

`seedkeep-ios-5ff` verified three fresh processes per target on Mac and the
approved iPhone/iPad simulators with a private 1,000-seed fixture. iPhone list, iPad table and Mac guarded wheel traversal
passed first/middle/end/return checkpoints with sampled order/readbacks.
Separate native Terra reviewed source, artifacts and retained runtime evidence.
Main gate passed Kit 25 / CloudKit 176 / iOS 1,449 + one expected skip /
Mac 1,464 + one expected skip; signed Mac/system-trust verification passed.
Shipping source stays `914bff3`; private QA drivers are archived, not integrated.
UI launch latency, frame/hitch performance and trackpad remain unmeasured.
First-use pipeline samples use a simpler fixture than the warmed 50 ms gate.
Earlier driver/profiler failures remain preserved. R5 is still open.
Results and limits: [cold-start/scroll report](plans/2026-11-17-cold-start-scroll.md).

## Seed-table timing gate — verified (2026-11-17)

`seedkeep-ios-219` now has a passing main gate: Kit 25 / CloudKit 176;
iOS 1,449 passed + one expected skip; Mac 1,464 passed + one expected skip.
The sorter moves indices instead of large rows, preserving comparison/data
rules. A mandatory serial XCTest checks the same full 1,000-row workload and
hard 50 ms limit after ten-row warmup of all measured paths. Both app gates
require XCTest and Swift Testing counts. Focused checks, signed Mac/strict
verification and separate native Terra source review passed. This measures
warmed operations; separate isolated cold/scroll checks are recorded above.
Wider R5 acceptance remains open.
Earlier failures and rejected prototypes remain documented. No mapper change,
device action, push or release. Results: `plans/2026-11-17-seed-table-timing.md`.

## R5 Roshar update — startup and relaunch observed (2026-11-16)

CoreDevice accepted the preserved 1.0.0 (54) candidate from `199e47c`
(application code `63b5709`) in place on Roshar, iOS 27.2.1. The owner
accepted proceeding without a recent backup or pre-upgrade garden baseline;
the old build stopped at Apple sign-in. The new app opened its garden and
retained the same two beds, two active seeds and sampled details after one
controlled relaunch. CloudKit Settings diagnostics were visible; their
record-count label is a local engine-store count, not a transfer receipt.

Photo-cache fix (`seedkeep-ios-8ii`) is implemented and verified on Sel. Cleanup now
compares filenames within the enumerated directory, preserving the new file
when equivalent URLs compare unequal. Focused cache suites passed 17/17 on
iOS and Mac; native Terra approved code, signed artifact and device evidence.
The owner-requested fixed normal 1.0.0 (54) remains on Sel. The original photo
renders before/after one cold relaunch; its one 87,110-byte cache file retains
its filename/mtime/hash and matches the protected Mac original. No picker,
manual sync, user edit or Roshar action occurred; owned automation stopped.
At that photo-fix checkpoint, the main gate passed Kit 25 / CloudKit 176 /
iOS 1,448 + one skip, but Mac had 1,462 passed / one skip / one timing failure
(78.496 ms; isolated retry 72.914 ms). Signed Mac/strict verification passed.
The November 17 timing verification above supersedes that failed-gate state;
its earlier results remain preserved. No threshold change, push or release.
Diagnosis and results:
`plans/2026-11-16-photo-loading-diagnosis.md` (`seedkeep-ios-6y0`).
Full preservation,
prior-source/account equality, remote round-trip, minimum-26, VoiceOver,
the 345-report audit and release acceptance remain open. R5 is not complete. Seedkeep and WDA remain installed;
the owned WDA runner/diagnostic stopped and its endpoint refused connection.
Results/limits: `plans/2026-11-16-roshar-update-check.md`. Tracking:
umbrella `seedkeep-30f.5`, native handoff `seedkeep-ios-ezm`. That earlier
acceptance changed no app source; the cache fix above is the later source repair. No push.
Physical captures remain private task-temporary evidence.

## R5 automated release readiness — targeted checks passed (2026-11-13)

Four unique normal-render layout cases now pass across the recorded runs:
bed/square details and Add Seed at default/Accessibility XXXL. The owner
approved a separate native Terra agent after `worker_hard` was unavailable.
Its isolated QA helper correction matches the lowercase Notes header and
selects the actual TextField. Both Add Seed tests passed (2/0 failures/0
skips), including full-frame/hittability checks and Cancel/form dismissal.
The XXXL case also passed picker readbacks. No app source or shipping QA code changed;
the earlier failed runs remain preserved. Application code stays `63b5709`.

Two signed Mac sample launches opened their initial window without recovery.
A focused TextField → Outline → TextField sequence passed with keyboard mode
0 unchanged; full Tab order and normal owner-account startup remain open.
Final full-gate retry passed: Kit 25, CloudKit 176, iOS 1,447 + one expected
skip, Mac 1,462 + one expected skip; signed Mac/strict codesign passed. One
iOS 50 ms timing check first failed, passed alone, then passed in the full
retry; no threshold or app change. Failed-gate logs remain, but its raw result
bundle is unavailable; focused/retry raw results are preserved. Local
schema parity, version dry run and five fake-backed release checks passed.
Before-commit follow-up receipts and independent reviews must accompany the
frozen patch. Source/build observations remain distinct from release archives.

All 345 historical audit reports remain unresolved; their original raw
temporary paths are absent. VoiceOver remains deferred. Runtime evidence is
iOS 27.0 / macOS 27.0.1, not minimum-26 acceptance. Physical-device upgrade,
live CloudKit and release acceptance remain open; R5 is not complete.

Checklist: `plans/2026-11-13-native-release-readiness.md`; detailed Results:
`plans/2026-11-05-r5-local-acceptance.md`. Evidence:
`/private/tmp/seedkeep-r5-readiness/`; private archive
`.git/seedkeep-agent-patches/2026-11-13-r5-readiness/` (Terra follow-up separate).
Tracking: native `seedkeep-ios-k97.10` / `k97.11`, audit `65p`; umbrella
`seedkeep-30f.1`. Local only; no push/release or personal/live data change.

## N2-E guard implemented — R5 owner acceptance next (2026-11-05)

Native iOS, iPadOS and macOS only. Branch `redesign/r2-design-system` is local
only: G1 `a5add72`, G2 `c239d06`, G3 `cf64db0`. G1 supplies account-keyed
binding/grants/discovery; G2 supplies detection, participant rules and the
write fence; G3 supplies the every-window choice and resumable Keep/Discard/
silent re-home journals. Missing/hash-invalid photo rows drop atomically,
including recovered journal photos; enumeration failures stop/retry. Shared
IDs stay retired on this device/account even after a new invitation.

Final worktree/main code gates passed: SeedkeepKit 25, CloudKit 176, iOS
1,439 passed + one opt-in fixture-generator skip, macOS 1,454 passed + the
same skip. Signed Mac Debug build/strict codesign passed. Exact read-only Sol
CLI and DeepSeek approved the committed source. Gone passed 4 tests / 8 PNGs,
R3 4 / 32, R4 4 / 28; every step reached.

The four-configuration accessibility audit completed with **345 unresolved
findings**, versus N3's recorded 309 (+36). It exited nonzero on findings;
there were no aborted, errored, timed-out or unreached checkpoints. Exact
per-element changes cannot be reconstructed because the old raw bundle is
unavailable. This is not accessibility acceptance. Triage is
`seedkeep-ios-65p`; owner VoiceOver/manual checks remain open.

Contract Results and the seven accepted limits:
`.docs/ai/plans/2026-10-22-n2e-deleted-garden-guard.md`. R5 (`seedkeep-30f` in
the umbrella) needs owner-approved iPad/Mac runtime, manual accessibility,
older-build device upgrade, live throwaway-garden/optional spike checks and
separate release approvals. No picker, Portview, iPad, live-account, personal-
device or manual Mac runtime checks were performed. No push.

Task worktrees were removed after frozen-hash checks; patches are archived in
`.git/seedkeep-agent-patches/2026-11-05`. Seasonal care is untouched. Resumption
tracking: native `seedkeep-ios-eee` / umbrella `seedkeep-qjx`.

## N3 done (2026-10-22): the server code is gone

Contract: `.docs/ai/plans/2026-10-22-n3-server-removal.md`. Branch
`redesign/r2-design-system`, local only (not pushed).
- **Done:**
  - U (6398d39): the dead UI is gone (You, catalog corrections,
    the assistant, the MCP, server, subscription and pending-writes
    settings). Retired catalog notifications are cleared at launch.
  - D (91da158): privacy, support and home pages, the AASA file and the
    submission notes. The website is not deployed.
  - A (c632a33): account deletion and garden transfer are gone. The owner
    confirmed no device ever started one, so launch only deletes the
    leftover checkpoint and transfer folders; checkpoints no longer pause
    CloudKit. Gate 97 / 148 / 1291 + 1 / 1306 + 1.
  - T1 (0c0efdd): the server client and server sync are gone. Writes no
    longer queue `LocalPendingWrite` rows; old rows stay. A pre-N3 store
    fixture covers every model. Gate 25 / 148 / 1240 + 1 / 1255 + 1.
  - T2 (1105dd0): every test runs on the CloudKit path over fake
    engines (`CloudCoordinatorFactory`); the sync flag and the
    CloudKit-OFF lanes are gone. Gate 25 / 148 / 1242 / 1257.
  - F (55fb1b3): `ServerRetirement`, the API plist keys and the Sign in
    with Apple entitlement are gone; the release verifier now forbids
    that entitlement. `ZeroServerTransportTests` checks the built app.
    Gate 25 / 148 / 1243 / 1258.
- **Verification:** R3 32/32 and R4 28/28 screenshots; audit 309
  findings (R4 339), no new real defect. Results are in the contract.
- **Next:** N2-E (delete data; never recreate a deleted garden's zone),
  then R5.
- **Owner:** the server-retirement runbook is in the umbrella repo,
  owner-run and not executed.

## R4 done (2026-10-21): Today, Journal, Settings and CSV import

Contract and results: `.docs/ai/plans/2026-10-21-r4-today-journal-settings.md`.
Branch `redesign/r2-design-system`, local only (not pushed).
- **Today:** a This week block (the frost warning, then seeds to plant
  now or soon, and See all in Windows) and "<n> more due".
- **Journal:** search over text and attachments; filters by seed, bed or
  planting in submenus; saves re-check the garden.
- **Mac:** Settings is a standard Settings window (⌘,); the sidebar
  drops it. The Server, Subscription and Hosted settings are gone.
- **Seeds:** CSV import with a preview. Matching rows update, and export
  round-trips.
- **Verification:** gate 97 / 148 / 1562 + 1 / 1577 + 1; R4 screenshots
  28/28; audit 339 findings, all in recorded noise categories.
- **Owner checks pending:**
  - the Mac Settings window and a real CSV import on the Mac
  - Journal search on iPad
  - earlier: iPad and Mac Garden and Windows, VoiceOver, the manual
    checklist
- **Next:** N3 (remove server code, retire legacy accounts), then N2-E,
  then R5.

## R3 done (2026-10-21): Garden grid and planting windows

Contract and results: `.docs/ai/plans/2026-10-21-r3-garden-windows.md`.
Branch `redesign/r2-design-system`, local only (not pushed).
- **Garden:** beds plan on a square-foot grid you paint with a seed.
  - Square details edit one planting; Move uses tap or VoiceOver actions.
  - New/Edit bed take decimal sizes. A stored size can't be cleared; see
    `decisions.md`.
  - iPad and Mac get a bed switcher and the inspector; iPhone keeps the bed
    list and opens a bed screen.
  - The bed canvas and slider placement are gone.
- **Windows** (⌘5; Garden toolbar on iPhone) replaces What to Plant: a
  season timeline on regular width, a grouped list on compact. Plan hands a
  seed to Garden in either shell.
- **Frost:** a Today banner for plantings in the next two weeks, a glyph on
  due rows, and the frost sentence in Add Planting and square details.
- **Verification:**
  - gate 97 / 148 / 1386 + 1 / 1401 + 1
  - scripted iPhone screenshots (`scripts/r3-screenshots.sh`): all 32 steps
    reached
  - audit: 283 findings, compared with R2d's 289
- **Owner checks pending:** iPad and Mac at runtime (Garden, the Windows
  timeline, keyboard), VoiceOver per the manual checklist's bed grid
  section. The iPad simulator needs approval.
- **Next:** R4 (Today, Journal, Settings and flows).

## R2d done (2026-10-21): accessibility audit

The owner's choice: fix the real defects, then move on to R3.
- **Triage** (1b24c2b): the real fixes landed (filled-button text in dark
  mode, form footer contrast, canvas label backgrounds, separators read by
  VoiceOver), with 80 accepted limitations.
- **Second run:** 289 unresolved findings, down from 512, recorded as
  suspected audit noise in the R2 plan. Rerun before release.

### Before the triage

- **Sample-garden mode is self-contained and repeatable** (0f56b3c).
  - It makes no WeatherKit, Keychain or notification-permission calls.
  - Launches are repeatable: fixture preferences, a fresh scratch
    directory, a fixed random pick.
  - The audit launch fails closed.
  - Accessibility identifiers are on tabs, rows, Settings rows and screens.
- **The audit harness** (5a57e35):
  - `SeedkeepUITests` in its own `SeedkeepAccessibilityAudit` scheme,
    outside the gate.
  - Run it with `scripts/a11y-audit.sh <simulator UDID>`, about 30 minutes
    for 4 iPhone configurations.
  - The manual checklist is `.docs/ai/plans/2026-10-20-a11y-manual-checklist.md`.
- **The first run found 512 issues:** Dynamic Type 244, contrast 182,
  clipped text 86; 148 have no element.
  - Many look like audit false positives (text that scales in the
    screenshots, pixel sampling under translucent bars, system nav
    buttons).
  - The audit doesn't pass yet. Triage and fixes are the next step; how
    deep to go is the owner's decision.
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 1187 + 1, macOS
  app 1202 + 1.

## Native Workbench redesign — R2c complete (2026-10-20)

R2c turns dark mode on and fixes contrast, large-text and VoiceOver defects.
It's on `redesign/r2-design-system`, local only.
- **Appearance:** Light / Dark / System in Settings (`seedkeep.appearance`,
  per device). Applied by a view modifier at each window root. The launch
  screen has light and dark backgrounds.
- **Contrast:** `WBPalette` and `WorkbenchContrastTests` check WCAG ratios
  for text and graphic pairs, the chart marker against every ramp segment,
  and token resolution on iOS and macOS.
  - **Combinations fixed:** the photo retry icons (`warnInk`), the chart
    marker (halo), readable `faint` text (now `muted`).
- **Sample-garden isolation:** the appearance, What's New and notification
  toggles use the fixture suite (`DevicePreferences`). A sample-garden
  session never prompts for, schedules or clears real notifications.
- **Large text and VoiceOver:**
  - **Journal:** the date sits above each entry at accessibility sizes.
  - **What's New:** VoiceOver says "new" when there's something unseen.
  - **Bed canvas:**
    - VoiceOver can move plantings, sharing one movement path with drag.
    - Positions snap and clamp to the bed (fixes the 2.3 ft → 2.5 bug).
    - Each planting is one element; labels don't overlap or clip.
  - **Pickers:** at accessibility sizes the State, Location and Source
    pickers push a list (iOS).
  - **Seeds on iPad and Mac:** the bulk bar wraps; the toolbar stacks
    without losing search focus; narrow iPad layouts start with the
    inspector closed.
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 1166 + 1, macOS
  app 1181 + 1, on Xcode 27.1.
- **Reviews:** Sol critiqued the contract over three rounds. Opus and Sol
  reviewed each slice.
- **Plan and results:** `.docs/ai/plans/2026-10-20-r2-design-system.md`.
- **Open (owner):**
  - the Mac visual and keyboard check
  - iPad screenshots (simulator approval)
  - VoiceOver on the bed canvas
  - a dark-mode glance on the phone
- **Next:** R2d, the automated accessibility audit with its own scheme. Then
  R3.

## Native Workbench redesign — R2b complete (2026-10-20)

R2b finishes the Workbench look for the remaining Herbarium screens. It's on
`redesign/r2-design-system` after R2a, and is local only.
- **Tabs (compact interface):** Today, Seeds, Garden, Journal and Settings.
  Settings replaced You. YouView is unreferenced (its server-era rows were
  already hidden) until N3. On iPad and Mac, the Settings route opens
  Settings directly.
- **Seeds (compact):**
  - A list built on R1's row model and search.
  - A state filter with counts that follow the search: segmented, or a menu
    at accessibility sizes.
  - Rows show type, variety, company, year and the planting verdict.
  - Group by type, as before.
- **Today:**
  - A daylight panel, with a polar day/night message.
  - The Due queue (one queue, six rows), now showing the event kind and an
    overdue warning icon.
  - The latest journal note.
- **Settings:** one Workbench form with these sections: Account, Seeds, Home
  and alerts, AI, Sync (unchanged), Diagnostics, About (version row).
- **Shared:**
  - `WBScreenTitle` and `WBMetrics.screenGutter`.
  - `AppEnvironment.isSyncingForDisplay`, so loading states see CloudKit
    sync.
  - `WBSectionHeader` in the remaining forms.
  - Layouts stack at accessibility text sizes.
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 1096 + 1, macOS
  app 1111 + 1, on Xcode 27.1.
- **Reviews:** Sol critiqued the contract over three rounds. Opus and Sol
  reviewed the merged change. The iPhone screenshot review is done.
- **Contract and results:** `.docs/ai/plans/2026-10-20-r2-design-system.md`
  (R2b sections).
- **Open:** the regular-width iPad screenshots (the iPad simulator needs the
  owner's approval to drive) and the owner's Mac visual check.
- **Next:** R2c (the appearance setting and dark mode, contrast, the large-text
  items deferred from R2a, and VoiceOver and keyboard acceptance).

## Native Workbench redesign — R2a complete (2026-10-20)

R2a restyles the app in Workbench with no behaviour change. It's on branch
`redesign/r2-design-system`, stacked on N2, and is local only.
- **Foundation:** `WBType` (system text styles, so text scales),
  `WBComponents` (section header, banner, status chip, empty state, daylight
  panel, screen background, `.wbPanel`, `.wbForm`, progress style), and
  `WBMetrics.minTouchTarget` (44pt on iOS, intrinsic on Mac). AccentColor and
  the app tint are `WBColor.accent`; the tab bar uses system fonts.
- **Restyled:**
  - Garden, Journal and Add Seed
  - seed detail, the planting panel, scan chrome, random pick, invite and
    What's New
  - the Settings sub-screens
  The Latin headings, folios, ornaments and pressed-plant art are gone. The
  copy is plain ("Garden", "Journal", "Garden bed").
- **Planting chart:** it now has a VoiceOver summary. The "Your date" marker
  and the summary use the local day the picker shows (the marker used the UTC
  day before).
- **Sample garden (debug only):** the `-SeedkeepFixture` launch argument runs
  the app on an in-memory sample garden with no CloudKit, for screenshots.
  `verify-release-archive.sh` fails if it's in a Release build.
- **Still Herbarium until R2b:** Seeds (LibraryView), Today, You and the main
  Settings list. `HerbSpace` stays as a layout constant until N3.
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 1060 + 1, macOS
  app 1075 + 1, on Xcode 27.1. **Reviews:** Opus 5.5 and GPT-6.1 Sol, two
  rounds plus confirmations.
- **Contract:** `.docs/ai/plans/2026-10-20-r2-design-system.md`.
- **Screenshot review:** done for Garden, bed detail, Journal, journal entry,
  seed detail, the planting panel, Add Seed and random pick, at the default
  and largest text sizes. Fixes for the planting panel, status chip and
  random pick landed after the review; the deferred items are listed in the
  R2 plan.
- **Not done:** screenshots of the Settings sub-screens, What's New, invite,
  scan chrome and regular-width iPad, and the owner's Mac visual check. Light
  mode is still forced until R2c.
- **Next:** R2b (the compact Seeds list, Today, and You folded into
  Settings), then R2c (dark mode and accessibility acceptance).

## Apple-only app — N2 complete (2026-10-20)

N2 brings back, fully on the device, what N1 hid. On branch
`redesign/n1-apple-only` after N1; local only.
- **Home location:** ZIP only, looked up in a bundled table
  (`Seedkeep/Resources/Climate/zip_climate.csv`, 33,751 ZIPs; zone frost dates
  in `ZoneFrostDates.swift`; sources in `SOURCES.md`). Existing ZIPs get frost
  dates filled in at launch.
- **Planting recommendations:** the server's rule engine and projection ported
  to Swift (`PlantingEngine`), keyed by seed and computed from each seed's
  growing info and the local date. No AI fallback, no extension calendars.
  Seeds without usable growing info show no window.
- **Scanning:** extraction on device (or BYOK) saves locally; both packet
  photos become the seed's photos. Staging is durable, scoped to the iCloud
  user and garden, purged on any account or garden change, and resumed after a
  verified launch. No barcode or catalog step.
- **Random pick:** local, weighted by packet age, in the active garden; also
  in the Workbench (Seeds toolbar, menu, ⌘K).
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 1043 + 1, macOS
  app 1058 + 1, on Xcode 27.1. **Reviews:** Opus 5.5 and GPT-6.1 Sol, three
  rounds plus confirmations.
- **Contract:** `.docs/ai/plans/2026-10-20-n2-on-device.md`.
- **Still to do:**
  - N2-E, "Delete Seedkeep data" plus handling a garden deleted elsewhere. The
    contract draft was rejected by Sol and needs redesign (account-bound
    retired gardens, no zone resurrection).
  - The owner's real-account check on Mac and iPhone.
  - N3: remove the server code, privacy policy and labels, retire legacy
    accounts, and verify the zone-data redistribution terms.

## Apple-only app — N1 complete (2026-10-20)

The app no longer needs the Seedkeep server (Fly has been stopped since
2026-10-15). On branch `redesign/n1-apple-only`, stacked on R1; local only.
- The iCloud account is the identity; there is no sign-in screen. Existing
  installs rebind to their CloudKit garden in place, with no wipe.
- New screens: "Sign in to iCloud" (and restricted / couldn't verify), and a
  garden chooser for ambiguous accounts.
- No request reaches the server: a refusing transport, gated callers, and
  server-only features hidden (scan, catalog, recommendations, random pick,
  home-location editing, account deletion). N2 brings back what can run on
  the device.
- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 916 + 1, macOS
  app 931 + 1, on Xcode 27.1.
- **Reviews:** Opus 5.5 and GPT-6.1 Sol, four rounds plus confirmations.
- **Contract:** `.docs/ai/plans/2026-10-20-n1-apple-only-entry.md`.
- **Not verified:** live CloudKit identity and garden discovery with a real
  account; that is the owner's device check after N2.
- **Known flake:** `SeedsTableModelTests` "1,000 seeds under 50 ms" fails on
  the iOS simulator under heavy machine load; its code path is unchanged
  since R1.

## Native Workbench redesign — R1 complete (2026-10-18)

R1 is on branch `redesign/r1-shell-seeds`, commit `16ec7b9`. It stacks on M0
and is local only, not merged or pushed. On regular-width iPad and on Mac,
the app now shows the Workbench:
- a sidebar shell
- a spreadsheet-style Seeds table: sorting, multi-select, filters, inline
  edits with undo, bulk actions, an inspector, CSV export and packet scanning
- menus and shortcuts, and a ⌘K command palette

iPhone, including Plus/Max in landscape, keeps the tab UI unchanged.

- **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 854 + 1, macOS app
  868 + 1, on Xcode 27.1.
- **Reviews:** Opus 5.5 and GPT-6.1 Sol, with three rounds plus confirmations.
- **Contract and known limitations:**
  `.docs/ai/plans/2026-10-17-r1-shell-seeds.md`.
- **Not yet verified by hand:** the signed-in iPad table layout, VoiceOver,
  keyboard-only use and 1,000-seed scrolling. Simulators can't sign in.
- **Next:**
  - owner review of R1
  - R2: the design-system rollout, dark mode, Dynamic Type and the compact
    iPhone restyle


## Native Workbench redesign — M0 complete (2026-10-16)

The app stays native. It's being redesigned in the Workbench style for
iPhone, iPad and Mac, and the redesign ships as 1.0. Plan:
`~/git/seedkeep/.docs/ai/phases/2026-10-15-native-workbench-redesign-plan.md`
(approved 2026-10-15).
- **V1 build-55 plan retired:** the sections below are kept for history
  only.
- **M0 (native macOS build of the current app) is done** on branch
  `redesign/m0-mac`, commit `b363a92` (seed `908b60f`, scheme fix
  `d2c5ab6`).
  - **Gate:** SeedkeepKit 97, SeedkeepCloudKit 148, iOS app 769 + 1, macOS
    app 783 + 1; all passing on Xcode 27 with the iOS 27 simulator.
  - **iOS behaviour unchanged:** the share, photo and lifecycle paths are
    identical to the previous code.
  - **Reviews:** Opus 5.5 and GPT-6.1 Sol across three rounds; both report
    no blocking issues.
- **Unsigned smoke test (2026-10-16):**
  - The Mac Debug build launched and stayed running for more than 5 min,
    with a 1690×992 on-screen window and no crash or fault logs.
  - A screenshot wasn't possible because the Claude app lacks the macOS
    Screen Recording permission.
- **Capability matrix and signed-check plan:**
  `.docs/ai/plans/2026-10-15-m0-capability-matrix.md`.
- **Next:**
  - R1 (shell and Seeds table).
  - Signed Mac checks need the owner's approval for macOS signing and
    provisioning.
- **Local setup:**
  - Simulators "Seedkeep iPhone" (`DD9BE2B2…`) and "Seedkeep iPad"
    (`1B4EF142…`) on iOS 27.
  - `scripts/test-gate.sh --simulator-udid <iPhone>` runs both platforms.


## Combined QA preparation — 2026-09-29

The canonical cross-repo dashboard and execution procedure are maintained in
the umbrella checkout: `/Users/tfinklea/git/seedkeep/.docs/ai/current-state.md`
and `phases/2026-09-29-combined-qa-session.md`. This checkout is the V1
main source at `f3e3c59`; build `1.0.0 (54)` remains rejected, its counter is
unchanged, and no new hands-on result was reported in this preparation pass.

Resume the approved V1 checks first: verify the exact You → Settings build
stamp/install source, enter and save the Home ZIP, scan the prepared online
barcode card from Library's viewfinder, record the raw detection and catalog
match before saving, inspect Seed Detail planting guidance, relaunch, and
record same-account iPad receipt. Device/install provenance and the catalog
match remain unknown. Earlier photo attempts ended in `Server Record Changed`,
and the scalar sender save has no receiver-convergence proof.

Seasonal care remains isolated on `seedkeep-ios-seasonal-care` at `3e62f2e`
with schema companion `seedkeep-seasonal-care-schema` at `d936cff`; source
child `seedkeep-p49.1` and QA preparation `seedkeep-p49.2` are closed while
parent `seedkeep-p49` remains open. V1 `seedkeep-27d.33` and historical
build-54 `seedkeep-27d.32` remain open. Keep care writes out of this V1 data
graph until the supported isolated same-account care path is established or V1
is accepted. The user authorized scoped documentation/Beads commits and branch
pushes; verified publication and remote readback are recorded in the canonical
`/Users/tfinklea/git/seedkeep/.docs/ai/phases/2026-09-29-session-handoff.md`.
Live schema deployment, signing/install, archive, upload and merge remain
unrun or unapproved.

## Active M1 — `seedkeep-27d.33` — 2026-09-10

Build `1.0.0 (54)` remains rejected; its archive is retained, counter 54 is unchanged, and repair `b11195f` remains the source input.
RecommendationStore source tests and the newest-first build-55 changelog entry are ready; the existing URLSession injection is used with a suite-local URLProtocol fixture.
Initial full gate, before the final fixture/changelog corrections: SeedkeepKit 97, SeedkeepCloudKit 148, CloudKit-OFF app 769, Production-default CloudKit-ON 1.
Final focused gates after those corrections: RecommendationStore 5/5 and ChangelogData 3/3; no final full-gate rerun is claimed.
Authenticated iPad retry QA exercised both real Retry controls; Production asset sends were attempted but existing-record conflicts prevent fresh upload acceptance. Original synced-state was restored and the roster is empty. A fresh supported Add Photo check reached the native picker; the native screenshot shows the synthetic barcode as the first tile, but picker AX interaction is unavailable, so no fresh photo acknowledgment exists. A synthetic scalar Seed save received Production `savedRecords` acknowledgement, with no second-receiver convergence proof.
Remaining live gates: on iPad, select the first synthetic barcode tile in the visible PhotosPicker, then complete Add photo; on Roshar, scan the prepared online barcode with Camera, record raw detection and catalog hit, save, set local ZIP, and inspect live planting guidance.
Evidence: `.docs/ai/evidence/2026-09-10-m1-native-v1.md` and `2026-09-10-m1-live-retry-log.txt`; barcode card: `2026-09-10-m1-online-barcode-card.html`; approved spec: umbrella `.docs/ai/phases/2026-09-10-v1-successor-release-plan.md`; Bead: `seedkeep-27d.33`.
M2/build-55 archive, upload, and external release actions remain inactive.
