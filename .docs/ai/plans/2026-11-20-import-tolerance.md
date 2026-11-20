# Import Tolerance Implementation Plan (Track B, build 56)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. If those skills are not installed, do the tasks in order as written. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A gardener's own Excel or Google Sheets file, saved as CSV, imports without renaming its columns, and the preview says what was not imported.

**Architecture:** The importer stays the pure pipeline it is (`decode → records → parse → plan → writer`). Only `parse` changes: header resolution moves into a small resolver with an alias table, and three cell readers accept a few explicit extra forms. The resolver's result (`ColumnReport`) rides on `ParsedFile` and `Plan` so the existing preview can show it. No model, CloudKit or writer change.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), XcodeGen. The Xcode project is generated and gitignored: run `xcodegen generate` after adding any file, before building or testing.

**Spec:** `~/git/seedkeep/.docs/ai/phases/2026-11-20-v1-plan.md` (sections 1, 2, 4 and 5). Owner decision 2026-11-20: this slice is in 1.0.

## Global Constraints

- Work in the worktree `~/git/seedkeep-ios-wt/import-tolerance` on branch `import-tolerance` (task B0). Never switch branches in `~/git/seedkeep-ios`; Track A owns that checkout.
- One simulator, one job at a time. Do not run a test, gate or audit here while Track A is running one: both use the simulator `DD9BE2B2-F191-459F-8B5B-1AD8B252B171`.
- After Track A's task A9, `main` is the only release branch. Build 56 is cut from `main` (task B6). Never run `release.sh` from `redesign/r2-design-system` or from this branch.
- No third-party packages. No CloudKit schema change. No new screen or sheet.
- Seedkeep's own export (`SeedCSV.columns`) must import exactly as before. Every existing test in `SeedCSVImportParseTests`, `SeedCSVImportPlanTests`, `SeedCSVImportWriterTests` and `SeedsCSVTests` keeps passing, except the two assertions tasks B1 and B2b name.
- Minimum OS: iOS/iPadOS 27.0, macOS 27.0. Both destinations must build.
- Seedkeep's column meanings: `name` is the cultivar ("Brandywine"), `type` is the crop ("Tomato"), `variety` is an optional sub-variety.
- Never guess a value. A cell that fits none of the explicit forms below is a row error, as today.
- Copy is plain and literal. No exclamation marks.
- Focused test command:
  `xcodebuild test -project Seedkeep.xcodeproj -scheme Seedkeep -destination 'platform=iOS Simulator,id=DD9BE2B2-F191-459F-8B5B-1AD8B252B171' -only-testing:SeedkeepTests/<SuiteStructName>`
  After a run, check the log shows the suite's tests ran; a run that executed zero tests is a failure.
- The five import suites: `SeedCSVImportParseTests`, `SeedCSVImportPlanTests`, `SeedCSVImportWriterTests`, `SeedsCSVTests`, plus the new suites as they are added.
- Before each commit that touches Swift: a Codex `gpt-6.1-terra` diff review and an independent Sonnet review (umbrella plan, section 5).

## Review Focus

1. **A sheet with a title row above the header, or semicolons for commas.** Expected: the "no column Seedkeep can use" error, whose text says what to check. Never a crash or a silent wrong import. Test in B1.
2. **Two headers that mean the same field** ("Qty" and "Packets"). Expected: the exact name wins, the other is listed as not imported, nothing is fatal. Test in B1.
3. **Seedkeep's own export re-imported.** Expected: the same result as today, with matching on and no Columns section in the preview. Tests in B1 and B3.
4. **A cell that is not clearly one number** ("50 seeds", "2 pkts of 50", "2023/2024"). Expected: a row error naming the cell, never a guess. Tests in B2a.
5. **Aliases switch matching on.** A sheet headed "Seed, Variety, Source, Year" now has all four identity columns, so its rows update existing seeds. Expected: the preview's Updated count shows it before anything is saved. Test in B3.

---

### Task B0: Worktree

- [ ] **Step 1:** If the worktree does not exist: `git -C ~/git/seedkeep-ios worktree add ~/git/seedkeep-ios-wt/import-tolerance -b import-tolerance redesign/r2-design-system`. If it exists (a resumed session), `cd` into it and confirm `git branch --show-current` prints `import-tolerance`.
- [ ] **Step 2:** In the worktree: `xcodegen generate`. Run the focused test command for `SeedCSVImportParseTests`. Expected: pass. This proves the worktree builds before any change.
- [ ] **Step 3:** If the owner has sent the header row of their real sheet (umbrella plan, section 6), keep it for task B1 step 6. If not, do not wait.

