# R1: Workbench shell and Seeds table (contract)

Umbrella plan: `~/git/seedkeep/.docs/ai/phases/2026-10-15-native-workbench-redesign-plan.md`.
Branch: `redesign/r1-shell-seeds` (from `redesign/m0-mac` at `8ccff15`).

This is the first usable milestone: the Workbench shell and a spreadsheet-like
seed library, on iPad (regular width) and Mac.

## Scope

**In scope:**
- Workbench shell on iPad (regular width) and Mac:
  - a sidebar, with the Seeds table as the main screen
  - menus and keyboard shortcuts
  - a ⌘K command palette
  - CSV export
- **Inspector:** seed detail appears in an inspector beside the table.
- **Existing screens in the sidebar:** Today, Garden, Journal and Settings
  stay as they are and open from the sidebar.

**Out of scope:**
- **Compact width:** iPhone, and iPad in compact Split View, keep today's
  tab UI unchanged. The compact restyle is R2.
- **Dark mode:** forced light stays until R2. The tokens already define dark
  values.
- **Other screens:** Planting windows and the Garden redesign are R3. Today,
  Journal, Settings and CSV import are R4.
- **No data-model, sync or CloudKit schema changes.**

## Design decisions (owner, 2026-10-16)

- **Fonts:** system fonts. SF Pro for text, SF Mono (`.wbMono`) for numbers,
  dates, counts and keyboard hints. Sizes come from text styles.
- **Colours:** Workbench tokens in `DesignSystem/Workbench/WBColor.swift`
  (parent-owned). New surfaces use only `WBColor` and `WBMetrics`, never
  literal colours.
- **Verdict labels:** use the app's existing wording, so both screens agree
  during the transition. The colours are Workbench (`WBColor.verdict`).

## Parent-owned contract (do not edit; ask the parent)

- `Seedkeep/DesignSystem/Workbench/WBColor.swift`: `WBColor`, `WBMetrics`,
  and the `Font.wb*` styles.
- `Seedkeep/Features/Workbench/WorkbenchModel.swift`:
  - `WorkbenchRoute` and `SeedsRequest`
  - `WorkbenchModel`:
    - the route
    - `selectedSeedIDs`
    - palette and inspector flags
    - `isEditingText`
    - a **queued** request API, `request(_:)` and `takeSeedsRequests()`,
      which drains each request exactly once
    - `reveal(seedID:)` with `revealedSeedID`
    - `resetForScopeChange()`
  - One instance per window.
- `Seedkeep/Features/Workbench/SeedTableRow.swift`: the `SeedTableRow` value
  type plus the `rows(seeds:locations:tags:recommendations:)` signature.
  Slice B replaces the placeholder body and may add fields, but not rename or
  remove any.
- `Seedkeep/Platform/Platform.swift` and `project.yml`.

## Revisions after Sol's contract critique (2026-10-17, binding)

1. **iPad column policy.**
   - **iPad (regular width):** Name, Status, Pkts, Year, Stored in and
     Window. The other fields are in the inspector.
   - **Mac:** all ten columns.
   - **Acceptance width:** 11-inch iPad in landscape, with the sidebar and the
     inspector both open; no clipped controls.
   - **Touch multi-selection:** a Select toolbar button toggles selection
     mode.
   - **Sorting:** sort the array explicitly. Blanks sort last in both
     directions, and ties break by `id`.
2. **Editing and focus.**
   - Drafts live in `SeedEditing`, keyed by `(seedID, field)`, not in cells.
   - Blurring away from an invalid draft keeps the draft and shows the error;
     it doesn't commit.
   - Escape discards the draft, and the blur that follows doesn't commit.
   - If the seed changes remotely during an edit, the draft is kept and the
     commit patches only that field. If the seed is deleted remotely, the
     draft is discarded with a notice.
   - Focus and scroll position return to the edited row (by id) after a
     re-sort.
   - While text is being edited, `WorkbenchModel.isEditingText` is true and
     Delete is disabled.
