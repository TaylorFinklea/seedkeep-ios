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

### Bed canvas (Garden → a bed with a layout)
- [ ] Each planting is one item: "<name>, <x> feet from the left, <y> feet
  from the bottom".
- [ ] Swiping up or down (custom actions) offers Move left, Move right, Move
  up and Move down.
- [ ] A move speaks the new position, and focus stays on the planting.
- [ ] At an edge, moving further does nothing and nothing is saved.
- [ ] The move is still there after leaving and reopening the bed.

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

## Mac
- [ ] Cmd+1 to Cmd+4 switch Today, Seeds, Garden and Journal. Cmd+, opens
  Settings.
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
