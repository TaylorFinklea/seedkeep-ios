# R4 — Today, Journal, Settings, flows and CSV import (contract)

Status: approved (2026-10-21) after two rounds of Sol's critique. Sol's
suggestion to move C to a lighter worker was declined: C is data-safety
work, so it stays on Opus. Owner decisions are in
the umbrella `decisions.md` ([2026-10-21] R4). Branch
`redesign/r2-design-system`.

## Owner decisions (fixed)

- **Today is a dashboard:** six due rows plus a "+N more" row that opens
  Garden, and a "This week" block with the seeds to plant now or soon and
  the frost count. No seasonal care.
- **CSV import round-trips the export.** A row matching an existing seed
  (name, variety, company, year) updates it. Missing locations and tags are
  created by name. A preview shows the counts first.
- **Mac Settings is a standard Settings window** (⌘, from the app menu).
  iPad keeps the sidebar route.
- **Journal gets search and filters** (seed, bed, planting).

## Invariants

- No data-model or CloudKit schema change, and no migration.
- **Writes use the existing mutation boundaries:** `SyncEngine` enqueue
  methods and `setLocalCustomType` for seeds, and `JournalStore` for Journal
  entries.
  - Edits send only changed fields. A field with no change is omitted
    (outer `nil`); a nullable seed field is cleared with `.some(nil)`.
  - An empty patch is never enqueued.
  - Sync stays whole-record last-write-wins with sticky deletes.
- Before writing, every bulk or deferred write re-checks that the active
  garden household is the one the screen was opened in, and that its
  target records are still live.
- **The R2 rules carry over:**
  - tokens, and tested contrast
  - text that scales; side-by-side layouts switch on
    `isAccessibilitySize`
  - labels, ≥44pt targets, dark mode
  - sample-garden mode
  - identifiers on new screens and controls
- Pure logic is unit tested; writes get integration tests over the
  in-memory store and `SyncEngine`.
- **Files:** each slice lists the files it owns. Tests, the screenshot
  driver, the DEBUG fixture and audit files may change in any slice.

## T — Today dashboard (worker)

Files: `Seedkeep/Features/Today/*`. Today already receives
`WorkbenchModel?` (nil on compact); no new host interface.
- **Order:** title and date, the daylight panel, **This week** (new),
  **Due**, then the journal line. G4's frost banner moves into This week.
- **This week** (`TodayWeek`, pure):
  - **Inputs:** the same as Windows.
    - `WindowSeed` rows built as `WindowsView` builds them: the active
      garden's live, non-archived seeds, as `WindowsGrouping` filters them,
      including wishlist and saved seeds.
    - `WindowsGrouping.sections`, `WindowsRowFormat`, and the
      recommendations computed for today.
    - Count all eligible seeds before any cap.
  - **Frost first:** when G4's count is above zero, the block opens with
    G4's warning banner ("<n> planting(s) may meet frost (zone estimate).",
    Open Garden) and its existing routing.
  - **The summary line:**
    - "<n> to plant now · <n> soon", leaving out zero parts.
    - With a home location and nothing now or soon: "Nothing to plant this
      week".
    - While recommendations are loading or syncing: the existing loading
      treatment, not "nothing".
  - **Up to five seed rows:** Plant now first, then Plant soon, in Windows'
    order. Each row shows the name, the group and Windows' timing text,
    and opens the seed.
  - **"See all in Windows"** routes by host:
    - On compact, Today presents `WindowsView` as a sheet with
      `WindowsHost.compactGardenSheet` and the window's existing
      `GardenSession`. Plan, New bed and resume behave as from Garden's
      sheet.
    - On the workbench, the route switches to `.windows`.
  - **No home location:** one line, "Set a home location to see planting
    windows", linking to the existing home-location screen. No
    recommendations are computed.
- **Due:**
  - `TodayDue.queue` keeps its six-row truncation.
  - The overflow count comes from the full household-scoped due set,
    before truncation, using the same query and filters.
  - When it is above zero, a row "<n> more due" opens Garden through G4's
    host routing.
- **Accessibility:**
  - Each This week row is one element: "<name>, <group>, <timing>".
  - The summary is a header.
  - The overflow row is a button: "<n> more due, open Garden".
- **Tests:**
  - summary wording, including zero parts, loading and no location
  - eligibility, matching Windows
  - ordering and the five-row cap, with counts taken before it
  - overflow at 0, 6, 7 and 20 due items
  - frost-banner placement
  - routing by host
  - the accessibility labels

## J — Journal search and filters (worker)