### Task B1: Header resolution with aliases

**Files:**
- Create: `Seedkeep/Features/Workbench/SeedCSVImportHeader.swift`
- Modify: `Seedkeep/Features/Workbench/SeedCSVImport.swift` (the header loop in `parse(_:)`, lines 298–316; `ParsedFile`, lines 282–292 and its one construction site at line 386; `FatalError.noNameColumn`, line 37)
- Modify: `SeedkeepTests/SeedCSVImportParseTests.swift` (two assertions, named in step 4)
- Test: `SeedkeepTests/SeedCSVImportHeaderTests.swift` (new)

**Interfaces** (file `SeedCSVImportHeader.swift`):
- At file scope (Swift does not allow an extension nested in an extension):
  `extension SeedCSVImport.Column { var canonicalKey: String; var displayName: String }`
  - `canonicalKey` is `rawValue` with `_` replaced by a space (`stored_in` → `stored in`).
  - `displayName` is `Name, Variety, Type, Company, Year, Packets, Status, Stored in, Tags, Notes`.
- In `extension SeedCSVImport`:
  - `static func headerKey(_ header: String) -> String` — `normalized(header)`, then every character that is not a letter or digit becomes a space, runs of spaces collapse to one, ends trimmed.
  - `static let headerAliases: [String: Column]` — the table below, keyed by `headerKey` form.
  - `struct MappedColumn: Equatable, Sendable { let header: String; let column: Column; let index: Int }` — `header` is the cell as the file spells it, trimmed; `index` is the cell's position in the header record.
  - `struct ColumnReport: Equatable, Sendable { var mapped: [MappedColumn]; var ignored: [String]; static let empty = ColumnReport(mapped: [], ignored: []) }`
  - `static func resolveColumns(_ header: Record) throws(FatalError) -> ColumnReport`
- `ParsedFile` gains `let columns: ColumnReport`. `present` stays and equals `Set(columns.mapped.map(\.column))`.

**Alias table** (`headerAliases`; keys are in `headerKey` form):

| Column | Aliases |
|---|---|
| `name` | seed, seeds, seed name, plant name, cultivar, item, item name |
| `variety` | sub variety, subvariety, strain |
| `type` | crop, crop type, plant, plant type, category, kind, species, vegetable |
| `company` | brand, source, supplier, vendor, seed company, seller, purchased from, bought from, from |
| `year` | year packed, packed for, pack year, packet year, year purchased, purchase year, year bought |
| `packets` | packet, pkts, pkt, qty, quantity, number of packets, no of packets, of packets |
| `status` | state |
| `storedIn` | location, storage, storage location, stored, where, where stored, container, box |
| `tags` | tag, labels, label |
| `notes` | note, comments, comment, remarks, description |

"Season", "Amount" and "Count" are deliberately not aliases: a season column holds words like "Spring", and amount or count often means seeds, not packets.

**Resolution rules** (`resolveColumns`):