3. **Inspector.**
   - `SeedDetailView` sits inside its own `NavigationStack` (its Tags link
     needs one) and is keyed with `.id(seedID)`, so drafts and cached state
     reset when the selection changes.
   - It guards deleted and foreign-household seeds. Deleting the shown seed
     clears the selection and shows the hint.
   - Existing destination screens already own their stacks, so don't wrap
     them again.
4. **Commands.**
   - They use the queued request API. Plain `onChange` loses early requests;
     the queue doesn't.
   - The model is published with `.focusedSceneValue` only by signed-in
     Workbench windows.
   - `MainTabView`'s banner and requested-tab behaviour are kept.
5. **Data guarantees.**
   - Patches change only the edited field. A clear is sent explicitly as
     `.some(nil)`. The type goes through `setLocalCustomType`.
   - Write errors are surfaced to the user, never swallowed.
   - **Undo registration:** register undo only after a write succeeds, with
     the reciprocal patch. Group bulk changes into one undo step.
   - **Partial failures:** if some seeds in a bulk change fail, report which,
     and register undo only for those that succeeded.
   - **On undo:** check again that each seed still exists and still belongs
     to the household.
   - **No UndoManager:** if the environment has none, use a per-window one.
   - **Merge limits:** the CloudKit merger is last-writer-wins per record,
     with packet minimum and tag union (`SeedkeepMerger.swift`). So remote
     fields are kept where the merger keeps them; nothing stronger is
     promised.
6. **Live-data scope.**
   - **Household:** seeds, tags and locations use the same
     `activeGardenHouseholdID` scoping as the Library, shared-owner scope
     included.
   - **Scope change:** call `resetForScopeChange()`, and clear drafts and
     undo.
   - **Selection pruning:** prune against the household's live rows, not just
     the visible ones.
   - **Revealing a seed** clears any filter or search that would hide it.
   - **Recommendations:** `@Query` them once into a catalog-id dictionary;
     never one fetch per row.
   - **Refreshing verdicts:** use the store's existing location-signature
     logic and `bulkRefresh` in chunks of 200 ids or fewer.
7. **Seam between the slices.**
   - **Feed:** the shell (A) owns one live feed (`@Query` seeds, tags,
     locations and recommendations, household-scoped). It calls B's
     `SeedTableRow.rows(...)` and passes rows plus a `[id: LocalSeed]` lookup
     into `SeedsTableView(model:rows:seedsByID:)`.
   - **Off-route uses:** the sidebar count and the palette use the same rows
     while another screen is showing.
   - **Placeholders:** B's `SeedsTableView` replaces A's placeholder at
     integration.
   - **Palette ranking:** prefix matches first, then word-start, then
     substring. Ties go Actions, then Go to, then Seeds, then alphabetical.
   - **CSV scope:** export the selected rows if any are selected; otherwise
     the current filtered and sorted rows.
8. **Acceptance.**
   - Empty, loading and no-match states.
   - Commands are disabled when signed out.
   - VoiceOver labels on cells, controls and validation errors.
   - Dynamic Type at accessibility sizes on iPad without clipping.
   - Keyboard navigation through the table and palette.
   - 44 pt touch targets.
   - Multiple windows on Mac and iPad, and resizing between regular and
     compact width.
   - A measured performance check: mapping and sorting 1,000 seeds in under
     50 ms in tests, plus a manual scroll check.

## Data rules (both slices)

- **Reads:** use SwiftData `@Query` (live, so remote CloudKit changes appear
  on their own).
  - Seeds of the signed-in household with `deletedAt == nil`.
  - Tags and locations come from `LocalTag` and `LocalLocation` by id.
  - Verdicts come from `RecommendationStore` and `LocalRecommendation`, keyed
    by `catalogID`.
- **Writes:** only through `SyncEngine`, exactly as the existing Library and
  SeedDetail screens do:
  - `enqueueUpdateSeed(id:_:)` with an `UpdateSeedInput` patch that sets only
    the changed fields. A remote change to another field survives.
  - `setLocalCustomType(seedID:type:)` for the type.
  - `enqueueDeleteSeed(id:)` for deletes.
  - Then follow the existing call pattern.
  - Never write `LocalSeed` properties directly from the UI.