Files: `Seedkeep/Features/Journal/*` (including `JournalEntryView` and
`AttachedEntityPicker`).
- **Query:**
  - `JournalView` queries all of the household's live entries.
  - `filterParent:` (from "See all") becomes the initial value of a mutable
    filter, not part of the `@Query`, so clearing the chip shows the whole
    feed.
  - Refresh, the header and the RetrospectiveCard follow the current
    criteria.
- **Search** (`JournalFilter`, pure):
  - `.searchable`, prompt "Search journal".
  - Whitespace-only text means no search.
  - Matching is case- and diacritic-insensitive. Every token must match
    somewhere: the body, or the display name of the entry's attached seed,
    bed or planting. Tokens may match different fields.
- **Filters:**
  - A "Filter" menu offers every live seed, bed and planting in the
    household, not just the latest 20.
  - **Labels:** seeds use `displayName`; plantings are "<kind> · <date> ·
    <seed or Note>".
  - **What each filter matches:**
    - a seed: entries attached to it, or to any of its plantings
    - a bed: entries attached to it, or to plantings in it
    - a planting: entries attached to it
  - One filter at a time, combined with search, shown as a removable chip
    ("Seed: Brandywine ✕").
  - A household change clears the filter, and so does the filtered entity
    being deleted.
- **New entry from a filtered Journal:**
  - It pre-fills that parent through a parent-aware creation path
    (`JournalEntryView(entryID: nil, initialParent:)`), with at most one
    attachment.
  - Saving re-checks that the parent is live and in the household the
    draft was opened in; otherwise it refuses with a message.
  - This resolves the TODO in `JournalView`.
- **States:**
  - The normal empty and loading states stay.
  - "No entries match", with Clear, shows only when search or a filter is
    active and nothing matches.
  - The header reads "3 of 41 entries" while filtered.
- **Accessibility:**
  - The chip's remove button is labelled "Remove filter, <kind> <name>".
  - The result count is announced once typing pauses (debounced), not on
    each keystroke.
- **Tests:**
  - tokens across fields, case and diacritics, whitespace-only search
  - seed and bed filters reaching planting attachments
  - a deleted attached entity still matching on the body
  - header counts and states
  - the initial filter and clearing it
  - the pre-filled parent, including refusal on save after a household
    change
  - filters cleared on a household change or deletion

## S — Settings, legacy cleanup and flow polish (worker; owns the shared route changes)

Files:
- `SeedkeepApp.swift`, `WorkbenchCommands.swift`, `WorkbenchModel`,
  `WorkbenchSidebar`, `CommandPaletteView`
- `Seedkeep/Features/Settings/*`
- for styling only: `CloudEntryView`, `GardenChooserView`,
  `EntryProgressView`, `InviteAcceptView`

S owns the route and palette changes; C builds on S's.
- **macOS Settings window:**
  - A `Settings { … }` scene, macOS only, hosts
    `NavigationStack { SettingsContent() }`.
  - **It gets the same instances `mainRoot` gets, applied explicitly:**
    `AppEnvironment`, auth, the model container, `AppAppearanceModifier`
    and tint.
  - It never copies `RootView`, its startup tasks, or any per-window
    Workbench state.
  - **When there's no active garden** (signed out, loading or no
    household), it shows a short explanation in place of household-scoped
    rows. App-wide rows (Appearance, About) stay usable.
  - Opening it during startup or with every main window closed must not
    crash or start anything.
  - It has a sensible minimum size, and sub-screens push inside it.
- **Routes:**
  - `WorkbenchRoute.settings` stays in the enum; iPad and exhaustive
    switches still need it.
  - On macOS it's excluded from the sidebar, the palette's Go items and
    the Go menu's ⌘, item, so the system Settings… item owns ⌘,.
  - iPad keeps the route and its ⌘, item; iPhone keeps the tab.
  - A pure per-platform route and command list makes this testable.
