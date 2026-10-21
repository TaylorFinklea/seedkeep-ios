# Current State

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
