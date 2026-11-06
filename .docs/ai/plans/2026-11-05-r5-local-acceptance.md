# R5 local acceptance — 2026-11-05

## Scope and provenance

The owner said “do it” after N2-E completion and the R5 acceptance handoff.
This pass covers local runtime checks on the existing Seedkeep iPad simulator
`1B4EF142-DF45-475C-979C-FBCBE4CA4E59` (iOS 27.0) and native macOS, using
sample data. Base: native `0823468`, application source `cf64db0`.

Sample mode (`-SeedkeepFixture`) uses in-memory SwiftData, dedicated
`app.seedkeep.fixture` preferences cleared per launch, fake identity/token
storage, no CloudKit coordinators, in-memory API keys and a no-network
forecast. Its scratch cleanup is limited to exact fixture-owned temporary
names. The runtime worker checked for an existing owner Seedkeep process
before the Mac launch; no blanket app termination is authorized.
`-SeedkeepGardenGone owner|participant` adds an in-memory gone-garden guard.
These structural seams isolate the checks; they do not prove live iCloud
behavior. No simulator erase, personal photo picker or personal-data mutation
is part of this pass. Portview is excluded.

Tracking: umbrella `seedkeep-30f.1` under R5 `seedkeep-30f`; native runtime
`seedkeep-ios-k97`, accessibility `seedkeep-ios-65p`, sidebar repair
`seedkeep-ios-k97.1`. The runtime worker owns mutable Mac/iPad sessions;
implementation uses an isolated worktree and lead integration.

## Recorded accessibility triage

The completed N2-E audit remains **345 unresolved reports**, versus N3's
recorded 309. No report has been suppressed or marked fixed by this triage.
The older raw result is unavailable; the +36 total is not a reconstructed
regression set. Repeated checkpoint reports are not distinct defect counts.
160 reports have no associated element.

| Destination family | Contrast | Dynamic Type | Clipping | Element detection | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Settings | 31 | 53 | 40 | 0 | 124 |
| Today | 36 | 0 | 0 | 0 | 36 |
| Seeds | 31 | 0 | 0 | 0 | 31 |
| Bed detail | 19 | 12 | 8 | 2 | 41 |
| Add Seed | 20 | 2 | 2 | 0 | 24 |
| Other destinations | 51 | 26 | 12 | 0 | 89 |
| Total | 188 | 93 | 62 | 2 | 345 |

The raw-log tally is `/private/tmp/seedkeep-r5-local/a11y-tally.json`.
The source audit bundle/log/attachments remain at
`/private/tmp/seedkeep-a11y-audit/20261105-154446-58673`.

Read-only source/attachment inspection found:

- Representative Today section/overdue labels use the existing muted token;
  the checked opaque muted, accent and warning foreground/background pairs
  exceed 4.5:1. This is a calculation for those source pairs, not a measurement
  or clearance of every rendered node. Contrast issue details identify only
  `SwiftUI.AccessibilityNode` and often no element.
- Settings default-size captures show “Share garden via iCloud”, “Check
  iCloud account” and “What's New” fully rendered on repeated scroll pages.
  Representative exported images:
  `/private/tmp/a11y-darkdefault-all/DA3F3E30-3D75-477A-BA80-5685491EE4A7.png`
  and `91565718-BCBB-44F9-9D79-E26ED2A8024D.png` in that directory.
- Square details' “SUGAR SNAP” and spacing labels render fully at default
  size; Notes continues below the sheet viewport. Representative image:
  `/private/tmp/a11y-darkdefault-all/E90E1617-65BC-4EB2-98FD-DB69A9F917FD.png`.
  The underlying `Form` and medium/large detents allow scrolling.
- These captures do not establish Accessibility XXXL fit. Their activity
  attachments lack checkpoint-specific AX hierarchies, so element frames,
  traits and VoiceOver order cannot be reconstructed from them.
- Gone is outside the audit manifest. Its earlier screenshot tests asserted
  existence and captured the top; they did not exercise scrolling to actions,
  confirmation/retry or actual VoiceOver output.

No source-backed defect in those sampled iPhone audit families was confirmed.
That does not classify all findings as harmless. Runtime accessibility and
owner acceptance remain open; the allowlist is unchanged.