- **Legacy cleanup** (settings the server-free app can't reach now):
  - In `SettingsContent`, remove the Server and Subscription sections,
    which are gated off.
  - In `AIProviderSettingsView`, remove the "Hosted" option and the
    server-tier rows. A stored "hosted" selection reads as the BYOK
    default; stored keys are untouched.
  - Remove the hosted-tier copy in `APIKeysSettingsView` and the "House"
    copy in `NotificationsSettingsView`.
  - Keep BYOK and the existing Apple-only behaviour.
  - Unreachable files (MCP, AssistantKey, Server and Subscription views,
    `AccountDeletionFlowView`, `YouView`) stay for N3; don't touch them.
- **Flow polish:**
  - `NotificationsSettingsView` gets `.wbForm()`; it must not be applied
    twice.
  - Check the four entry screens named above against R2's criteria:
    tokens only, `WBScreenBackground`, scalable text styles, ≥44pt
    buttons, and accent and warn ink for prominent buttons. Fix what falls
    short and list what changed.
  - Scan's dark camera chrome stays (an intentional exception).
- **Tests:**
  - the per-platform route and command lists
  - Settings sections present and absent
  - the AI provider options
  - a stored hosted selection mapping to the default

## C — CSV import (worker-opus; merges after S)

Files:
- new `Seedkeep/Features/Workbench/SeedCSVImport*.swift`
- `SeedCSV.swift`, for reversible export changes only
- the Seeds toolbars: `SeedsToolbar` and `LibraryView`
- `WorkbenchModel` (`SeedsRequest` gains import) and its request handling
- `CommandPaletteView`, and `WorkbenchCommands` (one "Import CSV…" item
  next to Export)

Rebase onto S before merging.
- **Export becomes reversible** (`SeedCSV`), and the file format stays
  readable by spreadsheets:
  - **Formula guard:** text starting with `=`, `+`, `-`, `@`, a tab or a CR
    is prefixed `'` as today. Text that already starts with `'` is also
    prefixed `'`. Import removes the guard once per text cell (one leading
    `'` followed by one of those characters or by `'`). For tags, that
    happens before splitting and unescaping.
  - **Tags:** names are joined with `; `. A `;` or `\` inside a name is
    escaped with `\`, and import unescapes it.
  - **Legacy files are best-effort.** Files exported before this change
    import, but an apostrophe before a guarded character or another
    apostrophe, and backslashes or semicolons in tag names, can be
    ambiguous in them.
  - The existing export tests are updated; new tests pin the escaping.
- **Entry:**
  - "Import CSV…" goes in the Seeds toolbar menu on every platform, in the
    command palette, and in the menu bar next to Export (⌘⇧I if free),
    through a new `SeedsRequest`.
  - `fileImporter` accepts comma-separated text and plain text.
  - **File access:** balanced security-scoped access (start and stop on
    every path), and a bounded read that refuses files over 5 MB before
    reading them whole.
  - UTF-8 is required, with or without a byte order mark; anything else
    is refused with a message.
- **Parsing** (`SeedCSVImport.parse`, pure, off the main actor):
  - RFC 4180: CRLF or LF, quoted fields with doubled quotes, and embedded
    newlines. Errors report physical line numbers.
  - **Fatal, nothing imported:** malformed CSV (an unterminated quote), no
    header, duplicate headers, `name` missing from the header, or more
    than 5,000 data rows.
  - **Header matching:** case-insensitive after trimming. Unknown columns
    are ignored, and so is `window`.
  - **A ragged row** (a cell count different from the header's) is a row
    error.
- **Values** (a bad cell makes that row an error, with its line and
  column; other rows go on):
  - `name`: required, non-blank.
  - `year`: blank, or an integer from 1900 to 2100.
  - `packets`: blank, or an integer ≥ 0.
  - `status`: blank, or a `SeedState` raw value, case-insensitive.
  - `stored_in`: a location name.
  - `tags`: escaped names separated by `;`, trimmed, with blanks and
    case-insensitive duplicates dropped.
  - `type`, `variety`, `company`, `notes`: text.
- **Identity and matching:**
  - **Matching is on only when** the header has all four identity columns:
    name, variety, company and year.
  - **When one is missing,** every valid row creates a new seed, and the
    preview says so prominently.
  - **The key:** the four values, trimmed and normalized with
    `.folding(options: [.caseInsensitive], locale: Locale(identifier:
    "en_US_POSIX"))`. Seed keys, location and tag lookup, and every
    de-duplication use this same normalization. Blank equals only blank.
    Year is compared as a number.
  - **It's compared with the live seeds as export shows them**
    (`SeedTableRow`): `name` is `displayName`, which is the custom name or
    "Untitled seed", with no catalog lookup.
  - Matching is indexed (a dictionary by key), not a scan per row.
  - **Two or more existing seeds share a key:** the row is skipped as
    ambiguous.
  - **A key repeats within the file:** the first *valid* row wins, and
    later ones are skipped as duplicates.
  - The preview explains that changing an identity value in the file
    creates a new seed.
- **Plan** (`SeedCSVImport.plan`, pure, over value snapshots, off the main
  actor):
  - Each row becomes create, update (the fields that differ), unchanged,
    or skipped with a reason.
  - **Updates follow round-trip rules for columns present in the file:**
    - **Clears:** a blank `type`, `notes` or `stored_in`. A blank `tags`
      clears only the tags that have names. Unresolved tag IDs (tags that
      no longer exist) are always kept.
    - **Leaves alone:** a blank `packets` or `status`. A `stored_in` that's
      blank because the seed's location no longer resolves.
    - A column absent from the header leaves its field alone.
    - **`tags`:** replaces the named tags, with unresolved IDs kept.
    - Fields that compare equal produce no change. Values the export
      doesn't carry (`catalogID`, growing info, the custom-name override,
      source, ids) are never touched.
  - **Creates use defaults:** status `active`, packets 1 when blank, and
    source as Add Seed sets it for manual entries. A non-blank `type` is
    applied with `setLocalCustomType` after the create.
  - **Locations and tags:**
    - They resolve by trimmed, case-folded name among the household's live
      ones.
    - Two existing ones sharing a name: the row is skipped as ambiguous.
    - New ones are created once each, with the file's first spelling, and
      only for rows that will run.
- **Preview sheet:**
  - The counts: new, updated, unchanged, skipped, and errors (the first
    errors with line and column).
  - The locations and tags it will create.
  - The no-matching notice, when matching is off.
  - Import and Cancel. Nothing is written before Import, and Import can't
    be pressed twice.
- **Write:**
  - **Before writing, rebuild the plan** from fresh snapshots and compare
    it with the preview's. If the household, a target seed, or a
    location or tag it depends on has changed, show the new preview and
    ask again.
  - **Order:** create locations and tags, then create and update seeds
    (`enqueueCreateSeed`, `enqueueUpdateSeed`, then `setLocalCustomType`
    where `type` changed).
  - **Batches:** sequential and on the main actor, in batches that yield
    between them, with progress ("Importing 1,200 of 5,000").
  - **After every yield:** re-check the household, the remaining identity
    matches, the target snapshots, and the location and tag dependencies,
    allowing for this run's own completed writes. If anything affected has
    changed, stop and require a fresh preview before continuing.
  - **Track every save as it happens,** keeping the row-to-seed ids. If a
    seed saves but its `setLocalCustomType` fails, report that seed as saved
    with its type not applied. A retry reuses that seed's id.
  - **On a failure:** stop and report what was saved. Locations and tags,
    seeds created and seeds updated are counted separately. Name the row
    that failed. No rollback; each write is its own record.
  - Nudge sync once at the end, even after a partial run.
  - The result reads "Saved on this device: 12 new, 30 updated". It means
    saved locally, not confirmed uploaded.
- **Round-trip guarantees (tests):**
  - Export, then import into the same store: everything is unchanged and
    nothing is written.
  - Export, edit one non-identity cell, then import: only that field
    changes, for an unambiguous match. Editing an identity cell follows
    the create and ambiguity rules above.
  - Seeds with a catalog link, unresolved tags or a deleted location keep
    their hidden values.
- **Tests:**
  - parser: quotes, newlines, a byte order mark, CR, ragged rows, duplicate
    headers, limits, non-UTF-8, the formula guard (old and new), tag
    escaping
  - every value rule
  - matching on and off, ambiguity, duplicates within the file
  - plan diffs and the round-trip rules
  - integration:
    - creates and updates that send only changed fields
    - `type` written after a create
    - a location or tag created once
    - a household change refusing, and a changed target forcing a new
      preview
    - a partial failure reported
    - the round-trip no-op
  - a 5,000-row plan within a time budget (rough, not flaky: a generous
    bound)

## Order and ownership

1. T, J and S run in parallel in separate worktrees; C starts in parallel.
2. Merges go one at a time: T, J, S, then C. S owns the shared route
   changes, and C rebases onto the merged S before its final review, even
   if its patch applies cleanly.
3. Each slice gets the gate, an Opus review and a Sol review, with
   findings resolved before its commit.

## Verification

- **Gate:** passes after each merge.
- **Screenshots** (iPhone; the four configurations): `R4ScreenshotTests`,
  with the R3 driver, covers:
  - Today with This week, frost and "+N more"; the DEBUG fixture gets
    enough due events, with stable ids
  - Journal search with a filter chip
  - the CSV preview, from a DEBUG-only launch argument that loads a
    bundled test file (never the Files picker)
- **Importer access and errors:** covered by unit tests on the read path
  with temporary files. The real Files picker is an owner check.
- **Audit:** rerun and compared with R3's 283 findings (about 275 expected
  after R3's allowlist update).
- **Owner checks:**
  - **Mac Settings window:** ⌘, from the app menu; no Settings in the
    sidebar; it opens with no main window and while starting up.
  - **CSV:** a real export, edited and imported on the Mac.
  - **Journal search** on iPad.
