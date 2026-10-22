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
    - SproutFAB, TopBarSparkleButton
    - the `SettingsView` wrapper at `SettingsView.swift:428`
  - **Correction (2026-10-22, N3 slice D):** `CloudSharingControllerView.swift`
    is not dead and was wrongly listed above. `CloudSharingPresenter` presents the
    "Share garden via iCloud" sheet from `SettingsView`'s Sync section
    (`SettingsView.swift`, `CloudSharingPresenter.present`), so it stays live
    through N3.
  - **Hidden features:**
    - pets: MenagerieView, PetDetailView, PetCard, Companions/*,
      PressedPlant, RarityBadge
    - catalog: CatalogFeedbackSheet, CatalogDetailView,
      ContributionDetailSheet, CorrectionStatusPill
    - ServerSettingsView, SubscriptionSettingsView, AccountDeletionFlowView
  - **Code gated off in live files:** inside `if !ServerRetirement.isRetired` or
    `if FeatureFlags.plantPetsEnabled` blocks, listed in the final review.
  - **Unmigrated live screens:** none after R2b. LibraryView, TodayView
    (outside its pet gate) and SettingsView (`SettingsContent`) are migrated.
    YouView is a dead file (no references) until N3.

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

## R2b review and screenshot results (2026-10-20)

- **Opus review:** approve with fixes. Applied:
  - **Seeds:**
    - The state filter switches on `isAccessibilitySize` rather than
      `ViewThatFits`. Segmented-control text doesn't grow, so the fallback
      never triggered.
    - The menu shows only the value, and the custom accessibility value is
      dropped.
    - A blank type and a literal "Untyped" type share the last group, as the
      grid did.
    - The counts go through a tested `libraryStateCounts(_:search:)`.
  - **Today:** due rows use `displayName`. The fixture's seedless note is
    overdue, so the six-row cut always keeps it.
  - **Settings:** publishes `pageType: "settings"` assistant context.
  - **Recorded, not changed:** BedDetailView's "Companions" header sits
    inside the pet gate (allowlisted).
- **Fixed after screenshots** (iPhone, sample garden, default and largest
  sizes):
  - Today's daylight readings and due rows stack at accessibility sizes,
    instead of breaking words mid-word.
  - Seed rows put the verdict under the name at accessibility sizes, and sit
    on the page background and gutter.
- **Checked:**
  - Today: daylight, due rows (overdue and today, the seedless note), the
    journal panel.
  - Seeds: segmented filter, rows, grouped, no matches with counts following
    the search, the menu filter at the largest size.
  - Settings: every section, the version row, the largest size.
  - Garden; bed detail headers; journal entry ("Attached to" once, no blank
    photo strip).
- **Open:**
  - **Regular-width iPad (Today, Settings route, bed detail, Add Seed):**
    driving the iPad simulator needs the owner's approval in the simulator
    panel. A static capture showed the R1 Seeds table.
  - **R1 problem for R2c:** in iPad portrait, with the sidebar and inspector
    open, the table's Name column scrolls out of view.
  - **Mac:** the visual check stays with the owner.

---

# R2c contract

R2c turns dark mode on and fixes the known contrast, large-text and
VoiceOver defects. Owner decision (2026-10-20): appearance follows the
system, with a Light / Dark / System override in Settings.

Sol critiqued the first draft and asked for a revision. Two more
confirmation rounds followed, and it approved this version (2026-10-20). Its main result: the automated accessibility
audit is a separate phase, R2d, with its own scheme, kept out of the
per-change gate.

## Facts (verified 2026-10-20)

- **Forced appearances:**
  - Light mode is forced once, at `SeedkeepApp.swift:48`. The only scene is
    `WindowGroup("main")`.
  - Two intentional dark exceptions stay: `ScanFlow`'s dark navigation bar
    (`ScanFlow.swift:65`) and the camera controller's black background
    (`CameraView.swift:89`).
- **Native sharing doesn't go through SwiftUI sheets:**
  `UICloudSharingController` on iOS and `NSSharingService` on macOS
  (`CloudSharingControllerView.swift`).
- **Launch screen:** it uses `systemBackground` (`project.yml:62`). It
  follows the device's appearance before the app can read its own
  preference.
- **Token contrast (WCAG, light / dark):** every token passes against
  `bg`, `panel` and `panel2`:
  - `ink`: 15.3 / 13.6
  - `muted`: 6.0 / 7.0
  - `accent`: 7.8 / 8.1
  - `accentInk` on `accent`: 8.5 / 8.7
  - `warn`: 5.9 / 7.6
  - the lowest verdict: 3.4 / 5.9
  - `faint`: 3.8 / 5.0
  
  `line2` on `panel` is 1.56 / 1.58 and is used only for rules and borders.
- **Real failures are in combinations of tokens:**
  - **Photo retry icons:** white on `warn` is 2.3:1 in dark
    (`SeedDetailView.swift:189`, `JournalEntryView.swift:250`).
  - **Chart marker:** `ink` over full-strength `verdictPlantNow` is 3.1
    light / 1.6 dark (`RecommendationPanel.swift:391`).
  - **`faint` used for readable text:**
    - the garden chooser's dates (`GardenChooserView.swift:106,111`)
    - the command palette's group label (`CommandPaletteView.swift:111`),
      which is 3.4 / 3.9 on `paletteSelection`
  - **The Seeds search field's border:** it's `line2` on `panel2`
    (`SeedsToolbar.swift:136`).
- **No UI-test target exists.** The chart's text summary is already done and
  tested (R2a).

## Permitted behaviour changes

- the appearance preference
- bed-canvas move actions for VoiceOver, and hidden overlapping labels
- picker style at accessibility sizes (iOS)
- the bulk bar's reflow
- the inspector's initial state in narrow Seeds layouts
- the bed-position bounds fix
- the "new" label on What's New

Everything else is unchanged. The R2a and R2b rules carry over.

## Order and ownership

The lead plans, integrates, takes the screenshots and decides; workers
implement.
1. C0 and C1 (one worker) land first, including the fixture isolation that
   the C2 screenshots depend on.
2. C2: the lead takes the screenshots and a worker fixes what they show.
3. C3 workers in disjoint file groups:
   - C3-a: Journal and Settings (What's New)
   - C3-b: the bed canvas, its new helper and tests
   - C3-c: the seed detail and Add Seed pickers
   - C3-d: the inspector policy, model and table, the bulk bar, and the
     toolbar
4. Merge, screenshots, gate, then reviews.

## C0 — Appearance and fixture isolation (worker)

- **Model:** `AppAppearance` (`system`, `light`, `dark`), raw values
  `"system"`, `"light"` and `"dark"`.
  - **Storage:** `AppAppearance.storageKey = "seedkeep.appearance"`, read
    with `@AppStorage(..., store: AppAppearance.store)`.
  - `store` is the fixture suite in sample-garden mode and `.standard`
    otherwise. It's per device, shared by all of the app's windows,
    independent of the garden, and never synced.
  - An unset or unknown value means `system`.
- **Applied once** at `mainRoot` as `.preferredColorScheme(appearance.colorScheme)`,
  where nil follows the system and its changes. The forced light mode and its
  Herbarium comment are removed.
- **Settings:** an "Appearance" section after Account, with a picker:
  System, Light, Dark.
- **Native sharing on iOS:** the presenter sets the controller's
  `overrideUserInterfaceStyle` from the preference (unspecified for System).
- **Native sharing on macOS:** if `NSSharingService` can't follow the
  override, that's recorded as a known exception.
- **Launch screen:** a `LaunchBackground` asset with `bg`'s light and dark
  values, set as `UILaunchScreen.UIColorName` in `project.yml`. It follows
  the device, so when the override differs, a brief switch at launch is
  accepted and documented.
- **Fixture isolation**, before any R2c screenshot:
  - In sample-garden mode, `WhatsNewGate` (startup baseline and
    mark-seen) and the Notifications toggles (`seedkeep.notif.*`) read and
    write the fixture defaults suite.
  - Notification permission requests, scheduling, and every clear, remove
    or cancel of pending or delivered notifications are skipped there. The
    toggles only store their value, so a fixture session can't change the
    device's real notifications.
  - A test shows a fixture launch leaves `UserDefaults.standard` unchanged
    for these keys.
- **Tests:**
  - raw-value mapping, the default, and an unknown value → system
  - `colorScheme` mapping
  - the store choice in fixture mode

## C1 — Contrast (same worker as C0)

- **One table:** `WBPalette`, with each token's light and dark hex values.
  `WBColor` builds its colours from it.
- **Tests compute WCAG contrast in both appearances.** Text pairs need 4.5:1:
  - `ink` and `muted` on `bg`, `panel`, `panel2`, `accentSoft`, `warnSoft`,
    `selection` and `paletteSelection`
  - `accent` on `bg`, `panel`, `panel2` and `accentSoft`
  - `accentInk` on `accent`
  - the new `warnInk` on `warn`

  Graphics need 3:1:
  - `warn`, the verdict colours and `faint` on `panel`
  - `faint` (the swatch ring) on `panel`
- **Resolution tests:** a token resolves to its light value under a light
  trait or appearance, and to its dark value under a dark one, on iOS
  (`UITraitCollection`) and macOS (`NSAppearance`).
- **Fixes:**
  - **New `warnInk` token** (white light, `#1A0F0A` dark) for icons on
    `warn`. The retry icons use it.
  - **Chart marker:** an `ink` bar with a 1pt `panel` halo. A test checks
    that the marker or its halo reaches 3:1 against every segment colour
    the ramp can draw (`line`, and `verdictPlantNow` at opacity 0.25–1 over
    `panel`), in both appearances.
  - **Readable `faint` text → `muted`:** the garden chooser's dates and the
    command palette's group labels. Every remaining
    `foregroundStyle(WBColor.faint)` on a `Text` is listed in the review
    as decorative or disabled.
  - **Swatch rings stay `faint`.**
  - **`line2` stays for rules and borders.** The Seeds search field's
    magnifying-glass icon (`SeedsToolbar.swift:112`) changes from `faint` to
    `muted`, so the icon and the system placeholder identify the field and
    its `line2` border is decorative. That's recorded here as a product
    choice (WCAG 1.4.11 doesn't require decorative borders to contrast).

## C2 — Dark-mode pass (parent screenshots, worker fixes)

- **Checklist**, in dark at the default size: every iPhone tab root, seed
  detail with the planting panel, Add Seed, bed detail, What to Plant,
  Journal entry, random pick, Settings and each sub-screen, What's New, and
  the entry screens (sign in to iCloud, the garden chooser, through their
  DEBUG previews where the fixture can't reach them).
- **Plus**, if the owner approves the simulator: the regular-width iPad
  Seeds table, inspector and command palette.
- **Repairs are limited to** contrast, appearance and readability.
  `.primary` and `.secondary` → `ink` and `muted`, for consistency.
- **Not reachable in the fixture**, so checked by code review against the
  token rules: photo-upload failure, participant and recovery UI, and entry
  failures.

## C3 — Large text and VoiceOver fixes (workers)

1. **Journal list (C3-a):** at accessibility sizes the date sits above the
   text, in the locale's abbreviated format, and may wrap. The row keeps its
   combined accessibility label.
2. **What's New (C3-a):** one button. Its label is "What's New, new" when
   the unseen dot shows (`SettingsText.whatsNewLabel(unseen:)`, tested in
   both states). Mark-seen-on-tap is unchanged.
3. **Bed canvas (C3-b):**
   - **One movement helper**, used by both drag and the new actions:
     `BedPlacementMath.moved(x:y:dx:dy:widthFeet:lengthFeet:)` returns nil
     for a no-op.
   - **Positions** snap to the 0.5 ft grid and clamp to the last grid point
     within the bed. That fixes the clamp-before-round bug, where a 2.3 ft
     bed allowed 2.5.
   - **Coordinates:** the bed's y increases upward. The canvas draws
     `screenY = originY + (lengthFeet - y) * scale`.
   - **Each placement is one accessibility element**, labelled "<name>, <x>
     feet from the left, <y> feet from the bottom". When moving is enabled
     it has the custom actions Move left (x decreases), Move right (x
     increases), Move up (y increases) and Move down (y decreases), each one
     0.5 ft.
   - **Moving:** a no-op writes nothing. Focus stays on the element, and its
     label updates.
   - **Labels:** each label reports its rendered frame through a preference
     key.
     - A pure helper, `BedLabelLayout.visibleIDs(frames:order:)`, keeps a
       label only if its rectangle doesn't intersect one already kept. The
       order is by y descending (top of the drawn bed first), then x, then
       id. Hidden labels stay out of the layout until frames change.
     - Tests use rectangles, including a touching-but-not-intersecting case.
     - The name stays in the accessibility label.
   - **Dots** keep their 18pt look, with a 44pt hit area wherever that
     doesn't overlap a neighbour's dot.
   - Tests cover the grid, the bounds, the no-op case and the overlap rule.
4. **Pickers (C3-c, iOS only):** at accessibility sizes, the seed detail and
   Add Seed menu pickers (State, Location, Source) use
   `.pickerStyle(.navigationLink)`.
   - **macOS is unchanged:** that style doesn't exist there.
   - **Saving is unchanged:** seed detail saves each selection once, through
     the existing bindings, and Add Seed changes stay a draft until Save.
   - Back navigation is checked.
5. **Bulk bar and toolbar (C3-d):** `SeedsBulkBar` wraps by available width
   (`ViewThatFits(in: .horizontal)`: one row, otherwise two), on iPad and
   Mac. The actions, the delete confirmation and the keyboard order are
   unchanged. `SeedsToolbar` gets the same treatment if it truncates at the
   largest size.
6. **Narrow Seeds layout (C3-d):**
   - **On entering the Seeds route:** if the detail column is narrower than
     the table's minimum width plus the inspector's minimum, the inspector
     starts closed.
   - **User control wins:** a user toggle holds until the route is left, and
     `reveal(seedID:)` still opens the inspector.
   - **Resizing never toggles it automatically.**
   - **Acceptance:** in iPad portrait the Name column is visible at launch
     and after rotation, and details stay reachable. If closing the
     inspector isn't enough, the parent decides on the sidebar before
     merge.

## R2c verification (parent)

- **Gate:** `scripts/test-gate.sh` passes, with the new C0, C1 and C3 tests.
- **Screenshots:**
  - the C2 checklist in dark at the default size
  - the C3 screens at the largest size, in light and dark
  - the iPad screens if the owner approves the simulator
- **Reviews:** Opus and Sol on the merged diff.
- **Owner:**
  - the Mac visual check, including the appearance picker and the sharing
    sheet under an override
  - a dark-mode glance on the phone
  - VoiceOver on the bed canvas move actions

# R2d contract

R2d adds an automated accessibility audit that runs outside the per-change
gate, makes sample-garden mode fully self-contained and repeatable, and adds
a manual checklist for what an audit can't prove. GPT-6.1 Sol critiqued the
first draft and asked for a revision; it approved this version on the
second round, with one change, now included (2026-10-20).

## Permitted changes

- **Sample-garden (DEBUG) isolation and determinism**, as below.
- **Accessibility identifiers** on existing actionable elements.
- **Bounded fixes for audit findings:**
  - labels, traits, contrast, hit regions
  - text clipping in R2-styled views
- **Not permitted without approval:** changes to navigation, persistence or
  layout beyond those fixes.

## Facts (2026-10-20, verified by Sol)

- **Fixture boundary:** `AppEnvironment.live()` chooses the fixture before
  it builds anything live (`AppEnvironment.swift:74`). The fixture uses:
  - in-memory SwiftData
  - a fixed identity and a no-op token store
  - CloudKit off
- **Still reaching outside the fixture:**
  - seed detail's weather refinement calls WeatherKit
    (`RecommendationStore.swift:183`)
  - API Keys reads the Keychain (under a random test service)
  - Notifications reads the real authorization status
- **Still not repeatable:**
  - Seeds' `library.groupByType` uses standard defaults
  - the fixture's `temporaryDirectory/seedkeep-fixture` survives
    launches
  - the sample data's dates follow the device's clock
- **What's New:** a first launch records the current version silently,
  with no sheet.
- **The audit API:** `XCUIApplication.performAccessibilityAudit(for:_:)`
  is in the iOS 27.1 SDK. It's main-actor, throws, and covers only the
  elements currently on screen. The handler returns true to suppress an
  issue, and `issue.element` may be nil.

## R2d-1 — Sample-garden isolation, determinism and identifiers (worker)

- **No outbound calls in sample-garden mode:**
  - `RecommendationStore` gets an injectable forecast source. The fixture
    supplies an empty one, so no WeatherKit request is made and windows
    stay at their baseline.
  - `NotificationsCenter.authorizationStatus()` returns `.authorized`
    without asking the system (the fixture uses the existing test
    override).
  - The fixture's `APIKeyStore` is in memory: a new `APIKeyStore` backend
    seam (Keychain by default), so the fixture makes no Keychain calls.
- **Repeatable launches:**
  - `library.groupByType` moves to `DevicePreferences.store` (wiped per
    launch, so it starts ungrouped).
  - The fixture directory is a fresh `seedkeep-fixture-<UUID>` per launch,
    removed at the next fixture launch.
  - The sample data's dates stay relative to launch. This is accepted:
    the audit records the date and time zone in its results and makes no
    date assertions.
  - Random pick's random source is injectable. In sample-garden mode it
    is a fixed sequence, so the same seed is picked in every
    configuration.
- **Launch configuration:**
  - DEBUG-only, and read only when `-SeedkeepFixture` is present:
    `-SeedkeepAppearance light|dark` is written to the fixture suite
    inside `makeForFixture()`, straight after the wipe and before any view
    exists.
  - **Fail closed:** `-SeedkeepAuditLaunch`, in any build, means "this must
    be a sample-garden launch". If fixture mode isn't active (a Release
    build, or a missing `-SeedkeepFixture`), the app calls
    `preconditionFailure` in `AppEnvironment.live()`, before it builds
    anything live.
- **Identifiers**, on the actionable element itself, never replacing labels:
  - **tabs:** `tab.today`, `tab.seeds`, `tab.garden`, `tab.journal`,
    `tab.settings` (verified to reach the tab buttons; if `.tabItem`
    doesn't pass them through, the test uses the tab's label instead)
  - **rows:** `seeds.row.<id>`, `garden.bed.<id>`, `journal.entry.<id>`,
    with the fixture's fixed ids
  - **Settings rows:** `settings.locations`, `settings.tags`,
    `settings.homeLocation`, `settings.notifications`,
    `settings.aiProvider`, `settings.apiKeys`, `settings.whatsNew`
  - **toolbar buttons:** `seeds.add`, `seeds.random`, `garden.whatToPlant`
  - **destination roots**, so a test knows where it is: `screen.<name>`
- **Readiness** needs no extra element. The test waits (bounded) for the
  fixture-only row `seeds.row.<fixture id>`. Only the sample garden has that
  id, so finding it proves both the fixture and readiness.
- **Tests:** override parsing, the fail-closed decision, and the fixture
  store choices, as unit tests.

## R2d-2 — Audit target, scheme and script (worker)

- **Target and scheme:**
  - **target:** `SeedkeepUITests` (`bundle.ui-testing`, iOS only,
    depends on `Seedkeep`)
  - **scheme:** a shared Debug scheme, `SeedkeepAccessibilityAudit`, that
    contains only that bundle
  - **verification:** the lead inspects the generated `Seedkeep` scheme
    and confirms the UI tests aren't in it. The gate's counts must equal
    the previous counts plus the R2d-1 unit tests.
- **One test per configuration:**
  - iPhone, in light and dark, at the default text size and at
    Accessibility XXXL: 4 launches.
  - Each launches with `-SeedkeepFixture`, `-SeedkeepAuditLaunch`,
    `-SeedkeepAppearance`, `-UIPreferredContentSizeCategoryName`,
    `-AppleLanguages (en)` and `-AppleLocale en_US`.
  - It asserts the effective configuration before auditing:
    - **appearance:** by sampling the background colour of a screenshot
    - **text size:** the "Today" title's height must exceed a measured
      threshold at XXXL
    - A configuration that was ignored fails the test.
- **The manifest of destinations and checkpoints**, walked in one launch per
  configuration:
  - the Today root (top, then each screen scrolled)
  - Seeds (top, scrolled)
  - Garden
  - Journal
  - Settings (top, then each scroll page)
  - seed detail for a named fixture seed (top, the planting panel)
  - bed detail for North bed (top, the canvas)
  - a named journal entry
  - Add Seed (top, scrolled)
  - What to Plant
  - random pick
  - What's New
  - each Settings sub-screen
  
  Each audit runs after checking `screen.<name>`. Waits are bounded and
  wait on elements, never fixed sleeps.
- **Named exclusions,** covered by the manual checklist:
  - picker destination lists
  - entry and recovery states
  - photo-failure UI
  - the camera and scan
  - native sharing
  - regular-width iPad, until its simulator is approved, with its own
    navigation adapter
- **The never-touch list,** which the audit doesn't activate:
  - "Check iCloud account" and "Sync now"
  - sharing, Leave and Delete
  - API key fields
  - photo pickers
- **Allowlist (`AuditAllowlist.swift`):**
  - **Matching:** each entry matches the destination and checkpoint, the
    audit type, the exact element identifier, and the configuration. An
    exact label plus element type is used only when the element has no
    identifier.
  - An issue with no element always fails.
  - Every suppression is logged with its reason and the condition for
    rechecking it, and unused entries are reported.
  - The allowlist starts empty, and each entry is marked either "accepted
    limitation (verified false positive)" or "deferred defect" with a
    phase. Deferred defects need the owner's approval.
- **`scripts/a11y-audit.sh <simulator UDID>`:**
  - The UDID is required, with no fallback.
  - It runs serially, with its own DerivedData and a result bundle per
    run, in the scratch directory.
  - It fails on: zero tests, skips, a missing configuration, an audit
    execution error, a timeout, or an unallowlisted finding.
  - It prints the date, time zone and a per-configuration summary, and
    keeps logs.
- **Budget:** one configuration is timed first. The full-run budget is set
  from that and recorded in the script.

## R2d-3 — Manual checklist and acceptance report (lead)

- **`.docs/ai/plans/2026-10-20-a11y-manual-checklist.md`**, with pass and
  fail boxes:
  - **VoiceOver:**
    - read order and meaningful descriptions on Today, Seeds and Settings
    - bed canvas move actions, keeping focus after a move
    - picker navigation at accessibility sizes
  - **iPad portrait:** inspector access.
  - **macOS keyboard:**
    - Cmd+1 to 4 and Cmd+,
    - Tab through the Seeds table and inspector
    - the command palette
  - **Appearance override:** including the sharing sheet.
  - **The excluded states** listed under R2d-2.
- **The checklist's delivery and the owner's run are separate claims.** R2d
  is complete when the audit passes. Manual acceptance stays open until the
  owner runs it.

## R2d verification (lead)

- `scripts/test-gate.sh` passes, with the previous counts plus the R2d-1
  tests.
- `scripts/a11y-audit.sh` completes all 4 iPhone configurations with no
  unallowlisted findings.
- Opus and Sol review the diff.

## R2c results (2026-10-20)

- **Commits:**
  - 924b0b8: C0 and C1
  - 2f59a8e: appearance fix
  - 111afcb: C3
  - the bed-canvas label fix, committed with this note
- **Found by the dark-mode pass:** choosing Light or Dark had no effect. The
  `App` struct's `@AppStorage` didn't re-render the scene. Fixed with a view
  modifier and a single shared `DevicePreferences.store`. Verified with the
  device in dark and the app set to Light.
- **Sample-garden isolation went further than C0 planned.** Every
  notification toggle is now read through `DevicePreferences.store`, and
  in sample-garden mode `NotificationsCenter` and the weather scheduler
  never prompt, schedule or clear. There's no test seam on the system
  notification center, so this is checked by review.
- **Review fixes:**
  - **Opus on C3:**
    - drag in the canvas's coordinate space
    - one search field in the Seeds toolbar
    - wide layouts keep the inspector state
    - the inspector policy is iPad only (Mac unchanged)
    - one-axis VoiceOver moves leave the other axis alone
  - **Sol:**
    - the Appearance picker shows System for an unknown stored value
    - canvas labels truncate to the canvas width and are hidden past its
      bottom edge
- **Found by the largest-size screenshots:** bed canvas labels covered their
  dots, collided with the size label, and ran off the edge.
  - Labels now hang below their dots, stay inside the canvas, and avoid
    the size label.
  - **Decision:** the to-scale canvas caps its text at the largest standard
    size (`xxxLarge`). Each name stays in its VoiceOver label and in the
    events list. This is the only Dynamic Type cap in the app.
- **Checked in screenshots** (iPhone, sample garden):
  - **Dark at the default size:** Today, Seeds, seed detail, Settings.
  - **Largest size:** Journal (the date above the entry), the bed canvas.
- **Open (owner):**
  - **Mac visual check:** appearance, and whether the inspector state is
    kept.
  - iPad screenshots (the iPad simulator needs approval).
  - VoiceOver on the bed canvas move actions.
  - A dark-mode glance on the phone.
  - Sharing under an appearance override.
- **Next:** R2d, the automated accessibility audit (outlined above).

## R2d first audit run (2026-10-21)

- **The harness works** (`SeedkeepUITests`, scheme
  `SeedkeepAccessibilityAudit`, `scripts/a11y-audit.sh <UDID>`).
  - The gate's `Seedkeep` scheme has no UI tests.
  - Each configuration's appearance and text size is confirmed in
    effect: background luminance 0.96 light / 0.08 dark; the Today title
    is 40.7 pt by default and 71.7 pt at XXXL.
  - **Time:** about 7 to 8 minutes per configuration, about 30 minutes for
    all four, plus the build.
  - In one of three full runs, `performAccessibilityAudit` hung once (dark,
    XXXL, at the planting panel). The script reported it as a timeout.
- **Findings with an empty allowlist: 512.**
  - **By configuration:** light/default 184, dark/default 175,
    light/XXXL 79, dark/XXXL 74.
  - **By type:** Dynamic Type 244, contrast 182, clipped text 86.
  - 148 have no element.
- **Triage, which isn't done yet:**
  - **Dynamic Type, mostly at the default size, on text using text styles**
    (Settings, Notifications, Home location, the planting panel):
    - The R2a–R2c screenshots show this text scaling at the largest size,
      so these look like audit false positives.
    - Each needs checking before it's allowlisted as an accepted
      limitation.
    - The deliberately capped bed canvas is expected.
  - **Contrast:**
    - **Likely false positives from pixel sampling:**
      - text under the translucent nav bar after scrolling (the Today
        date)
      - small caps headers whose token pairs pass the WCAG tests
    - Each needs checking against the token tests.
  - **System controls:**
    - nav-bar text buttons (Cancel, Save, Done, Close) and UIKit text and
      search fields
    - fixed system styling, with Large Content Viewer
    - candidates for "accepted limitation"
  - **Issues with no element (148):**
    - The contract fails these unconditionally, so they can't be
      allowlisted.
    - Their source needs investigating: probably decorative or empty
      text-styled elements in the Seeds rows and the Settings section
      chrome.
- **Tab identifiers** reach the tab buttons only sometimes; the harness
  falls back to the tab's label.
- **Status:** the audit doesn't pass yet. Clearing it needs a triage and
  fix pass, which is next. The manual checklist is in
  `2026-10-20-a11y-manual-checklist.md`.

## R2d triage (2026-10-21)

The owner's decision: fix the real defects, allowlist only what can be
shown not to be an app defect, and record the rest as known audit noise.
Then move on to R3.

- **Real fixes:**
  - **Filled (bordered-prominent) buttons:** they use `accentInk` text. White
    on the dark-mode accent was about 2:1. "Pick another" no longer fails.
  - **Form footers:** they use `wbFootnote` and `muted`. The system
    secondary grey was about 3.5:1 on our backgrounds.
  - **Bed canvas labels:** they sit on an opaque `panel` capsule.
  - **Decorative "·" separators:** hidden from VoiceOver.
- **Allowlist:** 80 accepted limitations, each with its evidence.
  - Dynamic Type on system toolbar buttons (Large Content Viewer).
  - Clipping flagged on system text fields, search fields and the inline
    navigation title.
  - Dynamic Type on text set in a text style. These are checked in the code,
    not measured per element.
  - The bed canvas text, which is capped at `xxxLarge` by design.
  - No contrast finding is suppressed.
- **Second run:** 289 unresolved findings, down from 512 (light/default 98,
  dark/default 83, light/XXXL 57, dark/XXXL 51).
  - **By type:** contrast 199, Dynamic Type 51, clipped text 39. 138 have
    no element.
  - Every configuration completed, with no hang this time.
- **Unresolved, suspected audit noise.** These are recorded here and not
  suppressed:
  - contrast on ink or muted text on opaque surfaces whose token pairs pass
    the WCAG tests: the bed canvas names, Today's rows and headers, the
    Settings About text, section headers
  - contrast on system toolbar buttons
  - Dynamic Type on the Privacy Policy and Support links
  - clipping on "Share garden via iCloud", "Check iCloud account" and "Add
    photos" (plain labels, no line limit)
  - the 138 element-less issues
  
  Confirming any of these needs per-element measurement or Accessibility
  Inspector, which belongs in the manual checklist and R5 QA.
- **Status:** the audit runs and reports, but it doesn't pass. That's
  expected at this level of investment. Rerun it before release and compare
  against these counts.
