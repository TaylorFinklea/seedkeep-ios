# R3 — Garden grid and planting windows (contract)

**Plan:** umbrella `.docs/ai/phases/2026-10-15-native-workbench-redesign-plan.md`
(R3).
**Owner decisions:** umbrella `decisions.md` [2026-10-21].
**Design reference:** `~/git/seedkeep-web-design`, the Garden and Windows
screens.

GPT-6.1 Sol critiqued the first draft and asked for a revision. It approved
the revision with changes on 2026-10-21; this version includes them.

## Owner decisions (fixed)

1. **Beds are square-foot grids you paint.** Pick a seed as a brush, tap
   empty squares to plan it, and tap a planted square to edit or delete it.
2. **Planting windows:**
   - a season timeline on iPad and Mac
   - the same groups as a list on iPhone
   - a Plan action that starts painting with that seed
3. **Frost warnings in the app, spring and fall,** for frost-tender seeds.
4. **Navigation:** Windows is a sidebar route on iPad and Mac. On iPhone it's
   one tap from Garden. Five tabs stay.

## Invariants

- **No data-model or CloudKit schema change; no migration.** Coordinates are
  never rewritten for display, ordinary edits, or a bed resize. Only an
  explicit move or placement writes them.
- **Writes go through the existing `SyncEngine` enqueue methods.** An edit
  sends only the fields that changed, and a move sends both coordinates.
  Marking a planting not done sends `completed_at: .some(nil)`; plain nil
  means unchanged.
- **Sync semantics are unchanged:** whole-record last-write-wins, with sticky
  deletes (`SeedkeepMerger`).
  - "Empty square" is a local UI rule and doesn't make a square exclusive
    across devices. Two devices can each plant the same square; after
    sync it holds both, shown with a count.
  - Before any write, the action re-checks that the household scope, the
    bed, the event and the square's local state are still current.
- **The R2 rules carry over:**
  - tokens
  - text that scales
  - tested contrast
  - labels
  - targets
  - dark mode
  - sample-garden mode
- **Pure logic is tested**, along with integration tests over the in-memory
  store and `SyncEngine`.
- **Preserved:**
  - planting notes
  - seedless Note events
  - the bed journal
  - bed and event deletion (confirmed)
  - planting reminders
  - the household scope
  - the pet-gated code
- **Spacing is information only**, from the seed's own
  `plant_spacing_inches`. Painting doesn't model plant density.

## G0 — Pure model, session and routing interfaces (worker; lands first)

**`GardenGrid`** (pure):
- **Grid size:**
  - A size is valid if it's finite and at least 1.
  - columns = `floor(widthFeet)`, rows = `floor(lengthFeet)`
  - A bed draws its grid only if both sizes are valid and at most 50 (the
    render limit).
  - Otherwise the bed has no grid. Its events stay listed and editable,
    with "Set a size to plan on a grid" and an Edit bed action.
- **Square ↔ position** (native axes: x runs along the width, y up from
  the bottom):
  - `square(x, y)`, for finite coordinates:
    - inside the grid when `0 ≤ x ≤ cols` and `0 ≤ y ≤ rows`
    - `col = min(floor(x), cols-1)`, `rowFromTop = rows-1-min(floor(y), rows-1)`,
      so a point exactly on the far edge of the last whole square belongs
      to that square
    - Points in a fractional strip (cols < x ≤ width), negative, out of the
      bed, or non-finite are **outside the grid**.
  - `centre(col, rowFromTop) = (col + 0.5, rows-1-rowFromTop + 0.5)`.
  - Labels are 1-based: "Row R, square S".
- **Square contents:**
  - The bed's live events placed in that square, ordered by `plannedFor`
    and then id.
  - **The square has events** if it holds any placed live events,
    completed or not. In idle mode, tapping such a square opens its list.
  - **Blocks painting** means the square has an incomplete event. A square
    holding only completed events can be painted again; its history stays.
  - **The shown event** is the first incomplete one, otherwise the latest
    completed one.
  - **The square's frost flag** is true if any of its incomplete events is
    flagged.
- **Unplaced and outside-the-grid events** are listed separately, each with a
  "Place" action.
- **Plan date:** the outdoor window's start, if it's after today
  (device-local calendar day) and the verdict isn't `too_late`. Otherwise
  today.
- **Brush seeds:** the active seeds in the active garden, ordered by verdict
  (plant_now, plant_soon, late, too_early, too_late, none), then name, then
  id.

**`FrostCheck`** (pure; US zone estimates only, matching the bundled
climate table):
- **Inputs:**
  - `plannedFor` (yyyy-MM-dd)
  - kind, completed
  - the seed's `frost_tolerance`
  - the home climate's `avgLastFrost`/`avgFirstFrost` (MM-DD)