## Confirmed runtime blocker

The initial actual iPad fixture capture
`/private/tmp/seedkeep-r5-local/ipad-sample-home.png` shows the selected Seeds
sidebar label dark on the accent fill, a low-contrast count and an invisible
accent-colored leaf icon. `WorkbenchSidebar` forces ink/muted/accent styles
inside the native selected `NavigationLink`. This is a concrete regular-width
runtime issue, separate from the 345 iPhone audit findings. The isolated
worker patch `b72122221fdb6a2b080f675216df91d17a1e0ff4cf400a0701fc9e83de46dfab`
is the one-file shipping change in this handoff: remove three forced foreground colors and
let native selection styling apply, preserving fonts, layout, count AX label
and navigation. The shared palette is unchanged. Xcode generation and diff
checks passed. An initial compile-only worktree build was interrupted after
no visible progress and is incomplete evidence. The fresh main signed Mac
Debug build subsequently passed; strict signature verification passed with
normal filesystem/service access. The restricted-session trust failure is
preserved separately and is not a certificate change or product failure.
Actual iPad and Mac captures now verify selected-row readability in light/dark,
including an inactive Mac window; this does not clear the iPhone audit.

Build: `/private/tmp/seedkeep-r5-local/mac-signed-build.log`; app:
`mac-signed-derived/Build/Products/Debug/Seedkeep.app` under that directory.
Strict-verification receipt:
`/private/tmp/seedkeep-r5-local/mac-signed-codesign-verify-escalated.log`.

## Runtime and repair results

**iPad:** the final isolated Sol probe passed four unique cases, zero failures
or skips, and exported 26 PNGs. A focused two-case Gone repeat strengthened
full-control viewport assertions and passed, exporting 10 additional PNGs;
these are repeats, not six distinct cases. Verified light/dark sidebar and
Name visibility, initial closed inspector, toggle and rotation persistence,
Garden/Windows navigation, Journal search/no-match/clear, and both Gone roles
at Accessibility XXXL. Each choice was captured fully inside the viewport.
The native iPad confirmation popover has no Cancel button; safe outside-
dismiss cancelled it and preserved inventory. Neither final Discard nor Keep
was activated. The fixture stopped and portrait orientation was restored.

Artifacts: `/private/tmp/seedkeep-r5-local/ipad-sol-probe`, including probe
source versions, invocations, raw results/logs, exported manifests and
viewport/frame receipts. The temporary test was removed from the worktree
and is not shipping code; the application source matches the main patch.

**Mac:** actual captured checks cover numbered routes (Today needed one retry
after activation), Settings, command palette, a second main window, and both
Gone roles across two main windows and Settings. Fresh repaired-source light
and dark active selection and inactive-window captures are readable. CSV
export produced the 20-row synthetic fixture file
`/private/tmp/seedkeep-r5-local/seedkeep-seeds-2026-11-05.csv`; the Save panel's
destination was confirmed before export. The complete per-action matrix is
`/private/tmp/seedkeep-r5-local/mac-action-matrix.md`.

CSV import/roundtrip, table-row selection/inspector, grid keyboard behavior
and Mac Discard confirmation/cancel are not yet accepted. Coordinate probes
did not reach the controls; subsequent read-only AX traversal timed out and
one batched repair failed with `-1700`. The owned fixture was quit. These
helper failures are not application defects. A temporary macOS XCTest target/scheme was prepared only in an isolated
worktree. It compiled after correcting unsupported Mac `.rows` queries to
`.cells`; its local fixture app passed strict codesign. The runner then timed
out enabling automation mode and exited 65 before any test body: **zero tests
started**, no app UI actions or screenshots reached. This is a tool failure,
not evidence of an application defect. No permission, trust, automation,
VoiceOver or security settings changed. All owned processes stopped and the
Mac lease returned. The three prepared flows remain unverified and need a
manual pass. Nothing from this QA target is shipping.

