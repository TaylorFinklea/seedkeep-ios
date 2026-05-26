# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-26 — V2 Herbarium redesign shipped to TestFlight (build 24, 0.4.0)

Full visual redesign across every screen. Goal: shift from neutral
"iOS app" chrome to a scholarly-monastic herbarium aesthetic
(vellum paper, sepia ink, sage washes, italic display serif,
small-caps rubrics). The user is the gardener; the app is the herbarium.

### Design system (new)
- `Seedkeep/DesignSystem/Herbarium/` — 12 files, ~5,900 lines.
- **Fonts**: Spectral (light/regular/medium + italics), IM Fell English SC, Caveat. Bundled as TTF in `Resources/Fonts/`, declared in `UIAppFonts` via `project.yml`.
- **Tokens**: `HerbColor` (dynamic light/dark via `dyn(light:dark:)` UIColor helper — light is vellum-and-sepia, dark is "leather library at night"), `HerbFont` (with view modifiers `.herbRubricStyle`, `.herbDisplayStyle`, etc.), `HerbRomanNumeral` (Int → "i/ii/iii..." for folios + display elements).
- **Components**: `VellumBackground` (radial gradient + seeded speckle noise + vignette), `TapeStrip`, `ScholarRule` (◆◇◆), `Rubric` (small-caps + Roman num heading), `FolioStrip` (top "Section · fol. xxiii" marker), `SunArc` (NOAA-computed sunrise/sunset — no WeatherKit call), `SuitabilityBar` (60-day planting window strip), `PressedPlant` (20 hand-drawn SVG-equivalent shapes mapped from free-form `customType` via `PressedPlant.Kind.from`).

### New screen: Today / Diurnalis (default landing)
- `Seedkeep/Features/Today/TodayView.swift` — 7th tab inserted at position 1. Date heading ("The XXVI of May, MMXXVI" in IM Fell English SC sepia caps), italic "Today's specimens" display title, sun arc (uses cached household lat/lon), today's + overdue planting events with `PressedPlant` illustrations, handwritten Caveat margin note pulling the most recent journal entry from the last 48h. Falls back gracefully when home location isn't set.
- `MainTabView` now 7 tabs: Today / Library / Garden / Journal / Sprout / Settings / You. Default selection is `.today`.

### Existing screens restyled
- **Library** (`Pressed specimens`): vellum bg, folio strip ("Hortulus"), italic display title with Roman-numeral count subtitle, custom lifecycle filter strip (Active / Wished / Saved / Archived with rose underline on active), 2-col `LazyVGrid` of specimen cards (corner tape strips, Roman specimen number, pressed-plant illustration, binomial / name, verdict-dot provenance footer). Native `.searchable` + the existing toolbar (random/scan/add) preserved as liquid-glass.
- **Seed Detail**: vellum-skinned Form, hero block at top (italic sepia binomial, italic display name, family/cultivar line, scholar rule, central pressed plant + hand-drawn inches ruler). All existing edit logic intact.
- **Garden** (`Abbey grounds`): folio strip ("Hortus"), italic display title with Roman plot count, bed rows with Roman numerals + italic dimensions + next-event line.
- **Bed Detail**: vellum bg, scholarly italic "Plot · the abbey grounds" subtitle above bed name.
- **Journal** (`Daybook`): vellum-skinned List, folio strip + italic display title, retrospective card preserved, entry rows now use a left-side date roundel (MAY · 22 · MMXXVI).
- **Sprout tab**: folio strip ("Scriptorium"), italic display title, starter prompts as flat-bordered vellum cards, thread rows with ✦ glyph + Roman numeral hint.
- **Sprout chat**: vellum bg, small-caps role tags ("— the gardener" / "Sprout ✦") above each bubble, user side sage-washed, assistant side parchment with sepia accent stripe. Caveat handwriting composer; sepia send button.
- **Settings** (`The Order`): full restyle. Folio strip, italic display title, "House of Finklea" subtitle, 7 Rubric-styled sections (inventory / garden / sprout · the scribe / backend / household / invite / sync) with Roman numerals. **NEW**: "Sparkle on every page" `AppStorage` toggle — `SproutFAB` reads this and hides itself when off.
- **You** (`House`): full restyle as steward/house panel.
- **Add Seed**: vellum bg + scholarly title block above the form ("Lay a new packet / Add seed" or "Confirm specimen" when arriving from scan).
- **Tab bar**: native liquid glass chrome preserved; only the labels' font/tracking changed to IM Fell English SC via `UITabBarItem.appearance()` in `SeedkeepApp.init`.

### Dark mode
- Baked into `HerbColor` via `dyn(light:dark:)`. Light = vellum cream + sepia ink. Dark = deep cocoa surfaces + parchment-cream ink + warmer sepia/sage. All herbarium-styled surfaces shift automatically when the system theme changes.

### Server
- No changes this session. Last deploy: Fly v17 from the Phase 4 Sprout push (2026-05-25).

## TestFlight

- **0.4.0 (build 24)** uploaded 2026-05-26 — full V2 Herbarium redesign + all screens.
- 0.4.0 (build 23) — was the popup-FAB + Random-in-Library-toolbar change (2026-05-25 evening). Awaiting device-verification.
- 0.4.0 (build 22) — `/api/` prefix fix on Sprout routes (2026-05-25 evening). Awaiting device-verification.

## What's next (suggestions)

- Device-verify build 24 on TestFlight. The vellum bg renders best on real hardware; verify that the Caveat handwriting + IM Fell SC fonts load (if not, the labels will silently fall back to system serif — visible by lack of small caps on tab labels and lack of cursive in the composer).
- Consider follow-up polish where the herbarium aesthetic doesn't fully land yet: ScanFlow camera screens, RecommendationPanel, EntityScopedJournalSection cards in Seed Detail.
- Phase 4 B/C/D from `roadmap.md` (photo-of-corner suggestions, native push warnings, community catalog UI) are still pending.
- 7945ms scan-confirm freeze regression logged in an earlier session is still open.
