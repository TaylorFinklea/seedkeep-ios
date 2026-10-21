# R2 — Workbench everywhere, Dynamic Type, dark mode, accessibility

Plan: umbrella `.docs/ai/phases/2026-10-15-native-workbench-redesign-plan.md`
(R2). Release scope and look: umbrella `decisions.md` [2026-10-20]. Inventory:
the session report of 2026-10-20 (about 40 live Herbarium screens; HerbFont
never scales; forced light mode).

GPT-6.1 Sol critiqued the first draft (verdict: revise before execution). Its
main finding was that R2 was too large, so it is split into three phases. Each
has its own review and gate.

| Phase | Outcome |
|---|---|
| **R2a — foundation and behaviour-preserving restyle** | Workbench components, a debug sample-garden mode for screenshots, and restyled Garden, Journal, Add Seed, seed detail, planting panel, scan chrome, random pick, invite, What's New and the Settings sub-screens. No navigation or behaviour change. Light mode only. |
| **R2b — Seeds, Today and Settings** | The compact Seeds list (replacing the iPhone grid, with parity), Today restructured with its current semantics preserved, and You folded into Settings with route integration. |
| **R2c — dark mode and accessibility acceptance** | The appearance setting (System / Light / Dark) and dark enablement, contrast fixes, large-text layout fixes (bed canvas movement, bulk bar reflow, toolbars), the chart text summary, and VoiceOver and keyboard acceptance. |

## Owner decisions (2026-10-20)

1. **Workbench everywhere**, on iPhone, iPad and Mac, using system fonts
   (SF Pro for text, SF Mono for numbers, dates and counts).
2. **No Herbarium flourishes:** no Latin headings, roman-numeral folios,
   pressed-plant illustrations or ornaments. Headings are plain.
3. **Dark mode** follows the system, with a Light / Dark / System override in
   Settings (R2c).

## Scope rules (all R2 phases)

- **In scope:** code reachable in the shipping app. Navigation roots are
  `MainTabView`, `WorkbenchShell`, the N1 entry screens, and the sheets and
  pushes they open.