- **Parsing is strict.** A date must round-trip through a Gregorian, UTC
  calendar; anything that doesn't gives "unavailable". 02-29 in a non-leap
  year becomes 02-28.
- **Flags** apply only to incomplete sowing or transplant events of a seed
  whose tolerance is `tender` (case-insensitive).
  - **Spring:** the planned date is before last frost in the planned
    year.
  - **Fall:** the planned date is on or after first frost in the planned
    year.
- **Unavailable** (no flag):
  - the climate is missing
  - the first frost isn't after the last frost in the year
  - the bundled table puts that side at the calendar edge: a last frost of
    01-01 means no spring flag, and a first frost of 12-31 means no fall
    flag
  
  The table uses the year's edges for zones without that frost season (10
  to 13). Reading them as "no frost season" avoids made-up December 31
  warnings.
- **Copy** says this is estimated risk if planted outdoors:
  - "Frost risk if planted outdoors: before the average last frost (May 4)."
  - "Frost risk if planted outdoors: on or after the average first frost
    (Oct 1)."
  - The copy notes that the dates are zone averages, not a forecast.
- **Household note:** home climate is per device, so household members can
  see different flags. This is documented, not "fixed".

**`WindowsGrouping`** (pure):
- Seeds with a recommendation, excluding archived ones.
- Groups: Plant now, Plant soon, Closing soon (`late`), and Later
  (`too_early`, `too_late`, `unknown`).
- Within a group, order by window start, then name, then id. Seeds with no
  window come last.
- **"Next planned"** is the first incomplete event for the seed, giving its
  bed and date.

**`SeasonTimeline`** (pure):
- **The date domain** spans Jan 1 to Dec 31 of the current year, extended
  to cover every displayed outdoor and indoor endpoint and every marker,
  then padded to whole months.
- Endpoints are inclusive. A single-day range gets a minimum drawn width.
  Missing or inverted ranges get no bar.
- Month labels are generated from the same domain.
- **Markers:** today, last frost and first frost.

**`GardenSession`** (`@Observable`, one per window, owned at the window root
above both shells and injected into the environment):
- **State:**
  - `bedID`
  - `brushSeedID`
  - `selectedEventID`
  - `mode` (`.idle`, `.painting`, `.moving(eventID)`)
  - `detailsPresented`
  - `pendingPlan`
- **Rules:**
  - Moving takes precedence over painting: starting a move clears the
    brush.
  - **`plan(seedID:)`:**
    - clears the selection and any move
    - sets the brush
    - picks a bed: the last-viewed live bed with a grid, otherwise the
      first by sort order and then name
    - **zero beds with a grid:** the result is `.needsBed`, and the UI shows
      "Add a bed with a size to plan" with New bed
  - **Reconcile:** on a household change or sign-out, it resets; a selected
    event or bed that's gone is cleared; a brush seed that's no longer
    active or in this garden is cleared.
  - A pending Plan survives a size-class shell switch.
- **Routing:**
  - `WorkbenchRoute.windows` (after Garden; "calendar" symbol; ⌘5; a
    palette entry).
  - On compact layouts, Plan goes through the existing `requestedTab`
    (`.garden`) and the session's `pendingPlan`; the Garden tab opens that
    bed's screen.

**Tests:**
- every edge above: fractional, zero, huge, non-finite, the edge point,
  outside the bed
- strict dates, leap years, zone edges, inconsistent ordering
- grouping and order
- timeline domains
- the session's reducers

## G1 — Grid and square details (worker; after G0)

- **`BedGridView`:**
  - **Cell content:**
    - **background:** the kind colour of the shown event; `panel2` when
      empty; `kindNote` when all done
    - **text:** an abbreviation, a "+N" count badge, and a date or "done"
      line
  - **Rings:** accent when selected; warn ring plus a frost glyph when
    flagged (never colour alone).
  - **Size:** cells are at least 44pt, scale with Dynamic Type and have no
    upper cap at accessibility sizes. There the date line is hidden, and the
    events list carries the full text.
  - The grid scrolls in both directions, and keyboard focus scrolls the
    focused cell into view.
- **Accessibility:** each cell is one button.
  - **Label:** "Row R, square S", then the count when more than one, the
    shown event's seed, kind and date or "done", and "frost risk" when
    flagged. An empty square is "Row R, square S, empty".
  - **Hint:**
    - painting: "Plans <seed> here"
    - moving: "Moves <seed> here"
  - **Selected trait.**
  - **Custom actions on a selected event:** Move left, Move right, Move
    up, Move down. Each moves one square and refuses an occupied or
    outside square with an announcement.
