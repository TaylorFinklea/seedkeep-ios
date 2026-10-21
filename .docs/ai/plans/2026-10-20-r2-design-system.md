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
