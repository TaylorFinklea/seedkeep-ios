# Accessibility manual checklist (R2d-3)

This list covers what the automated audit (`scripts/a11y-audit.sh`) can't
prove. Run it on real hardware where noted. Tick each box. For a failure,
write down what happened and where.

Builds: a Debug build from `redesign/r2-design-system` or later. To use the
sample garden, launch with `-SeedkeepFixture`; your own garden works too.

## iPhone with VoiceOver (Settings → Accessibility → VoiceOver)

### Read order and descriptions
- [ ] **Today:** the title, the date, the daylight summary (sunrise, sunset,
  day length, how much has passed), the "Due" header, and each due row as
  one item (name, kind, day label). Then the "Journal" header and the
  note.
- [ ] **Seeds:** the title and summary, then the state filter, which reads
  its title, count and selection. Each seed row is one item: name, type,
  variety, company, year, and the verdict when there is one. Rows are
  buttons.
- [ ] **Seeds, grouped by type:** each type is read as a header before its
  rows.
- [ ] **Settings:** section headers are read as headers. The Appearance
  picker reads its value. What's New says "new" when the dot shows.
- [ ] **Planting panel (seed detail):** the chart reads one summary, for
  example "Best from May 4 to Jun 1; today: plant soon; your date: May 12".

### Bed grid (Garden → a bed with a size; R3 replaced the canvas)
- [ ] Each square is one button: "Row R, square S", then the planting, its
  task and date (or "done"), and "frost risk" when flagged. An empty
  square says "empty".
- [ ] While painting, an empty square's hint is "Plans <seed> here"; while
  moving, "Moves <seed> here".
- [ ] On a square with a selected planting, swiping up or down offers Move
  left, Move right, Move up and Move down. A move speaks the result, and
  focus goes to the new square.
- [ ] Moving into an occupied square or off the grid is refused with a
  spoken message, and nothing is saved.
- [ ] Square details (a sheet): the fields read their values; after it
  closes, focus returns to the square.
- [ ] Today: the frost banner reads its count and "Open Garden"; a flagged
  due row says "frost risk".
- [ ] Windows: each seed is one item with its group, dates, timing and next
  planting, and offers a "Plan" action.

### Large text (Settings → Accessibility → Display & Text Size → Larger Text, largest)
- [ ] Seed detail and Add Seed: State, Location and Source open a list
  instead of a menu. Choosing one goes back, and the choice shows.
- [ ] In seed detail, a choice is saved once. In Add Seed, nothing is saved
  until Save.
- [ ] No clipped or overlapping text on Today, Seeds, Journal, Settings, bed
  detail and the planting panel.

## iPad (regular width)
- [ ] **Portrait, Seeds:** the Name column is visible when Seeds opens. The
  inspector starts closed and opens from the toolbar.
- [ ] Rotate to landscape and back: the inspector keeps the state you left
  it in.
- [ ] "Reveal" of a seed (for example from the command palette) opens the
  inspector.
- [ ] VoiceOver: the sidebar, table and inspector can each be reached.
- [ ] **Garden:** the bed switcher, brush list, grid, events table and
  inspector (square details) lay out at default and the largest text size.
- [ ] **Windows (sidebar):** the timeline is at least 720 points wide and
  scrolls sideways; month labels line up with the bars; today and frost
  labels don't overlap. At accessibility sizes it shows the list.

## Mac
- [ ] Cmd+1 to Cmd+5 switch Today, Seeds, Garden, Journal and Windows.
  Cmd+, opens Settings.
- [ ] Garden grid: arrow keys move between squares; Space or Return paints
  or opens a square once (not twice); Escape closes details, then move
  mode, then the brush, then the selection.
- [ ] Tab moves through the Seeds table, the toolbar and the inspector in a
  sensible order.
- [ ] The command palette opens and runs a "Go to" item.
- [ ] Appearance set to Light, Dark and System follows the choice in every
  window. A new window gets the same appearance.
- [ ] The inspector is kept as you left it when you switch routes.

## Appearance override
- [ ] On iPhone with the device in dark mode, set Settings → Appearance →
  Light. The app turns light at once and stays light after relaunching.
- [ ] Share garden via iCloud with the override set opposite to the device:
  the sharing sheet follows the app's appearance (iOS). On Mac, note what
  happens; this is a known exception.

## Screens the audit excludes
- [ ] Picker lists at the largest size (see above).
- [ ] Sign in to iCloud / couldn't verify / garden chooser screens: read
  order, buttons labelled.
- [ ] A photo upload failure: the retry icon is visible in light and dark,
  and VoiceOver reads the error.
- [ ] Camera scan (device only): the controls are labelled; Restart and
  Read back can be reached.

## Result
- Date, device and OS:
- Build or commit:
- Failures (screen, step, what happened):