- **Input:**
  - Tap, click and keyboard (focus plus Space or Return) do the same thing.
  - Arrow keys move focus between cells on iPad and Mac.
  - Drag isn't required.
- **`GardenInteraction`** (a pure reducer over `GardenSession` and square
  contents):
  - **painting:**
    - a square that doesn't block painting creates a sowing event at its
      centre, dated by the plan date. The brush stays and details stay
      closed.
    - a blocking square selects its shown event, stays in painting mode,
      and keeps details closed.
  - **idle:**
    - a square with events selects its shown event and sets
      `detailsPresented`
    - an empty square clears the selection and closes details
  - **moving:**
    - a square that doesn't block painting moves the event there (both
      coordinates) and returns to idle
    - a blocking square refuses with a message
  - **Opening details:**
    - tapping an event row selects it and sets `detailsPresented`
    - while painting, a "Details" button in the Stop bar (every layout)
      opens the selected event
    - on iPad and Mac the inspector shows the selected event whenever it's
      open, and the inspector toggle stays as it is
    - closing details clears `detailsPresented` and keeps the selection
  - **Escape and Cancel close things in order:** the details editor, then
    move mode, then the brush, then the selection.
  - A visible Stop or Cancel button shows while painting or moving, on
    every layout.
- **`SquareDetails`:**
  - **Presentation:** the inspector on iPad and Mac, a sheet on iPhone.
  - **When a square holds several events,** each is listed and can be
    selected.
  - **For the selected event:**
    - the seed (tap to open it; seedless Notes say "Note")
    - "Row R, square S"
    - spacing, when the seed has one
    - a Task picker (Sow, Transplant, Harvest, Note)
    - a date
    - a Done toggle
    - notes (multi-line; saved on commit)
    - the frost sentence
  - **Move:** dismisses the sheet and enters move mode, with a banner: "Tap
    an empty square to move <seed>", plus Cancel.
  - **"Delete planting…":** a confirmation says "Deletes this planting, with
    its notes and done state, for everyone in this garden. Journal entries
    and other plantings in the square stay." It deletes through
    `enqueueDeletePlantingEvent`, which tombstones that one event and
    cancels its reminder.
  - **Focus:** returns to the square after the sheet closes or a delete.
  - **Remote changes:** if the selected event changes or disappears, the
    details update or close.
- **Events list for the bed:**
  - **Layout:** a `Table` on regular width, a `List` on compact.
  - **Columns:**
    - Done toggle
    - Date
    - Task
    - Seed
    - Square ("R2 · S3", "Unplaced" or "Outside the grid")
    - Status: done; "N days overdue" with a warn icon; "Today"; or "In N
      days"
    - Notes: a short preview in muted text
  - **Frost rows:** a warn glyph, and the sentence in VoiceOver and as a
    second line.
  - **Order:** by date, then id.
  - **Actions:** selecting a row selects its event. Unplaced and outside
    rows have "Place".
- **The R2c canvas guarantees move to grid tests,** each with its equivalent:
  - bounds
  - no-op moves write nothing
  - orientation (y up)
  - an untouched axis is preserved: a one-axis move sends both
    coordinates, with the untouched one's existing value unchanged
  - accessibility labels and actions

## G2 — Garden screens (worker; after G1)

*From the G0 review:* the Garden screen in **both** shells calls
`takePendingPlan()` (otherwise a leftover Plan fires on a later
size-class switch). A `.needsBed` brush with no grid bed shows the
add-a-bed prompt, never a Stop bar over the bed list or a gridless bed.
Gridless beds list their events from `offGrid`'s `noGrid` bucket, with no
"Place" action.

- **iPad and Mac (`.garden`):**
  - **Toolbar:**
    - a bed switcher (segmented up to 5 beds, otherwise a menu)
    - New bed, Edit bed
    - Stop or Cancel while painting or moving
    - a legend popover
  - **Content:** the brush list ("Paint with a seed", with verdict dots and
    labels), the grid, and the unplaced/outside list and events table below.
  - **Inspector:** square details.
- **iPhone:**
  - The bed list stays: name, size, next event, and a frost count.
  - **The bed screen:**
    - the brush strip (horizontal, with Stop)
    - a move banner while moving
    - the grid
    - the events list
    - square details as a sheet
  - A toolbar button opens Windows.
- **New bed and Edit bed** (sheets):
  - **Fields:** name; width and length as decimal fields, defaulting to 4
    × 8 for a new bed; description.
  - **Validation:** a size must be finite and from 1 to 50. A blank size
    is allowed and means no grid.
  - **Edits send only the changed fields.** An existing decimal size, a
    missing size, or a size over 50 is kept unless the user edits that
    field.
  - **Resizing never moves events.** Events that fall outside a smaller
    grid show in the Outside list.