1. Walk the header cells in order. Trim each; skip blanks.
2. The same `normalized` text twice is fatal, as today: `throw .duplicateColumn(spelled, line: header.line)`. This check runs first.
3. `key = headerKey(spelled)`. Each cell gets a rank for the column it resolves to:
   - rank 0: `normalized(spelled) == column.rawValue` (Seedkeep's own spelling, such as `stored_in`);
   - rank 1: `key == column.canonicalKey` (such as `Stored In`);
   - rank 2: `headerAliases[key] == column`;
   - otherwise the cell resolves to nothing and is ignored.
4. When two cells resolve to the same column, the lower rank holds it; on a tie the earlier cell holds it. The loser is ignored.
5. A cell whose `key` is `window` is skipped silently (neither mapped nor ignored) when every other non-blank cell resolved at rank 0, which is what a Seedkeep export looks like. In any other file it is ignored like any unknown column.
6. After the walk, if nothing holds `.name`: re-label the `.variety` mapping as `.name` if there is one; else re-label the `.type` mapping as `.name`; else `throw .noNameColumn`.
7. `mapped` is sorted by `index`. `ignored` holds the trimmed spellings of every ignored cell, sorted by that cell's index, so a displaced header keeps its place in file order.

New message, replacing the old `noNameColumn` text: `"This file has no column Seedkeep can use as the seed name. Check that the first row holds the column names, that the columns are separated by commas, and that one of them is named “Name”, “Seed” or “Variety”."`

- [ ] **Step 1: Write the failing tests** in `SeedkeepTests/SeedCSVImportHeaderTests.swift`

```swift
import Foundation
import Testing
@testable import Seedkeep

@Suite("Seeds CSV import — header resolution")
struct SeedCSVImportHeaderTests {
    private static func report(_ header: String) throws -> SeedCSVImport.ColumnReport {
        try SeedCSVImport.parse(header + "\n").columns
    }
    private static func pairs(_ r: SeedCSVImport.ColumnReport) -> [String] {
        r.mapped.map { "\($0.header)=\($0.column.rawValue)" }
    }

    @Test("header keys fold case, punctuation and spacing")
    func keys() {
        #expect(SeedCSVImport.headerKey(" Stored_In ") == "stored in")
        #expect(SeedCSVImport.headerKey("# of Packets") == "of packets")
        #expect(SeedCSVImport.headerKey("Qty.") == "qty")
        #expect(SeedCSVImport.headerKey("Year  Purchased:") == "year purchased")
    }

    @Test("Seedkeep's own export header resolves as before, and window is silent")
    func ownExport() throws {
        let r = try Self.report("name,variety,type,company,year,packets,status,stored_in,tags,notes,window")
        #expect(r.mapped.map(\.column) == [.name, .variety, .type, .company, .year, .packets, .status, .storedIn, .tags, .notes])
        #expect(r.ignored.isEmpty)
        #expect(try SeedCSVImport.parse("name,variety,company,year\nA,,B,2024\n").matchingEnabled)
    }

    @Test("common spreadsheet headers resolve through aliases")
    func aliases() throws {
        let r = try Self.report("Seed Name,Crop,Source,Year Purchased,Qty,Location,Comments")
        #expect(Self.pairs(r) == ["Seed Name=name", "Crop=type", "Source=company",
                                  "Year Purchased=year", "Qty=packets", "Location=stored_in", "Comments=notes"])
        #expect(r.ignored.isEmpty)
    }

    @Test("unknown columns are listed in file order; a foreign window column is listed too")
    func ignored() throws {
        #expect(try Self.report("Seed,Price,Germ %,Window,Days to Maturity").ignored == ["Price", "Germ %", "Window", "Days to Maturity"])
        let season = try SeedCSVImport.parse("Name,Season\nTomato,Spring\n")
        #expect(season.columns.ignored == ["Season"])
        #expect(season.rows.count == 1)
        #expect(season.issues.isEmpty)
    }

    @Test("Seedkeep's spelling beats a respelling, which beats an alias; ties go to the first")
    func conflicts() throws {
        let alias = try Self.report("Name,Qty,Price,Packets")
        #expect(Self.pairs(alias) == ["Name=name", "Packets=packets"])
        #expect(alias.ignored == ["Qty", "Price"])
        let first = try Self.report("Name,Qty,Quantity")
        #expect(Self.pairs(first) == ["Name=name", "Qty=packets"])
        #expect(first.ignored == ["Quantity"])
        let own = try Self.report("name,Stored In,stored_in")
        #expect(Self.pairs(own) == ["name=name", "stored_in=stored_in"])
        #expect(own.ignored == ["Stored In"])
    }

    @Test("with no name column, variety and then type stand in for it")
    func promotion() throws {
        #expect(Self.pairs(try Self.report("Crop,Variety,Source")) == ["Crop=type", "Variety=name", "Source=company"])
        #expect(Self.pairs(try Self.report("Plant,Source,Qty")) == ["Plant=name", "Source=company", "Qty=packets"])
        let file = try SeedCSVImport.parse("Crop,Variety\nTomato,Brandywine\n")
        #expect(file.rows.first?.name == "Brandywine")
        #expect(file.rows.first?.type == "Tomato")
        #expect(file.rows.first?.variety == "")
        #expect(!file.matchingEnabled)
    }

    @Test("a file with no usable name column is refused: no name, a title row, or semicolons")
    func noName() {
        #expect(throws: SeedCSVImport.FatalError.noNameColumn) { try SeedCSVImport.parse("Source,Year\nA,2024\n") }
        #expect(throws: SeedCSVImport.FatalError.noNameColumn) { try SeedCSVImport.parse("My Seeds 2026\nName,Qty\nBasil,2\n") }
        #expect(throws: SeedCSVImport.FatalError.noNameColumn) { try SeedCSVImport.parse("Name;Qty\nBasil;2\n") }
    }

    @Test("the same header text twice is still refused")
    func duplicates() {
        #expect(throws: SeedCSVImport.FatalError.duplicateColumn("NAME", line: 1)) { try SeedCSVImport.parse("Name,NAME\nA,B\n") }
    }
}
```

`resolveColumns` throws before any data row is read, so the title-row and semicolon cases reach `noNameColumn` and not the ragged-row error.

- [ ] **Step 2:** `xcodegen generate`, then run `-only-testing:SeedkeepTests/SeedCSVImportHeaderTests`. Expected: a build failure, `headerKey` and `columns` not found.
- [ ] **Step 3:** Implement `SeedCSVImportHeader.swift`. In `parse(_:)`, replace the header loop with `let columns = try resolveColumns(header)`, build `columnIndex` and `headerNames` from `columns.mapped`, delete the `guard columnIndex[.name] != nil else { throw .noNameColumn }` line, and pass `columns` to `ParsedFile`. Change the `noNameColumn` text. `xcodegen generate`.
- [ ] **Step 4:** In `SeedCSVImportParseTests`:
  - `headerErrors`: replace `#expect(Self.fatal("variety,company\nA,B\n") == .noNameColumn)` with `#expect(Self.fatal("company,year\nA,2024\n") == .noNameColumn)`. (A variety column now stands in for the name.)
  - `headerMatching`: add `#expect(file.columns.ignored == ["Color", "window"])`. (That file has an unknown column, so it is not a Seedkeep export and `window` is listed.)
- [ ] **Step 5:** Run the new suite and the four existing import suites. Expected: all pass.
- [ ] **Step 6:** If the owner's header row has arrived: add a test `ownerSheetHeader` to this suite with the header inlined as a string (no data from the owner's sheet), asserting `pairs` and `ignored` for it. For each header that should map and does not, add its `headerKey` to the alias table only if its meaning is unambiguous; otherwise leave it ignored and tell the owner which columns will not import.
- [ ] **Step 7:** Reviews, then commit: `feat(import): resolve spreadsheet headers through aliases`.