- **Household:** same scoping as `LibraryView`.

## Slice A — shell, commands, palette (Luna)

You own:
- `Seedkeep/Features/Workbench/WorkbenchShell.swift`
- `Seedkeep/Features/Workbench/WorkbenchSidebar.swift`
- `Seedkeep/Features/Workbench/WorkbenchCommands.swift`
- `Seedkeep/Features/Workbench/CommandPalette*.swift`
- the shell-switch edit in `Seedkeep/App/SeedkeepApp.swift` (RootView) and/or
  `Seedkeep/Features/MainTabView.swift`
- `SeedkeepTests/Workbench{Shell,Commands,Palette}*Tests.swift`

Requirements:
1. **Shell switch:**
   - In RootView's signed-in branch, iOS regular width and macOS show
     `WorkbenchShell`; iOS compact width shows today's `MainTabView`,
     unchanged.
   - Switching size class at runtime (iPad Split View) must not lose the
     sign-in state or crash.
   - Each window owns a `WorkbenchModel` (`@State`) and publishes it with
     `.focusedSceneValue`.
2. **WorkbenchShell:**
   - A `NavigationSplitView` with the Workbench-styled sidebar
     (`WorkbenchRoute.allCases`: title, SF Symbol, and the count for Seeds).
   - The detail shows `SeedsTableView` for `.seeds` (slice B's view; until
     it lands, use a placeholder file that slice B replaces). The existing
     views (Today, Garden, Journal, Settings/You) show for the other routes,
     unchanged.
   - Sidebar selection is bound to `model.route`.
   - The palette is a sheet or overlay bound to `model.isPaletteOpen`.
3. **Commands** (`WorkbenchCommands: Commands`, installed on the
   WindowGroup):
   - A Seeds menu:
     - New Seed ⌘N → `request(.newSeed)`
     - Find ⌘F → `request(.focusSearch)`
     - Export CSV… ⇧⌘E → `request(.exportCSV)`
     - Delete ⌫ → `request(.deleteSelection)`; disabled when nothing is
       selected or `isEditingText` is set
     - Command Palette ⌘K
   - A Go menu: Today ⌘1, Seeds ⌘2, Garden ⌘3, Journal ⌘4. Settings uses
     macOS's standard ⌘, (the Settings scene can wait until R4; until then,
     route to `.settings`).
   - Commands act on the focused window's model (`@FocusedValue`). With no
     focused model they're disabled.
   - The same commands appear in the iPadOS 26 menu bar and keyboard
     shortcut overlay.
   - No single-letter shortcuts that fire while typing.
4. **Command palette:**
   - A search field and a list of up to 9 results, case-insensitive across
     title, hint and group.
   - Groups: Actions (New seed, Export CSV, Find), Go to (each route), and
     Seeds (one per seed, from `SeedTableRow`).
   - Choosing a seed calls `model.reveal(seedID:)`.
   - ↑/↓ moves, Return chooses, Escape closes. Clicking and tapping work.
     Results use `WBColor.paletteSelection`.
   - Reachable by touch: a toolbar button on iPad.
5. **Tests:**
   - route and title mapping
   - commands set the right model state, and are disabled with no
     selection or no model
   - palette filtering, ranking and the 9-result cap
   - `reveal` behaviour
   - shell choice by size class (a pure function you can test)

## Slice B — Seeds table (Haiku 5.5)

You own:
- `Seedkeep/Features/Workbench/SeedsTableView.swift`, `SeedsToolbar.swift`,
  `SeedsBulkBar.swift`, `SeedsInspector.swift`, `SeedsTableModel.swift`,
  `SeedEditing.swift`, `SeedCSV.swift`
- the `SeedTableRow` mapping in `SeedTableRow.swift` (an added extension;
  the struct fields stay)
- `SeedkeepTests/Seeds{Table,Editing,CSV}*Tests.swift`

