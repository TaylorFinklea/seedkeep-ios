# What's New / Changelog — SPEC (approved via brainstorming 2026-07-18)

Bead: `seedkeep-rdd`. Feature owner: user (Taylor). Repo: `seedkeep-ios`.

## Goal

An in-app "What's New" changelog (Moshi-style): auto-present the latest release's changes,
categorized New / Improved / Fixed, once after each update; a "History" button browses past
releases. Dual audience (locked in brainstorming): a TestFlight testing aid **now** (an entry per
build) presented as polished user-facing copy for the App Store **later**.

## Product decisions (locked)

- **Audience**: both — testers now, users later. Entries are polished user copy, one per shipped build.
- **Keying**: detection + ordering by **build number** (`CFBundleVersion`, monotonic/unique); display
  leads with the marketing version, e.g. "0.4.0 (50)".
- **Categories**: New / Improved / Fixed (maps to the user's "New, fixes, features etc.").
- **Authoring**: `release.sh` is **gated** — refuses to cut a build with no changelog entry, bypassable
  with `--skip-changelog` for throwaway diagnostic builds.
- **History browsing**: drill-down — sheet opens on the latest release; a "History" toolbar button
  pushes a scrollable list of all releases; tapping one pushes its detail.
- **Skipped builds**: auto-present shows **only the latest** release (not a merged catch-up); the full
  trail is in History.

## Approach

**Swift constant as source of truth**, mirroring `CatalogFieldBounds`
(`Seedkeep/Core/Catalog/CatalogFieldBounds.swift` — structured data as `static let`, no runtime file
loading). Rejected: a runtime-loaded bundled JSON (no such runtime path exists in the app — the one
JSON resource `fieldBounds.canonical.json` is test-only) and a server-fetched changelog (cuts against
the serverless R1–R5 direction; needs network + caching). The Swift constant ships in the binary,
works offline, versions with the build, needs zero new infrastructure.

## Data model — `Seedkeep/Core/Changelog/ChangelogData.swift` (new)

Exact shapes (spec-derived):

```
enum ChangelogCategory: CaseIterable {
    case new, improved, fixed
    // display: title ("New"/"Improved"/"Fixed"), tint (HerbColor), symbol (SF Symbol name)
}

struct ChangelogChange: Identifiable {           // Identifiable for ForEach; id can be synthesized
    let category: ChangelogCategory
    let text: String
}

struct ChangelogRelease: Identifiable {
    var id: Int { build }
    let version: String          // "0.4.0" — marketing, shown prominently
    let build: Int               // 50 — the ordering + detection key
    let date: String?            // optional display date, e.g. "2026-07-17"
    let headline: String?        // optional one-line release summary
    let changes: [ChangelogChange]
}

enum ChangelogData {
    static let releases: [ChangelogRelease]      // authored newest-first
}
```

Category → presentation mapping (spec-derived; use the existing tokens named in the codebase map):
- `.new` → title "New", `HerbColor.sage`, SF Symbol `sparkles`
- `.improved` → title "Improved", `HerbColor.ochre`, SF Symbol `wand.and.stars`
- `.fixed` → title "Fixed", `HerbColor.rose`, SF Symbol `ladybug`

Keep the tint/symbol mapping ON `ChangelogCategory` (a computed property or a small switch) so the view
stays declarative — mirror how `HerbBanner.Severity` carries its own symbol+tint
(`Seedkeep/.../HerbBanner.swift:27-81`).

## Detection — `WhatsNewGate` (new, pure + host-testable)

Persistence key: `seedkeep.whatsNew.lastSeenBuild` (Int), following the `seedkeep.<area>.<detail>`
idiom. Mirror `FeatureFlags` for the static style and the 27d.18 guard-then-set marker discipline
(`ParticipantRowRecovery.swift:159-233`).

**The decision function is PURE** (no `UserDefaults`, no `Bundle` — inject both), so it is unit-testable
without touching real defaults or the bundle. This is the load-bearing logic:

```
enum WhatsNewGate {
    // Pure decision: which release (if any) to auto-present. Nil = present nothing.
    static func releaseToAutoPresent(
        releases: [ChangelogRelease],   // ChangelogData.releases
        lastSeenBuild: Int?,            // nil = first install / never recorded
        currentBuild: Int               // Bundle CFBundleVersion at the call site
    ) -> ChangelogRelease?

    // Persistence helpers (injectable defaults for tests):
    static func lastSeenBuild(defaults: UserDefaults = .standard) -> Int?
    static func markSeen(build: Int, defaults: UserDefaults = .standard)
}
```

Required semantics of `releaseToAutoPresent` (test these exactly):
1. **First install** (`lastSeenBuild == nil`): return `nil` — do NOT auto-present. (The caller then
   silently baselines: `markSeen(build: currentBuild)`.) A brand-new user is never shown a "What's New"
   for a version they never upgraded from.
2. **Updated** (`lastSeenBuild != nil` and the newest release's `build > lastSeenBuild`): return the
   **single newest** release whose build ≤ `currentBuild` (never advertise a release newer than the
   running binary). Latest-only, even across skipped builds.
3. **Nothing new** (newest presented build ≤ `lastSeenBuild`): return `nil`.
4. **Downgrade** (`currentBuild < lastSeenBuild`, e.g. an older TestFlight build re-installed): return
   `nil` — never treat a downgrade as "new"; leave `lastSeenBuild` untouched.
5. Empty `releases`: return `nil`.

Caller sets `markSeen(build: <presented release build>)` when the sheet is presented, and
`markSeen(build: newestBuild)` when opened manually from Settings — either clears the unseen state.

> Implementation note: `releaseToAutoPresent` is a good candidate for a user-authored contribution —
> it is small, pure, and its edge cases (first-install, downgrade, skipped builds) are the design's real
> decisions. Scaffold it with the signature + doc comment + a `// TODO(you)` and let the user fill the
> body during implementation.

## Authoring gate — `scripts/release.sh`

After `NEW_BUILD` is computed (script line ~71) and beside the existing dirty-tree (line ~52) and
test-gate (line ~86) checks, add a fail-closed check: grep `Seedkeep/Core/Changelog/ChangelogData.swift`
for an entry with `build: <NEW_BUILD>`. Missing → `fail "…"` with a message naming the file and the
expected `build:` value. Add a `--skip-changelog` flag (parsed in the existing flag loop, lines ~41-49)
that downgrades it to a warning for throwaway diagnostic builds. Run the check BEFORE the version bump
mutates `project.yml`, consistent with the existing "check before mutating" ordering.

## UI — `Seedkeep/Features/WhatsNew/` (new)

- **`WhatsNewSheet`**: a `NavigationStack`-wrapped sheet (mirror the sheet idiom in
  `InviteAcceptView.swift:16-30` and `SettingsView.swift:331-335`: `.cancellationAction` "Close"
  toolbar button). Root shows one release's changes; a "History" `.primaryAction`/toolbar button
  (SF Symbol `clock.arrow.circlepath`) pushes the history list.
- **Release detail view** (reused for the auto-presented latest AND each history entry): header in the
  `InviteRetirementNotice` panel idiom (`InviteAcceptView.swift:38-57` — display-font title + centered
  layout) showing the version+build and optional date/headline; then the changes grouped by category,
  each category a labeled section with its tint + SF Symbol, rows styled after `HerbBanner`
  (`HerbBanner.swift:27-81`). Use `HerbFont`, `HerbColor`, `Rubric`, `HerbSpace` tokens per the design
  system; no new colors.
- **History list**: a `List`/`Form` of releases newest-first (`ChangelogData.releases`), each row
  "version (build) · date" with a chevron; tap → push the release detail.
- **Entry points**:
  1. **Auto-present**: in `RootView` (`SeedkeepApp.swift`), signed-in branch, present a sheet sibling to
     the invite sheet (`SeedkeepApp.swift:112-125`), computed once during the launch `.task`
     (`:55-59`). Guard against colliding with a pending invite/CKShare sheet — if one is pending, defer
     What's New to the next launch (do not stack two sheets).
  2. **Manual**: a "What's New" row in `SettingsContent` near the build-stamp footer
     (`SettingsView.swift:318-325`), showing a small unseen-dot (accent `HerbColor`) when
     `newestBuild > lastSeenBuild`. Opening it presents the same `WhatsNewSheet` on the latest release.

App is forced `.preferredColorScheme(.light)` (`SeedkeepApp.swift:54`) — design for light only.

## Initial content seed

`ChangelogData.releases` ships seeded with **build 50** (current) authored from this session's shipped
work — draft copy, user refines the voice:
- New: "Recover garden entries that didn't make it into a shared garden — Settings flags any that need
  your review."
- Improved: "Sharing is simpler — gardens are now shared entirely through iCloud."
- Fixed: "Old invite links now explain that sharing moved to iCloud instead of failing."

Optionally seed **builds 49 and 48** for a non-trivial History demo (user-authored copy). Not required
to ship; History works with a single entry.

## Testing — `SeedkeepTests/WhatsNewGateTests.swift` (new)

Swift Testing (`@Suite`/`@Test`/`#expect`). The pure `releaseToAutoPresent` needs NO container and NO
defaults — test all five semantics directly with in-line `ChangelogRelease` fixtures:
1. first install (`lastSeenBuild == nil`) → nil
2. updated (newest build > lastSeen, ≤ current) → the newest release
3. nothing new (newest ≤ lastSeen) → nil
4. downgrade (current < lastSeen) → nil
5. empty releases → nil
6. latest-only across skipped builds (lastSeen 48, releases 49+50, current 50) → 50, not 49

Persistence helpers: mirror the save/restore-defaults idiom (`ProductionDefaultCloudKitGateTests.swift:12-51`)
OR the 27d.18 unique-key-per-run idiom (`ParticipantRowRecoveryTests.swift:11-58`) so no real defaults
leak between tests — assert `markSeen` then `lastSeenBuild` round-trips, and unset → nil.

Add a `ChangelogData` integrity test: builds are unique and strictly descending as authored; every
release has ≥1 change; no empty `text`. (This is the runtime guard that the authoring stays well-formed,
analogous to the `CatalogFieldBounds` parity test.)

Both `scripts/test-gate.sh` lanes must stay green; baseline 460 tests / 50 suites — new tests add on.

## Out of scope

- Localization (app has no String Catalog; all copy inline — consistent with the codebase).
- Server/CloudKit-hosted changelog, remote editing, per-user targeting.
- Rich media in entries (images/video). Text only for v1.
- Auto-generating copy from commits/beads (explicitly rejected — authoring is hand-written + gated).
- Marketing-version-level grouping/collapse (entries are per-build; App-Store-time curation is a later
  concern, not v1).

## Acceptance

- Updating the app to a build with a newer `ChangelogData` entry auto-presents that entry once; dismiss
  + relaunch same build does not re-present.
- A fresh install does not auto-present; it baselines silently and the entry is reachable from Settings.
- Settings "What's New" opens the sheet; the History button reaches every past release; the unseen dot
  clears after viewing.
- `release.sh` refuses a build with no matching `ChangelogData` entry; `--skip-changelog` bypasses.
- Flag-OFF/general regression: both `test-gate.sh` lanes green; new `WhatsNewGate`/`ChangelogData` unit
  tests pass and the pure decision function's five/six semantics are each asserted.

## File manifest

New:
- `Seedkeep/Core/Changelog/ChangelogData.swift` (data + category presentation mapping)
- `Seedkeep/Core/Changelog/WhatsNewGate.swift` (pure decision + persistence helpers)
- `Seedkeep/Features/WhatsNew/WhatsNewSheet.swift` (+ release-detail + history-list views; may split)
- `SeedkeepTests/WhatsNewGateTests.swift`, `SeedkeepTests/ChangelogDataTests.swift`

Touched:
- `Seedkeep/App/SeedkeepApp.swift` (auto-present wiring in RootView / launch task)
- `Seedkeep/Features/Settings/SettingsView.swift` (What's New row + unseen dot near the footer)
- `scripts/release.sh` (changelog gate + `--skip-changelog`)
- `project.yml` only if a new group needs explicit listing (Resources already auto-bundled; no new
  resource — pure Swift, so likely no project.yml change).

Commit convention: one focused feature commit (or a small series: data+gate, UI, tests), message
`feat: in-app What's New changelog (seedkeep-rdd)`, trailer
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do NOT push.