### Task B2a: Lenient counts and years

**Files:**
- Create: `Seedkeep/Features/Workbench/SeedCSVImportValues.swift`
- Modify: `Seedkeep/Features/Workbench/SeedCSVImport.swift` (the year and packets blocks in `parse(_:)`, lines 357–370)
- Test: `SeedkeepTests/SeedCSVImportValueTests.swift` (new)

**Interfaces** (in `extension SeedCSVImport`):
- `static func lenientCount(_ raw: String) -> Int?` — after trimming, the whole cell must be: an optional `x` or `×`, optional spaces, one run of ASCII digits, optional spaces, an optional unit word from `pkt, pkts, packet, packets, pack, packs` (any case), an optional final `.`. Return the digits as an `Int`. Anything else, including a sign, a decimal point or any other word, is nil.
- `static func lenientYear(_ raw: String) -> Int?` — after trimming: every character must be an ASCII digit, a space, `/`, `-` or `.`, and the first character must be a digit. Split the cell into runs of digits. If exactly one run is four digits long (runs of other lengths are ignored) and it is within 1900...2100, return it. Anything else is nil.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Seedkeep
import SeedkeepKit

@Suite("Seeds CSV import — lenient values")
struct SeedCSVImportValueTests {
    @Test("counts", arguments: [
        ("3", 3), ("0", 0), (" 4 ", 4), ("2 pkts", 2), ("2 Packets", 2), ("1 pkt.", 1), ("x3", 3), ("× 3 packs", 3),
    ])
    func counts(raw: String, expected: Int) { #expect(SeedCSVImport.lenientCount(raw) == expected) }

    @Test("cells that are not clearly one packet count",
          arguments: ["2.5", "1/2", "-1", "- 2", "none", "1,000", "50 seeds", "2 pkts of 50", "~5", "12 (opened)", ""])
    func notCounts(raw: String) { #expect(SeedCSVImport.lenientCount(raw) == nil) }

    @Test("years", arguments: [("2024", 2024), ("2023-24", 2023), ("2023/24", 2023), ("3/15/2023", 2023), ("2023-03-15", 2023)])
    func years(raw: String, expected: Int) { #expect(SeedCSVImport.lenientYear(raw) == expected) }

    @Test("cells that are not clearly one year",
          arguments: ["2023/2024", "'23", "1899", "2101", "20x5", "20x4", "12024", "-2023", "Packed for 2025", "2024 lot 1234", ""])
    func notYears(raw: String) { #expect(SeedCSVImport.lenientYear(raw) == nil) }

    @Test("a messy sheet imports its readable rows and reports the rest")
    func messySheet() throws {
        let file = try SeedCSVImport.parse("""
        Seed Name,Crop,Qty,Year Purchased,Status,Price
        Brandywine,Tomato,2 pkts,3/15/2023,active,3.50
        Genovese,Basil,2.5,2024,wishlist,2.00
        Sungold,Tomato,1,2023/2024,active,4.00

        """)
        #expect(file.rows.map(\.name) == ["Brandywine"])
        #expect(file.rows.first?.packets == 2)
        #expect(file.rows.first?.year == 2023)
        #expect(file.errorRowCount == 2)
        #expect(file.issues.map(\.column) == ["Qty", "Year Purchased"])
        #expect(file.columns.ignored == ["Price"])
    }
}
```

- [ ] **Step 2:** `xcodegen generate`, run `-only-testing:SeedkeepTests/SeedCSVImportValueTests`. Expected: a build failure, `lenientCount` not found.
- [ ] **Step 3:** Implement both functions. In `parse(_:)`, replace `if let year = Int(raw), (1900...2100).contains(year)` with `if let year = lenientYear(raw)`, and `if let packets = Int(raw), packets >= 0` with `if let packets = lenientCount(raw)`. Keep both issue messages unchanged.
- [ ] **Step 4:** Run all import suites. Expected: all pass, including the existing `packetsRule` (`-1`, `1.5`, `many` stay errors) and `yearRule` (`1899`, `2101`, `20x4` stay errors). The DEBUG fixture row `Mystery packet,,,,20x5` must still be an error. If an existing assertion fails for a reason this plan does not name, stop and report; do not edit that test.
- [ ] **Step 5:** Reviews, then commit: `feat(import): read counts and years leniently`.

### Task B2b: Status words

This task is the second to cut if the calendar slips, after B4 (umbrella plan, section 4). It is its own commit so it can be left out.

**Files:**
- Modify: `Seedkeep/Features/Workbench/SeedCSVImportValues.swift`
- Modify: `Seedkeep/Features/Workbench/SeedCSVImport.swift` (the status block in `parse(_:)`, lines 371–377)
- Modify: `SeedkeepTests/SeedCSVImportValueTests.swift`

**Interfaces:**
- `static func lenientStatus(_ raw: String) -> SeedState?` — `SeedState(rawValue: trimmed.lowercased())`, else the table below looked up by `headerKey(raw)`, else nil.

| State | Words (in `headerKey` form) |
|---|---|
| `active` | have, in stock, stock, yes, y, owned |
| `wishlist` | wish list, wish, want, wanted, to buy, buy, need |
| `saved` | saved seed, home saved, self saved |
| `archived` | archive, used up, used, out, out of stock, empty, finished |

"gone" is deliberately absent: the existing `statusRule` test uses it as the invalid status and must keep passing unchanged.

- [ ] **Step 1: Write the failing test** (add to `SeedCSVImportValueTests`)

```swift
@Test("status words")
func statuses() {
    #expect(SeedCSVImport.lenientStatus("Active") == .active)
    #expect(SeedCSVImport.lenientStatus("Have") == .active)
    #expect(SeedCSVImport.lenientStatus("In stock") == .active)
    #expect(SeedCSVImport.lenientStatus("Wish List") == .wishlist)
    #expect(SeedCSVImport.lenientStatus("to buy") == .wishlist)
    #expect(SeedCSVImport.lenientStatus("Home-saved") == .saved)
    #expect(SeedCSVImport.lenientStatus("Used up") == .archived)
    #expect(SeedCSVImport.lenientStatus("out of stock") == .archived)
    #expect(SeedCSVImport.lenientStatus("gone") == nil)
    #expect(SeedCSVImport.lenientStatus("maybe") == nil)
}
```

- [ ] **Step 2:** Run the suite. Expected: a build failure, `lenientStatus` not found.
- [ ] **Step 3:** Implement it. In `parse(_:)`, replace `if let state = SeedState(rawValue: raw.lowercased())` with `if let state = lenientStatus(raw)`. Keep the issue message.
- [ ] **Step 4:** Run all import suites. Expected: all pass with `statusRule` unchanged.
- [ ] **Step 5:** Reviews, then commit: `feat(import): read common status words`.

### Task B3: Show the column report in the preview

**Files:**
- Modify: `Seedkeep/Features/Workbench/SeedCSVImport.swift` (`Plan`, lines 574–596; the `return Plan(` at line 766)
- Modify: `Seedkeep/Features/Workbench/SeedCSVImportView.swift` (`SeedCSVImportText`, from line 252; `SeedCSVImportPreview.body`, from line 529)
- Modify: `Seedkeep/Features/Workbench/SeedCSVImportFixture.swift` (a second DEBUG fixture)
- Test: `SeedkeepTests/SeedCSVImportPlanTests.swift` (add to the existing suite)

**Interfaces:**
- `Plan` gains `let columns: ColumnReport`, set from `file.columns` at its one construction site.
- `SeedCSVImportText.renamedColumns(_ report: SeedCSVImport.ColumnReport) -> [(header: String, column: SeedCSVImport.Column, field: String)]` — the mapped columns whose `headerKey(header) != column.canonicalKey`, in file order, with `field = column.displayName`.
- `SeedCSVImportText.ignoredColumns(_ report: SeedCSVImport.ColumnReport) -> String?` — `report.ignored` joined with `", "`, or nil when empty.
- `SeedCSVImportText.ignoredColumnsFooter = "These columns were not imported. They stay in your file."`
- DEBUG only, in `SeedCSVImportFixture`: `static let aliasLaunchArgument = "-SeedkeepCSVImportAliasFixture"`, `static let aliasCSV` (the text below), and `static func data(arguments: [String]) -> Data`, which returns `Data(aliasCSV.utf8)` when `aliasLaunchArgument` is in `arguments` and the existing `data` otherwise. `consumeRequest` is unchanged, so the preview still opens only when `-SeedkeepCSVImportFixture` is present; the alias argument is added to it, never used alone. At `SeedCSVImportView.swift:421`, change the load to `await session.load(data: SeedCSVImportFixture.data(arguments: CommandLine.arguments))`.

```text
Seed Name,Crop,Source,Year Purchased,Qty,Location,Price,Germ %
Brandywine,Tomato,Baker Creek,3/15/2025,3 pkts,Seed box,3.50,85
Moon and Stars,Watermelon,Baker Creek,2024,1,Seed fridge,4.00,
Sugar Ann,Pea,Johnny's,2026,2 packets,Seed box,3.25,90
```

**Preview layout:** a `Section` with `WBSectionHeader("Columns")`, directly above the "Seeds" section, shown only when `renamedColumns` is non-empty or `ignoredColumns` is non-nil. Use the view's existing private helper `valueRow(_:_:id:)` (line 641), which stacks at accessibility sizes, never truncates and prefixes identifiers with `csvImport.`:
- one `valueRow(item.header, item.field, id: "mapped.\(item.column.rawValue)")` per renamed column, in a `ForEach` with `id: \.column`;
- then, when there are ignored columns, `valueRow("Not imported", ignored, id: "ignoredColumns")`, with `ignoredColumnsFooter` as the section footer in `.wbFootnote`.

- [ ] **Step 1: Write the failing tests** (in `SeedCSVImportPlanTests`; `Self.snapshot` is that suite's existing helper at line 47)

```swift
@Test("the plan carries the column report, and the preview text names renamed and ignored columns")
func columnReport() throws {
    let file = try SeedCSVImport.parse("Seed Name,type,Qty,Price,Germ %\nBasil,Herb,2,1.99,90\n")
    let plan = SeedCSVImport.plan(file, snapshot: Self.snapshot([]))
    #expect(plan.columns == file.columns)
    let renamed = SeedCSVImportText.renamedColumns(plan.columns)
    #expect(renamed.map(\.header) == ["Seed Name", "Qty"])
    #expect(renamed.map(\.field) == ["Name", "Packets"])
    #expect(renamed.map(\.column) == [.name, .packets])
    #expect(SeedCSVImportText.ignoredColumns(plan.columns) == "Price, Germ %")
    let own = try SeedCSVImport.parse("name,variety,stored_in\nBasil,,Box\n")
    #expect(SeedCSVImportText.renamedColumns(own.columns).isEmpty)
    #expect(SeedCSVImportText.ignoredColumns(own.columns) == nil)
}

@Test("aliased identity columns switch matching on, and a matching row is an update")
func aliasDrivenUpdate() throws {
    let snapshot = Self.snapshot([Self.seed("s1", name: "Basil", variety: "Genovese", company: "Johnny's", year: 2026, packets: 1)])
    let plan = try Self.plan("Seed,Variety,Source,Year,Qty\nBasil,Genovese,Johnny's,2026,4\n", snapshot)
    #expect(plan.matchingEnabled)
    #expect(plan.updatedCount == 1)
    #expect(plan.newCount == 0)
}
```

`Self.snapshot`, `Self.seed` and `Self.plan` are the suite's existing helpers (lines 24–60).

- [ ] **Step 2:** Run `-only-testing:SeedkeepTests/SeedCSVImportPlanTests`. Expected: a build failure.
- [ ] **Step 3:** Implement the `Plan` field, the text members, the preview section and the alias fixture. `xcodegen generate` is not needed (no new file).
- [ ] **Step 4:** Run all import suites. Expected: all pass. Build the Mac destination: `xcodebuild build -quiet -project Seedkeep.xcodeproj -scheme Seedkeep -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
- [ ] **Step 5:** Run `scripts/r4-screenshots.sh DD9BE2B2-F191-459F-8B5B-1AD8B252B171`. Its step 07 opens the canonical fixture; confirm in `light-default-07-csv-preview` that no Columns section appears. Then launch once by hand with `-SeedkeepFixture -SeedkeepCSVImportFixture -SeedkeepCSVImportAliasFixture`, screenshot the preview at the default size and at the largest accessibility size, and confirm the Columns section lists six renamed columns (Seed Name → Name, Crop → Type, Source → Company, Year Purchased → Year, Qty → Packets, Location → Stored in) and "Not imported: Price, Germ %" without truncation. Send both screenshots to the owner.
- [ ] **Step 6:** Reviews, then commit: `feat(import): show renamed and ignored columns in the preview`.

### Task B4: Offer import from an empty library

This task is the first to cut if the calendar slips (umbrella plan, section 4).

**Files:**
- Modify: `Seedkeep/Features/Library/LibraryView.swift` (the private `emptyState(rowsInSelectedState:searchMatches:)` near line 259 and its call at line 74)
- Modify: `Seedkeep/Features/Workbench/SeedsTableView.swift` (`emptyLibrary`, lines 550–566)
- Modify: `Seedkeep/Features/Workbench/SeedCSVImportView.swift` (`SeedCSVImportText`)

**Interfaces:**
- `SeedCSVImportText.spreadsheetHint = "Coming from Excel or Google Sheets? Save the sheet as CSV, then import it."`
- `SeedCSVImportText.importSpreadsheetLabel = "Import a spreadsheet…"`

- [ ] **Step 1:** iPhone Library. `.noSeeds` means the selected status tab is empty, not the library, so add a parameter: `emptyState(rowsInSelectedState:searchMatches:libraryIsEmpty:)`, passing whether the library has no seeds in any status (the unfiltered row collection the view already holds). Leave `SeedsListText.emptyState` and its tests unchanged. In the `.noSeeds` case: when `libraryIsEmpty`, `WBEmptyState(title: "No seeds yet", message: "Tap + to add a seed. " + SeedCSVImportText.spreadsheetHint, systemImage: "leaf", action: (SeedCSVImportText.importSpreadsheetLabel, { showingImporter = true }))`; otherwise the existing `WBEmptyState` unchanged.
- [ ] **Step 2:** Mac and iPad table. `emptyLibrary` is shown only when the library has no seeds. Change its description to `Text("Add a seed to start your list. " + SeedCSVImportText.spreadsheetHint)` and add a second button after "Add seed": `Button(SeedCSVImportText.importSpreadsheetLabel) { showingImporter = true }` with `.buttonStyle(.bordered)` and `.accessibilityIdentifier("seeds.empty.import")`.
- [ ] **Step 3:** Build both destinations. Check on screen, in the DEBUG sample garden (`-SeedkeepFixture`; it is in memory and resets on relaunch, and there is no empty-garden launch argument):
  - iPad ("Seedkeep iPad" simulator) or Mac: select all seeds in the table, bulk delete, confirm the empty state shows both buttons and that "Import a spreadsheet…" opens the file picker.
  - iPhone: open the Wishlist or Archive tab while the library still has seeds and confirm the old message shows with no import button. Then delete seeds from Seed Detail until the library is empty and confirm the new message and button appear and open the file picker.
- [ ] **Step 4:** Run `scripts/a11y-audit.sh DD9BE2B2-F191-459F-8B5B-1AD8B252B171` (about 30 minutes). Expected: `PASS`. Triage any new non-contrast finding by the four rules in `.docs/ai/plans/2026-11-19-a11y-triage.md`: fix a real blocker, otherwise add an allowlist entry with a reason.
- [ ] **Step 5:** Reviews, then commit: `feat(seeds): offer spreadsheet import from an empty library`.

### Task B5: Words that go with it

**Files:**
- Modify: `Seedkeep/Core/Changelog/ChangelogData.swift` (a new first element of `releases`, above the build-55 entry)
- Modify: `web/src/routes/support/+page.svelte` (a new question after "Packet scanning didn't recognize anything on my packet.")

- [ ] **Step 1:** Add the build-56 changelog entry. `release.sh` refuses to cut a build whose number has no entry. If B2b or B4 was cut, remove its line.

```swift
ChangelogRelease(
    version: "1.0.0",
    build: 56,
    date: nil,
    headline: "Bring your seed spreadsheet",
    changes: [
        ChangelogChange(category: .improved,
            text: "Import reads common spreadsheet column names such as Variety, Qty, Source and Location, so your own sheet works without renaming columns."),
        ChangelogChange(category: .improved,
            text: "Cells like “2 pkts” and dates like “3/15/2023” are read as a packet count and a year."),
        ChangelogChange(category: .improved,
            text: "Status words such as Have, Want and Used up are understood."),
        ChangelogChange(category: .improved,
            text: "The import preview lists any columns that were not imported."),
        ChangelogChange(category: .improved,
            text: "An empty seed list offers to import a spreadsheet."),
    ]
),
```

- [ ] **Step 2:** Add the support question:

```html
<h3>How do I bring in my seed spreadsheet?</h3>
<p>
  In Excel, Google Sheets or Numbers, save or download the sheet as CSV (in
  Excel, choose “CSV UTF-8”). In Seedkeep, open Seeds and choose Import CSV. The
  first row must hold the column names, with no title row above it. Seedkeep
  reads columns named for the seed's name or variety, crop or type, company or
  source, year, quantity or packets, status, location, tags and notes. Before
  anything is saved, a preview shows how many seeds will be added or updated and
  lists any columns Seedkeep did not import. Those columns stay in your file.
</p>
```

- [ ] **Step 3:** `cd web && npm ci && npm run -s check && npm run -s build`. Expected: 0 errors. (`web/node_modules` is gitignored, so a fresh worktree has none; `npm ci` installs from the lock file and needs the network.)
- [ ] **Step 4:** Reviews (`ChangelogData.swift` is Swift), then commit: `docs: build 56 changelog and spreadsheet import help`.

### Task B6: Gate, merge and build 56

- [ ] **Step 1:** Wait until Track A's task A9 is finished: `main` holds the merged redesign and the build-55 bump (`git -C ~/git/seedkeep-ios show main:project.yml | grep CURRENT_PROJECT_VERSION` shows `"55"`). Then, in this worktree: `git fetch origin && git rebase main`. In `ChangelogData.swift`, keep the build-56 entry above build 55. If `main` shows `"56"`, build 55 was re-cut: tell the owner and wait for their confirmation that this slice becomes build 57. Then change `build: 56` to `build: 57` in this branch's changelog entry (above the re-cut's entry), commit `docs: renumber the import-tolerance changelog to build 57`, and read every 56 in this task and in the umbrella plan's section 6 as 57. Any other value: stop and report.
- [ ] **Step 2:** When Track A is not using the simulator: `scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171`. Expected: all four suites pass, at or above Kit 25, CloudKit 176, iOS 1,449, Mac 1,464. Then `scripts/a11y-audit.sh DD9BE2B2-F191-459F-8B5B-1AD8B252B171`. Expected: `PASS`.
- [ ] **Step 3:** Ask the owner for the merge go-ahead. On yes, in `~/git/seedkeep-ios`: `git checkout main && git merge --no-ff import-tolerance -m "Merge import tolerance"`.
- [ ] **Step 4:** `./scripts/release.sh --plan-version`. Expected: `[release] version plan: 1.0.0 (55) -> 1.0.0 (56)`. Any other numbers: stop and report.
- [ ] **Step 5:** Ask for the iPhone/iPad upload go-ahead (it signs with the App Store Connect key and uploads). On yes, from `main`: `SIM_UDID=DD9BE2B2-F191-459F-8B5B-1AD8B252B171 ./scripts/release.sh`. Expected near the end: `✔ Seedkeep 1.0.0 (build 56) uploaded to TestFlight`. If it fails, follow "If a release run fails" in Track A's task A9.
- [ ] **Step 6:** If the Mac fallback was not taken, macOS is in the app record, and Track A's A7 dry run passed: ask for the Mac upload go-ahead, then `./scripts/release-mac.sh` (it reads build 56 from `project.yml`, which step 5 committed). Expected: `EXPORT SUCCEEDED`. If any condition is not met, skip this step, tell the owner, and continue; the iPhone/iPad build does not wait for the Mac.
- [ ] **Step 7:** Ask for the push go-ahead (if Cloudflare builds from `main`, say that this push deploys the website). On yes: `git push origin main`, and verify `git ls-remote origin refs/heads/main` equals `git rev-parse HEAD`.
- [ ] **Step 8:** Update both `current-state.md` files with the source commit and build number, tick the umbrella roadmap, and tell the owner build 56 is ready for the checks in the umbrella plan's section 6 ("On build 56").
- [ ] **Step 9:** Remove the worktree: `git -C ~/git/seedkeep-ios worktree remove ~/git/seedkeep-ios-wt/import-tolerance`.

## Not in this plan (1.1)

A column-mapping screen, other encodings and delimiters, title-row detection, paste, `.xlsx`, a stable `id` column, keeping unmapped columns, growing-info columns, duplicate header text handled without refusing the file.