- **Herbarium allowlist.** HerbColor, HerbFont, the Herbarium components and
  the bundled TTFs stay compiled until N3. They may only remain in:
  - **Dead files** (no live reference):
    - Assistant/*
    - MCPSettingsView, AssistantKeySettingsView, PendingWritesView
    - AccountDeletionHandoffAcceptView, SeedRow, SuitabilityBar
    - SproutFAB, TopBarSparkleButton, CloudSharingControllerView
    - the `SettingsView` wrapper at `SettingsView.swift:428`
  - **Hidden features:**
    - pets: MenagerieView, PetDetailView, PetCard, Companions/*,
      PressedPlant, RarityBadge
    - catalog: CatalogFeedbackSheet, CatalogDetailView,
      ContributionDetailSheet, CorrectionStatusPill
    - ServerSettingsView, SubscriptionSettingsView, AccountDeletionFlowView
  - **Code gated off in live files:** inside `if !ServerRetirement.isRetired` or
    `if FeatureFlags.plantPetsEnabled` blocks, listed in the final review.
  - **Unmigrated live screens:** LibraryView, TodayView, YouView, SettingsView
    (`SettingsContent`), until R2b migrates them.

  A **reference audit** lists every Herbarium symbol in live files and maps
  each one to an allowlist entry. Anything unmapped fails the phase.
- **Layout constants:** `HerbSpace` (gutters and the tab-bar clearance) is
  layout, not styling, so live screens may keep it through R2. It's renamed
  or folded into `WBMetrics` when N3 deletes the Herbarium code. (Recorded
  after the R2a review.)
- **Contrast.**
  - Text uses `WBColor.ink` or `WBColor.muted` on `bg`, `panel` or
    `panel2`. Both are at least 4.5:1 in light and dark.
  - `WBColor.faint` (about 3.8:1 on panel) is for decorative rules, disabled
    states and secondary icons only, never essential text.
  - Verdict and warn colours are for icons, dots and bars. Their labels use
    `ink`.
  - Interactive control labels (buttons, links) may use `WBColor.accent`,
    which is at least 4.5:1 on `bg` and `panel` in light and dark. (Parent
    refinement after the S0 review.)

---

# R2a contract

## Invariants

1. **No behaviour change.** Same navigation, tabs, data flow, sheets, actions,
   copy (except the removed flourishes) and tests, plus the N1 and N2
   invariants. Light mode stays forced until R2c.
2. **Dynamic Type in migrated files:**
   - text uses `Font.wb*` or system text styles; no `.system(size:)` or
     `.custom(_:size:)` for text
   - icon sizes use `@ScaledMetric`
   - no new `lineLimit(1)` on user content
3. **Accessibility in migrated files:**
   - icon-only controls have labels
   - custom tappables have `.isButton`
   - touch targets are at least 44pt on iOS
   - section headers carry `.isHeader`
4. **Scan hand-off frozen.** `ScanResult`, `AddSeedView.Prefill`,
   `ScanPrefillBox`, the dismissal order and `SeedSaveSession` keep their
   signatures and behaviour. Scanning stays iOS-only.

## S0 — Foundation (worker; parent-owned API below)

`Seedkeep/DesignSystem/Workbench/` gets new files:

```swift
// WBType.swift — all built on system text styles, so they scale.
extension Font {
    static let wbLargeTitle: Font   // .largeTitle, semibold
    static let wbTitle: Font        // .title2, semibold
    static let wbHeadline: Font     // .headline
    static let wbCallout: Font      // .callout
    static let wbFootnote: Font     // .footnote
    static let wbSectionLabel: Font // .caption, semibold (WBSectionHeader)
    // existing: wbBody, wbCaption, wbMono, wbMonoCaption
}

// WBComponents.swift
struct WBSectionHeader: View {            // replaces Rubric / .herbRubricStyle()
    init(_ title: String)                 // uppercased, tracking 0.6, WBColor.muted, .isHeader
}
struct WBBanner: View {                   // replaces HerbBanner: same initializer, drop-in
    enum Severity { case info, success, warning, error }
    init(severity: Severity, title: String, message: String? = nil,
         action: (label: String, handler: () -> Void)? = nil)
    // info, success: accentSoft background, accent icon; warning, error: warnSoft, warn icon.
    // title and message in ink and muted; the text wraps; the action button is 44pt or larger.
    // Accessibility: one combined element (severity + title + message); the action is a separate button.
}
struct WBStatusChip: View {               // status and verdict chips
    enum Tone { case neutral, accent, warn, verdict(String) }   // verdict raw value
    init(_ text: String, tone: Tone)      // tone dot or tint plus `ink` text; never colour-only
}
struct WBEmptyState: View {               // ContentUnavailableView, Workbench-styled
    init(title: String, message: String? = nil, systemImage: String,
         action: (label: String, handler: () -> Void)? = nil)
}
struct WBDaylightPanel: View {            // replaces SunArc on Today (R2b wires it)
    init(sunrise: Date, sunset: Date, now: Date)
    // text first: sunrise, sunset and day length in wbMono; a ProgressView bar; one accessibility summary
}
struct WBScreenBackground: View {}        // WBColor.bg, ignores the safe area; replaces VellumBackground
extension View {
    func wbPanel(padding: CGFloat = WBMetrics.gapLarge) -> some View  // panel, line border, radiusPanel
    func wbForm() -> some View   // Form/List: hidden scroll background over WBColor.bg; system grouped rows
}
struct WBProgressStyle: ProgressViewStyle {}   // linear; accent fill on line track
extension ProgressViewStyle where Self == WBProgressStyle { static var wb: WBProgressStyle { get } }
```

S0 also:
- swaps `HerbBanner` for `WBBanner` in `MainTabView`, `WorkbenchShell`,
  `AddSeedView` and `NotificationsSettingsView` (same arguments)
- sets the iOS tab bar to system fonts (removing the IM Fell
  `UITabBarItem` appearance in `SeedkeepApp`), and applies
  `.tint(WBColor.accent)` app-wide
- sets both AccentColor asset variants to `WBColor.accent` light and dark
- removes Core's `HerbColor` import from `Core/Changelog/ChangelogData.swift`
  (map release kinds to `WBColor` in the view that shows them)
- adds a **debug sample-garden mode** (`Seedkeep/App/FixtureMode.swift`,
  `#if DEBUG` only)

**Sample-garden mode.** The launch argument `-SeedkeepFixture` turns it on:
- `AppEnvironment.live()` uses an in-memory store seeded with a sample
  garden: about 20 seeds across all states, with growing info, two beds with
  plantings, journal entries with checklist items, tags, locations and a home
  ZIP
- a fixed identity provider returns an available account and one owned
  garden
- CloudKit is never used (`canUseCloudKit` is false; no coordinator)
- the refusal count stays 0, and it never runs under XCTest
- release builds don't contain it

Tests cover: the type styles (text-style based), `WBStatusChip` building
accessibility text for every tone, and the sample-garden mode staying off in
release builds and under XCTest.

## S1 — Garden, Journal, Add Seed (worker)

- **Files:**
  - Garden: GardenView, BedDetailView, BedLayoutCanvas (colours and labels
    only; movement accessibility is R2c), AddBedView, AddPlantingEventView,
    WhatToPlantView, CornerSuggestionsView
  - Journal: JournalView, JournalEntryView, EntityScopedJournalSection,
    RetrospectiveCard, AttachedEntityPicker
  - AddSeedView
- **Changes:**
  - Remove the Latin headings, folio strips, ornaments and illustrations.
  - Replace `Rubric` with `WBSectionHeader`, `VellumBackground` with
    `WBScreenBackground` and `.vellumForm()` with `.wbForm()`.
  - Map colours: `HerbColor.ink`→`ink`, `inkSoft`→`muted`, `inkFaint`→`faint`
    (decoration only) or `line`, `sepia`→`accent` (actions and tint) or `muted`
    (labels), `rose`→`warn`, `sage`→`accent`, and verdict colours to
    `WBColor.verdict`.
  - Fonts: `Font.wb*`.
- **Accessibility:** label the two Journal checklist buttons
  (`JournalEntryView` lines 130 and 261) and BedDetailView's delete-event
  button (line 271).

## S2 — Seed detail, planting panel, scan chrome, random pick, invite, What's New (Luna; the parent builds)

- **Files:** SeedDetailView, RecommendationPanel, ScanFlow (chrome only),
  CameraView, RandomPickView, InviteAcceptView, WhatsNewSheet.
- **SeedDetailView:** no pressed-plant hero. Photos first, then fields, then
  the planting panel. Keep the role label on photos: white on a black
  backing.
- **RecommendationPanel:**
  - verdict chip through `WBStatusChip(.verdict)`
  - the 60-day bar in Workbench tokens; replace the RGB `segmentColor` ramp
    with `WBColor.verdict` or opacity steps
  - **add a text summary to the chart for accessibility**, for example
    "Best from May 4 to June 1; today: plant soon"
  - `PlantingEngineTests` copy assertions keep passing (copy unchanged)
- **ScanFlow:** keep the black and white overlays on the camera feed;
  restyle the sheets and buttons.
- Same colour and font mapping as S1.

## S3 — Settings sub-screens (worker)

- **Files:** NotificationsSettingsView, AIProviderSettingsView,
  APIKeysSettingsView, HomeLocationSettingsView, LocationsView, TagsView,
  JournalRecoveryReviewView.
- **TagsView:** the persisted tag swatches stay user-chosen literal colours
  (exempt). Their names sit next to them in `ink`.
- Same colour and font mapping as S1.

## R2a verification (parent)

- **The full test gate passes.**
- **Reference audit:** a script lists every Herbarium symbol (`HerbColor`,
  `HerbFont`, `Rubric`, `ScholarRule`, `FolioStrip`, `TapeStrip`,
  `VellumBackground`, `.vellumForm`, `HerbBanner`, `PressedPlant`,
  `RarityBadge`, `SunArc`, `.herb*Style`, `HerbRomanNumeral`) across
  `Seedkeep/`. Each hit maps to the allowlist; R2a's migrated files have
  none.
- **Simulator screenshots in sample-garden mode** (iPhone and regular-width
  iPad), light mode, at default size and at the largest accessibility size,
  of every R2a screen. The parent reviews them for clipping and overlap.
- **An Opus and a Sol review** of the merged diff before commit.
- **Owner-run (open until done):** Mac visual check.

## R2a screenshot review (2026-10-20)

On the iPhone simulator in sample-garden mode, light mode, at the default text
size and at the largest accessibility size.

- **Checked:** Garden, bed detail, Journal list, journal entry, seed detail
  with the planting panel, Add Seed, and random pick.
- **Fixed after review:**
  - **Planting panel:** the "Outdoor"/"Indoors" label moves above its dates
    instead of breaking mid-word. The axis drops "+30D", then stacks, instead
    of truncating.
  - **Status chip:** the dot and padding scale with the text.
  - **Random pick:** the tags stack instead of truncating. The card scrolls
    instead of running under the title and pushing the button off screen.
- **Deferred to R2c (large text):**
  - The Journal list's date column squeezes the entry text.
  - Bed canvas labels overlap when plantings sit close together (visible at
    the default size too).
  - System menu pickers (Location, Source, State) truncate their values
    mid-word; consider `.pickerStyle(.navigationLink)` at accessibility sizes.
- **Deferred to R2b (polish):**
  - Form section headers mix two styles: system headers in bed detail, and
    `WBSectionHeader` captions in the journal entry and seed detail. Bed
    detail's "Journal" section shows both.
  - The large title's leading inset differs between Garden and Journal.
  - Add Seed repeats "Add seed" in the navigation bar and the content heading
    (this predates R2a).
  - In the journal entry, the empty photo strip leaves a blank row, and
    "Attached to" repeats as the header and the row label.
- **Not checked:** the Settings sub-screens, What's New, invite, scan chrome
  (the Simulator has no camera) and regular-width iPad. The Simulator dropped
  taps too often to walk them; they are standard forms like the screens
  above. These stay open for R2c's accessibility acceptance.

---

# R2b contract

R2b finishes the Workbench look for the remaining Herbarium screens: Seeds
in the compact (tab) interface, Today, and Settings with You folded in, plus
the polish items from the R2a screenshot review. Light mode stays forced
until R2c.

GPT-6.1 Sol critiqued the first draft and asked for a revision. Two
confirmation rounds later it approved this version (2026-10-20). It
resolves each of Sol's points:
- Library information parity
- verdict semantics
- Today's actual journal and daylight rules
- loading state
- garden identity beside sharing
- cross-platform scope
- slice ownership and acceptance data

## Platform scope

- **Every platform:**
  - **Today, Garden and Journal:** both interfaces render them, so S0, S2 and
    S4 change them everywhere.
  - **Settings:** S3 changes it on every platform.
- **Compact interface only** (iPhone and compact-width iPad): S1, the Seeds
  list. Regular-width iPad and Mac keep R1's Seeds table.

## Invariants

1. **Behaviour.**
   - These stay the same: the data, actions, sheets, gating
     (`ServerRetirement.isRetired`, `FeatureFlags`,
     `AppPreferences.isHostedTierEnabled`), the N1/N2 invariants, and
     persisted keys (`library.groupByType`,
     `seedkeep.whatsNew.lastSeenBuild` with mark-seen-on-tap, and the
     `seedkeep.notif.*` keys).
   - The only intended behaviour changes are the ones marked *Change* below.
2. **The R2a rules carry over:**
   - text scales, and icons use `@ScaledMetric`
   - text colour is `ink` or `muted`, and status colour goes on icons only
   - icon-only controls have labels
   - targets use `WBMetrics.minTouchTarget`
   - section headers carry `.isHeader`
3. **Testable logic.** Any new list, grouping, count, due, label or
   accessibility-text logic lives in pure helpers with Swift Testing tests.
   Shared Seeds helpers are additive, so R1's sorting, counts, selection and
   export stay unchanged.
4. **Large text is acceptance, not R2c.** Every R2b screen is
   screenshot-checked at the default and largest accessibility sizes.
5. **One `NavigationStack` per root.**

## Order and ownership

1. **S0 (parent) lands first.**
2. **S1, S2 and S3 run in parallel** (workers):
   - **S1:** `LibraryView.swift`, additive helpers in `SeedsTableModel.swift`,
     and their tests.
   - **S2:** `TodayView.swift`, a new `TodayDue.swift`,
     `FixtureSampleGarden.swift` (acceptance data), and their tests.
   - **S3:** all of `SettingsView.swift`, including the dead wrapper.
3. **The parent owns the routing callers:**
   - `MainTabView`, `AppEnvironment.AppTab`, `WorkbenchShell`
   - the dead `TopBarSparkleButton` and `SproutFAB`
   - `YouView`'s reachability
4. **S4 (parent) runs after the merge**, on a fixed file list.

## S0 — Shared title and gutter (parent)

- `WBMetrics.screenGutter`, one value for the page inset.
- `WBScreenTitle(_ title: String, subtitle: String? = nil)`:
  - `wbLargeTitle` in `ink` with `.isHeader`
  - the subtitle in `wbFootnote` `muted`
  - leading-aligned on the gutter
- GardenView and JournalView adopt it, which fixes the inset mismatch, with
  their titles and subtitles unchanged. S1, S2 and S3 use it.
- **Loading-state bridge** (*bounded correction*):
  - `AppEnvironment.runCloudSyncPass(_:)` wraps the `coordinator.sync()` call
    in `syncIfPossible`. It keeps an observed in-flight count, so passes that
    overlap can't clear it early.
  - `isSyncingForDisplay` is true when `sync.isSyncing`, that count is above
    0, or `cloudKit?.isSyncing`. The coordinator reference is
    `@ObservationIgnored`, so the observed count is what lets a view see the
    first pass begin.
  - JournalView, WhatToPlantView and R1's SeedsTableView switch to it, and
    S1 and S2 use it.
  - A test tracks `isSyncingForDisplay` with `withObservationTracking`,
    checks that starting a pass fires the change, that the flag is true
    during the pass, and that it settles to false afterwards, including for
    two overlapping passes.

## S1 — Seeds list, compact interface (worker)

`LibraryView` keeps its type name and becomes a compact `List`.

- **Rows:** `SeedTableRow.rows(...)`, scoped to the active household as in
  `WorkbenchShell`. Each row shows:
  - Line 1: the name (`row.name`).
  - Line 2: type · variety, skipping blanks.
  - Line 3: company · packed year, as a plain year, skipping blanks.
  - **Verdict:** a trailing verdict dot and `row.verdictLabel` in `muted`
    text, shown only when a recommendation exists (`row.verdict != nil`).
    An unknown verdict shows "No window", as `SeedTableRow` already does.
  - **VoiceOver:** one combined element whose text comes from a pure
    `SeedsListText.accessibilityLabel(for:)`. It covers name, type, variety,
    company, packed year and the verdict label when present, with
    `.isButton`. Tapping pushes `SeedDetailView`.
  - *Change:* a missing name reads "Untitled seed" (from `displayName`)
    instead of "Untitled", and is trimmed.
- **Subtitle:** `WBScreenTitle("Seeds", subtitle: "<N> seeds · <M>
  active")`. N and M keep today's meaning: N is the live seeds in the active
  garden, and M is those in the Active state (the old "of which M in the
  active garden" wording misdescribed M). The arithmetic goes in a pure
  helper, with singular and plural forms.
- **State filter:**
  - Active, Wishlist, Saved and Archived use `SeedStateFilter` titles with
    the count. There is no "All", and the default is Active.
  - It's a segmented `Picker` when it fits; otherwise (`ViewThatFits`) a menu
    `Picker` showing the current state and count.
  - VoiceOver hears the title, the count and the selection.
  - *Change:* the titles match iPad and Mac ("Wished" → "Wishlist",
    "Archive" → "Archived").
- **Search:** R1's complete semantics, through `SeedsFilter.matchesSearch`:
  the normalised display name, variety, company, type and notes, localized
  case-insensitive, without tags.
  - *Change:* type is now searched too.
- **Counts:** from all live active-household rows, with the search applied
  and no type filter, before the state filter (`SeedsTableModel.counts` with
  `type == nil`).
  - *Change:* the counts follow the search, as on iPad and Mac.
- **Empty states**, classified on the selected state's rows before search:
  - none → `WBEmptyState("No seeds yet", "Tap + to add a seed.")`
  - some, but no search match → `WBEmptyState("No matches", "Try a different
    search.")`
  - The classification is a pure helper with tests.
- **Sort:** most recently updated first, with ties by id, through a new pure
  `SeedsTableModel.recentFirst(_:)`.
- **Group by type:** the same toggle and key, through a new pure
  `SeedsTableModel.groupedByType(_:)`:
  - Buckets use the trimmed type and stay case-sensitive, so "Tomato" and
    "tomato" remain separate.
  - Sections sort case-insensitively, with ties by the raw string, and
    "Untyped" (blank) comes last.
  - Rows within a section are recent-first.
  - Sections use `WBSectionHeader`.
- **Unchanged:** the toolbar (options menu, random pick, scan on iOS, add),
  the sheets, pull-to-refresh, and `publishesAssistantContext`.
  - The scan presentation code (`showingScan` → `ScanFlow` → `scanPrefill` →
    `AddSeedView(prefill:)`) moves over verbatim. The review checks it by
    diff.
- **Loading:** shown only when the active garden has no rows and sync is
  running.
  - *Change (bounded correction, S0):* "sync is running" becomes
    `AppEnvironment.isSyncingForDisplay`. Today these screens used only the
    legacy engine, which never runs in the shipping CloudKit path. Cached
    rows always stay visible during sync.
- No new swipe actions, context menus or selection.

## S2 — Today (worker)

The queries, predicates and refresh (midnight and foreground) stay the same.

1. **Title:** `WBScreenTitle("Today", subtitle: <"EEEE, MMMM d">)`.
2. **Daylight:** the same branch as today, keyed on `Solar.dayLight(...)`
   returning a value:
   - a value → `WBDaylightPanel`
   - no cached location → a `wbPanel` with the existing message and the "Set
     home location" button (same sheet)
   - *Change:* a cached location but no sunrise or sunset (polar day or
     night) → "No sunrise or sunset at your home location today." Today it
     shows the set-location prompt, which is wrong there.
3. **Due (`WBSectionHeader("Due")`):**
   - **Queue:** one queue, as today: incomplete, non-deleted events with
     `plannedFor <= today`, oldest first, scoped to the active household,
     then a single `prefix(6)`.
   - **Row line 1:** the seed name, or "Untitled seed" when the seed is
     missing.
   - **Row line 2:** kind · type in `muted`, skipping a blank type.
     - *Change:* the kind is new. It uses
       `PlantingEventKind(rawValue:)?.displayName`, or "Event" for an
       unknown kind.
   - **Trailing day label:**
     - overdue: a warn icon plus "1 day overdue" / "N days overdue"
     - today: "Today"
     - future: "1 day left" / "N days left", kept for parity
   - **VoiceOver:** one combined label: name, kind, day label.
   - No tap action, as today.
   - **Empty:** "Nothing due." **Loading:** `ProgressView("Syncing…")`, using
     `isSyncingForDisplay` and only when the list is empty.
4. **Journal (`WBSectionHeader("Journal")`):**
   - The same query: the newest entry with `occurredOn >= yesterday` (no
     upper bound, ties as the store returns them).
   - Its body is shown in `wbBody` inside a `wbPanel`, or "—" when the body
     is empty. It appears only when an entry exists.
5. **Pet roll-call:** unchanged inside its `FeatureFlags` gate
   (allowlisted).

**Pure helpers with tests (`TodayDue`):**
- `dayOffset(plannedFor:today:)` works on `yyyy-MM-dd` strings, parsed as
  Gregorian dates in UTC, so DST can't shift them. An invalid date returns
  0, matching today's "today" fallback.
- `dayLabel(offset:)`, with singular and plural forms.
- `kindLabel(_ raw:)`.
- `rowAccessibilityLabel(...)`.

**Acceptance data (DEBUG fixture only):** S2 adds these to the sample
garden:
- incomplete events: two overdue, one due today, and enough beyond those
  for the queue to pass six
- every kind, plus one event whose seed is missing
- a journal entry dated today

`FixtureEnvironmentTests` are updated if their counts change.

## S3 — Settings replaces You (worker; the parent owns routing)

**Routing (parent):**
- `AppEnvironment.AppTab.you` → `.settings`, and `.library` → `.seeds`.
- The tabs become Today, Seeds (`leaf`), Garden, Journal and Settings
  (`gearshape`).
- Both the Settings tab and the Workbench `.settings` route render
  `NavigationStack { SettingsContent() }`.
- The dead `TopBarSparkleButton` and `SproutFAB` are updated to compile.
- A test pins the tab list.
- **YouView becomes unreachable.** Its server-era entry points
  (contributions, Delete account) were already hidden in every build
  (`isRetired` is constant `true`). This contract explicitly accepts that
  they become unreachable. Their implementation stays compiled until N3,
  and N2-E designs the new "Delete Seedkeep data".

**`SettingsContent` in Workbench (S3):** `.wbForm()`, `WBSectionHeader`, the
title "Settings", and no hero or roman footer. The sections, in order:

1. **Account:**
   - "iCloud account" (from You).
   - The household name and ID, from the signed-in identity as today,
     labelled "Your household" so they aren't mistaken for a shared garden.
2. **Seeds:** Locations, Tags.
3. **Home and alerts:** Home location (same summary), Notifications.
4. **AI:** Provider, API keys. Subscription stays behind both of its gates.
5. **Sync:** everything it has today, in place and unchanged, including:
   - Sync now, with its progress, success tick and error
   - the CloudKit flag
   - the status rows
   - the whole sharing branch: participant status, journal recovery (its
     scope and count, and the sheet), leave (and when it's disabled), share
     (progress and errors)
   
   The server rows stay gated.
6. **Diagnostics:** the paused-deletion row, under the same condition.
7. **About:**
   - What's New, with the same unseen dot and mark-seen-on-tap
   - the data sources text
   - the Privacy Policy and Support links
   - *Change:* "Version <AppInfo.currentVersion> (<build>)" replaces the
     roman build footer. A missing version shows "Build <n>", a missing
     build shows "Version <v>", and if both are missing the row is hidden.

S3 also removes the dead `SettingsView` wrapper. The "Settings → …" copy in
`Copy.swift`, `BYOKExtractor` and `ChangelogData` stays valid.

## S4 — Polish from the R2a review (parent, after the merge)

Files: `BedDetailView`, `AttachedEntityPicker`, `SeedsInspector`,
`AddSeedView`, `JournalEntryView`.

- **Form section headers** in those files use `WBSectionHeader`.
- **Add Seed:** drop the duplicate in-content heading. The navigation title
  stays.
- **Journal entry:**
  - Hide only the empty thumbnail strip. "Add photos" and the new-entry
    "save first" guidance stay.
  - Don't repeat "Attached to" as both the header and the row label. The
    picker keeps its accessibility name.

## R2b verification (parent)

- **Gate:** `scripts/test-gate.sh` passes (both packages, and both CloudKit
  lanes on iOS and macOS).
  - The existing pins keep passing: R1 search and counts, the verdict and
    fallback copy, the Workbench route titles and Settings command, and the
    warning copy.
  - New tests: the S1 and S2 helpers and the tab list.
- **Logic coverage:**
  - deleted, completed and future exclusions
  - scope before the limit, and more than six events
  - every kind, and missing seeds
  - journal boundaries, and date rollover and DST
  - group ordering and case variants
  - recent-first ties
  - empty versus no-match
  - The participant and rollback isolation tests stay.
- **Reference audit:**
  - LibraryView, TodayView (outside the pet gate) and SettingsView have no
    Herbarium symbols.
  - YouView is unreferenced.
  - The allowlist is updated.
- **Screenshots in sample-garden mode**, at the default and largest sizes,
  of every screen R2b changes:
  - iPhone:
    - Seeds: grouped, ungrouped, no matches, an empty tab, a long name, and
      the state filter falling back to a menu at the largest size, with no
      compressed segments
    - Today: with location, with overdue and today rows, and with the
      journal panel
    - Settings
    - Garden, Journal, What to Plant (S0)
    - bed detail, journal entry with the attachment picker, Add Seed (S4)
  - Regular-width iPad: Today, Garden, Journal, What to Plant, Settings, the
    Seeds table with its inspector, bed detail, journal entry with the
    attachment picker, and Add Seed.
  - Mac: the gate's macOS lanes build and test it. The visual check stays
    with the owner (the Mac app can't be driven from here).
- **Interactions:**
  - pushes from grouped and ungrouped rows
  - every toolbar sheet
  - pull-to-refresh
  - Settings pushes and back
  - the What's New sheet
  - the compact ↔ regular iPad transition
- **Not provable in the Simulator:** scan cancel and save need a camera. The
  scan presentation is checked by diff, and its device check moves to R5 QA.
- **Accessibility:** the pure label helpers are tested. A VoiceOver pass
  with Accessibility Inspector is R2c acceptance.
- **Reviews:** Opus and Sol on the merged diff.