Requirements:
1. **Rows:**
   - `SeedTableRow.rows(seeds:locations:tags:recommendations:)` maps live
     models to rows: display name, location and tag names, verdict raw
     value and existing label.
   - Search covers name, variety, company, type and notes, case-insensitive.
   - State filter tabs show counts (All, Active, Wishlist, Saved, Archived),
     plus a type filter.
2. **Table** (regular width, SwiftUI `Table`):
   - Columns: Name, Variety, Type, Company, Year, Pkts, Status, Stored in,
     Tags, Window (a verdict dot and label). Numbers use `.wbMono`.
   - Header sorting by `KeyPathComparator`, both directions. Blanks always
     sort last.
   - Multi-selection bound to `model.selectedSeedIDs`, kept by id across
     sorting and live updates. Rows that disappear are dropped from the
     selection.
3. **Inline editing contract:**
   - Inline edits cover Pkts and Year (numeric field), Status (picker) and
     Stored in (picker). Text fields (name, variety, company, type, notes)
     are edited in the inspector.
   - An edit is a draft. Enter or losing focus commits; Escape cancels and
     restores the value.
   - Validation:
     - packets: an integer of 0 or more
     - year: empty or an integer from 1900 to next year
     - an invalid draft shows an inline error and doesn't commit
   - A commit writes only the changed field through `SyncEngine`.
   - Focus stays on the same row (by id) after the commit re-sorts.
4. **Undo:**
   - Inline commits and bulk state, location and tag changes register undo
     on the window's `UndoManager`. Undo restores each seed's previous
     values through `SyncEngine`, and redo re-applies them.
   - Deletes have no undo, so they always ask for confirmation, naming the
     count.
5. **Bulk bar** (when there's a selection):
   - Set status, Move to location, Add tag (no duplicates), Delete (with
     confirmation), and Clear selection.
   - Bulk changes are applied per seed as patches.
6. **Inspector:**
   - `.inspector(isPresented: $model.isInspectorOpen)`.
   - **One seed selected:** the existing `SeedDetailView` for it, reused, not
     rewritten.
   - **Several selected:** a short summary (count and states).
   - **None:** a hint.
7. **Requests:** on appear, and whenever `pendingSeedsRequests` changes,
   handle `model.takeSeedsRequests()`:
   - new seed → present the existing add flow
   - export → `fileExporter` with CSV
   - focus search → focus the search field
   - delete selection → confirm, then delete

   Handle `revealedSeedID` too, clearing hiding filters.
8. **CSV export** (`SeedCSV`):
   - The columns are name, variety, type, company, year, packets, status,
     stored_in, tags (`; `-joined), notes and window.
   - RFC 4180 quoting for commas, quotes and newlines; UTF-8 with a header
     row; the current filter and sort; all seeds when nothing is selected.
   - The file name is `seedkeep-seeds-YYYY-MM-DD.csv`.
9. **Styling:** `WBColor` and `WBMetrics` only, with dense rows. Toolbar and
   bulk-bar controls meet the 44 pt touch target on iPad.
10. **Tests** (in-memory containers; see the existing tests for patterns):
    - row mapping
    - sorting with blanks last
    - search and filters, and the counts
    - inline edit validation and commit (only the changed field is patched;
      `updatedAt` advances)
    - undo and redo of an inline edit and of a bulk change
    - bulk actions on several seeds
    - delete needs confirmation (model-level)
    - CSV escaping and column order
    - selection pruning when a seed disappears

## Parent

- Integration and the full gate.
- The Opus 5.5 and GPT-6.1 Sol reviews.
- Device checks on the iPad simulator in regular width and on the Mac.
- Signed Mac checks continue separately (owner sign-in checklist).

## Gates

- `scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171`
  (packages, iOS app in both modes, macOS app in both modes). Counts must
  not drop: iOS 769 + 1, macOS 783 + 1, plus new tests.
- iPad build and launch on the "Seedkeep iPad" simulator (`1B4EF142…`).
