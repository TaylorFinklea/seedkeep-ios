# What's New / Changelog — REPORT (shipped 2026-07-19)

Spec: `2026-07-18-whats-new-changelog-spec.md`. Plan: `../plans/2026-07-18-whats-new-changelog-plan.md`. Bead: `seedkeep-rdd`.

## Outcome

Shipped to `main` (merged from `whats-new-changelog`, 6 commits `d387501..d04dc4c`). In-app "What's New": auto-presents the current build's New/Improved/Fixed notes once after an update, a Settings row + unseen dot open it any time, a History button drills into every past release. Built via subagent-driven TDD — 7 tasks, per-task spec+quality review, opus whole-branch review (READY-WITH-NOTES, no Critical/Important). Full both-lane `test-gate.sh` green (baseline 460 + 3 integrity + 8 gate tests).

## What was built (matches spec exactly)

- `Seedkeep/Core/AppInfo.swift` — `currentBuild`/`currentVersion` from the bundle.
- `Seedkeep/Core/Changelog/ChangelogData.swift` — Swift-constant `[ChangelogRelease]` (seed = build 50) + category→(title/symbol/tint) mapping on `ChangelogCategory`.
- `Seedkeep/Core/Changelog/WhatsNewGate.swift` — pure `releaseToAutoPresent` (6 semantics: first-install→nil, update→newest≤current, nothing-new→nil, downgrade→nil, empty→nil, latest-only-across-skips) + `lastSeenBuild`/`markSeen` on key `seedkeep.whatsNew.lastSeenBuild`.
- `Seedkeep/Features/WhatsNew/WhatsNewSheet.swift` — sheet + `ReleaseDetailView` + `ChangelogHistoryView`, Herbarium tokens, light-mode.
- `Seedkeep/App/SeedkeepApp.swift` — auto-present in RootView, guarded against stacking on a pending invite/CKShare sheet.
- `Seedkeep/Features/Settings/SettingsView.swift` — "What's New" row + unseen dot.
- `scripts/release.sh` — fail-closed gate: no `ChangelogData` entry for the new build → abort; `--skip-changelog` bypass.
- Tests: `SeedkeepTests/{WhatsNewGateTests,ChangelogDataTests}.swift`.

## Design note

Storage is a **Swift constant**, not a bundled JSON. This was re-litigated at ship time: an agent session proposed JSON; the user chose the constant, matching the approved spec. Rationale: the app has no runtime JSON-loading path (its one JSON resource is test-only), the constant mirrors `CatalogFieldBounds`, gets compile-time checking, and needs no decode/error path. See decisions.md 2026-07-19.

## Follow-ups (non-blocking, from the whole-branch review)

- **Authored-ahead marker clamp** (Minor, roadmap): Settings `markSeen`/`whatsNewUnseen` use the newest *authored* build; auto-present clamps to `currentBuild`. They agree in every shipped binary (release.sh gate keeps authored-max == the running build), so nothing broken ships. Divergence only if a dev hand-authors a future build's entry then taps Settings before cutting it — which would suppress that build's real auto-present on update. Cheap hardening: clamp both Settings paths to `AppInfo.currentBuild`. Deferred as a dev-workflow footgun, not a user-facing bug.
- Header alignment: spec called for the centered `InviteRetirementNotice` idiom; impl is left-aligned. Cosmetic — confirm on the device visual pass.
- `AppInfo.currentVersion` currently unused (planned interface; header shows the release's own version). Harmless.
- Reconciled: the whole-branch reviewer flagged the dropped `.ignoresSafeArea()` on `VellumBackground`; Task 3's focused check confirmed `VellumBackground` applies it internally (line 56), matching ~15 call sites. Non-issue.

## Human device-verify (spec Acceptance items needing a real update→launch)

1. Update to a build with a newer entry → sheet auto-presents once; dismiss + relaunch same build → does NOT re-present.
2. Fresh install → no popup, baselines silently; entry reachable from Settings.
3. Settings "What's New" opens; History reaches every release; unseen dot clears after viewing.
4. Light-mode visual pass: header alignment, VellumBackground edges, no collision with the invite sheet.
5. `release.sh` refuses a build with no `ChangelogData` entry; `--skip-changelog` bypasses.