- **Legend:** Sow, Transplant, Harvest, Done, the frost glyph as "Frost risk
  (estimate)", and "1 square = 1 sq ft".
- **Retired:**
  - `BedLayoutCanvas` with its drag, spacing rings and half-foot placement;
    the grid replaces placement
  - the slider placement in `AddPlantingEventView`, now "Place in bed" with
    a small grid picker
  - `BedPlacementMath`, `BedLabelLayout` and their tests, once G1's
    equivalent tests exist

## G3 — Planting windows (worker; after G0, in parallel with G1)

- **`WindowsView`** replaces `WhatToPlantView`.
- **Regular-width layout:**
  - **The timeline** has a month header and labelled today, last-frost and
    first-frost lines. Group headers carry a count.
  - **Each seed's row** shows:
    - the name
    - the outdoor bar (verdict colour)
    - the indoor bar (outlined)
    - the timing
    - the next planned bed and date
    - Plan
  - **Size and scrolling:** the chart is at least 720pt wide and scrolls
    horizontally. Rows grow with Dynamic Type.
  - At accessibility sizes, iPad uses the list layout.
- **Compact layout:** a grouped list with the same fields. It's also used
  on compact iPad, since that runs the compact shell.
- **Accessibility:**
  - each seed is one element: "<seed>, <group>, outdoors <start> to <end>,
    indoors <start> to <end>, <timing>, next planned <bed> <date>"
  - Plan is both a button and a custom action
  - bars and marker lines are hidden
- **Seeds without a window** show "No window" and their reason in muted
  text.
- **Tapping a seed** opens it.
- **Plan:**
  - for an active seed, `GardenSession.plan` (G0)
  - for any other seed, "Move <seed> to Active to plan it."
  - `.needsBed` shows the add-a-bed prompt
- **The toolbar** keeps "Snap a corner".
- **No home location:** the existing "set a home location" state.

## G4 — Frost on Today and Add Planting (worker; after G0)

Bounded to frost. The rest of Today's redesign is R4.
- **Today:**
  - Due rows that are flagged show the frost glyph, and their VoiceOver
    label adds "frost risk".
  - **A warning `WBBanner`** shows when, among live incomplete events from
    the existing live-candidates query, any event planned from today
    through today+13 is flagged. It counts events, separately from the
    six-row due list: "<n> planting(s) may meet frost (zone estimate). Open
    Garden."
- **Add Planting:** shows the frost sentence for the chosen seed and date.

## Order and ownership

1. **G0** first. It sets the session and routing interfaces.
2. **G1 and G3** in parallel.
3. **G2**, after G1.
4. **G4.**

Workers own their builds, tests, screenshots and simulator runs. The lead
integrates, runs the gate and the audit, and gets an Opus and a Sol review,
with findings resolved, before each commit.

## Verification

- **Gate:** `scripts/test-gate.sh` passes.
- **Integration tests** (in-memory store and `SyncEngine`):
  - paint, edit each field, move, delete
  - complete and uncomplete (`.some(nil)`)
  - several events in a square, completed history
  - invalid and decimal sizes, resizing
  - Plan handoffs: both shells, zero beds, beds without a grid
  - a household change
  - a remote deletion of the selected event (simulated by a local tombstone
    and reconcile)
  - the merge policy's effect on concurrent edits (the existing merger
    tests extended)
- **Fixture (DEBUG):**
  - a tender seed with stable ids
  - in sample-garden mode, the home climate keeps the sample ZIP's real
    frost dates, so planting windows stay realistic. A pure
    `FixtureFrostEvent.flaggedDay(today:lastFrost:firstFrost:)` dates the
    tender sowing: today+3 when that is frost-flagged (spring and fall,
    inside Today's 14-day banner), otherwise that year's average first frost
    (mid-season; flagged on the grid, but no Today banner). Tests sweep
    every day of a common and a leap year.
    - *Amended after the G0 review:* the original design overrode the frost
      dates (last 03-01, first today−5), which the planting engine also
      reads, so it emptied the sample garden's windows for most of the
      year.
  - one unplaced event
  - one event outside the grid
- **Audit:** the manifest, driver and tests are updated:
  - the bed screen with its grid and square details
  - Windows replacing What to Plant
  - the new toolbar identifiers
  
  New findings are compared against the triaged R2d baseline (289), and
  any real ones are fixed.
- **Screenshots** (iPhone; iPad if approved):
  - painting, the details sheet, move mode
  - the events and unplaced lists
  - the Windows timeline and list
  - the Today banner
  - light and dark; default and the largest size
- **Owner checks:**
  - iPad inspector and timeline
  - Mac keyboard: arrow keys, Space or Return, Escape
  - Mac pointer