The frozen QA-only patch is
`/private/tmp/seedkeep-r5-local/mac-ui-harness.patch` (SHA-256
`9a11bdf40488070a8a0aaa7691e829fecde1ea5a142288fad3c73b753952dd5b`);
corrected probe source SHA-256 is
`5aadb6ed0c42bacffff290f7cde7170c2f0f2373820654ad6eff0fc609f6f4a5`.
Raw compile/run logs and the result bundle are
`mac-ui-probe.log`, `mac-ui-probe-corrected.log` and
`mac-ui-probe-corrected.xcresult` under the R5 artifact root. The original
export is unchanged; no derived import file was created because no test ran.

Some exact signed fixture relaunches produced a process and menus without an
initial window; File > New Window then opened it. This occurred with Light
and Gone roles, including a normal `open` without `-n`. A later launch with
`-SeedkeepAuditLaunch` restored one window. The behavior is intermittent, its
root cause is unproven, and startup acceptance stays open (`seedkeep-ios-k97.2`).
The macOS-only `.defaultLaunchBehavior(.presented)` candidate compiled/signed,
then had a bounded A-B-B-A comparison against the repaired baseline. All four
normal LaunchServices launches, with identical `-SeedkeepFixture
-SeedkeepAuditLaunch` arguments, showed one window at both 5 and 15 seconds.
Exact artifact paths/PIDs were verified with `ps` and `lsof`; each owned PID
quit and exited. No New Window command was needed. The candidate showed no
differential benefit and is **excluded from the shipping patch**. Shared
bundle-ID/restoration state and the lack of resets limit causal inference;
the earlier no-window observation remains an unconfirmed release risk, not
a diagnosed/fixed product defect. Startup needs owner confirmation in normal
use. Automatic restoration and global settings are unchanged. Raw receipts:
`/private/tmp/seedkeep-r5-local/mac-launch-abba/`.

Mac artifacts remain under `/private/tmp/seedkeep-r5-local`. Actual VoiceOver
speech, physical hardware, upgrade and live CloudKit acceptance are not
established by these local checks.

## Required verification

The exact main-checkout gate completed with exit 0:

```sh
scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171
```

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| SeedkeepKit | 25 | 0 | 0 |
| SeedkeepCloudKit | 176 | 0 | 0 |
| iOS app | 1,439 | 1 | 0 |
| macOS app | 1,454 | 1 | 0 |

Both app skips are the existing opt-in fixture generator. Full combined raw
output is `/private/tmp/seedkeep-r5-local/main-gate/gate.log` (SHA-256
`07e2a28a8267d114db6725fa36b8c52422aeb3daf95114e4db39d684e26a558e`);
`ios.xcresult` and `macos.xcresult` are retained alongside it. The gate tested
base `0823468` plus shipping patch `b7212222…dfab`, the same source as the
signed Mac build and runtime checks. No fixture UI overlapped hosted tests.

DeepSeek V4.1 Flash approved that exact shipping patch through the freshly
verified Ollama selector `deepseek-v4.1-flash:cloud`; the response ended
normally (`done: true`, `done_reason: stop`, nonempty content, no error).
The separate launch candidate was excluded. Review artifacts are in
`/private/tmp/seedkeep-r5-local/reviews`. Source/capture provenance and frozen
artifact hashes are in `sidebar-evidence-provenance.json` under the R5 root;
they use retained build/launch/probe receipts, not a retroactive capture-time
attestation. The lead inspected representative repaired Mac light/dark and
iPad dark selected states. No new audit finding is declared resolved.

## Remaining owner and release boundaries

The fixture app shares the normal bundle identifier. OS-managed window
restoration/geometry can therefore be shared across these debug artifacts;
an earlier attempt to restore window geometry did not take effect. No saved-
state reset or guessed preference overwrite was performed. Sample-garden/
CloudKit isolation does not establish unchanged OS-managed UI restoration.

Actual VoiceOver speech/read-order acceptance is distinct from an AX tree or
screenshot. Physical-device upgrade requires the exact owner device/build;
live CloudKit deletion/Keep/stop-sharing requires a separately approved
throwaway garden. Optional spikes are restricted to approved
`seedkeep-spike-*` zones. The server-retirement runbook still starts with a
Postgres export. Push, publication, upload, submission and release remain
separate explicit approvals. R5 is not complete merely because local checks
or a styling repair pass.
