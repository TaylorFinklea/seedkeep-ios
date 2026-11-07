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

## Focused Settings diagnostic follow-up

On source `3ded648`, an isolated temporary test class captured eight DD9
checkpoints: Settings top, Share garden via iCloud, Check iCloud account and
What's New, at light default and Accessibility XXXL. The initial Luna capture
failed before its first checkpoint because it read metadata from a lazy,
offscreen row. Its bounded repair also failed; a Sol worker repaired those
optional reads and split the two configurations. Only QA code changed.

The repaired diagnostic completed all checkpoints but **did not pass cleanly**:
Xcode exited 65 and both test cases failed on retained audit findings. There
were no harness aborts or audit errors.

| Configuration | Checkpoints | Contrast | Dynamic Type | Clipping | Reports |
| --- | ---: | ---: | ---: | ---: | ---: |
| Light default | 4 | 12 | 31 | 15 | 58 |
| Light XXXL | 4 | 2 | 5 | 5 | 12 |
| Total | 8 | 14 | 36 | 20 | 70 |

Fifteen reports had no element. These targeted checkpoints differ from the
canonical four-configuration walk: do not add 70 to 345 or interpret the
count difference as a regression/resolution set. Seventeen old configuration/
type/id/label groups reproduce (29 old reports, 31 fresh reports), without
checkpoint/frame identity. **All original 345 reports remain unresolved.**

Six full-frame receipts and the pre-audit screenshots show each named button
fully rendered inside the 402×791 usable viewport at both sizes. At XXXL,
Share and Check are 217.33 pt high; What's New is 155.33 pt. Default heights
are 52 pt. This supports visibility of those captured controls, not every
rendered node or a waiver of their reported clipping/text-size issues.

The light-XXXL Share checkpoint exposes an audit-associated state change:
before auditing, Share and What's New render fully; immediately afterward,
the form is blank except for the title/tab bar and its AX scrollbar is at
100%. Another bounded scroll re-exposes content. The lead inspected the
paired captures. This does not establish a normal-use source defect, explain
all findings, or test a normal user's runtime text-size change. Manual
accessibility/VoiceOver acceptance remains open; the allowlist is unchanged.

Evidence: `/private/tmp/seedkeep-r5-settings-diagnostic-sol/` holds raw log,
xcresult, invocation, `evidence-summary.json`, `matched-old-groups.json` and
`curated-manifest.json`: 16 explicit app-only PNGs and 32 AX/frame texts.
Temporary source SHA-256:
`8b00f778ef852ff6ce5e5612f0865c7c4b3582049c803eef7f7564e4d9f24ddf`;
QA patch SHA-256:
`1b0277104c80b3973e6ccb63f228cd05fc35523074836bfd31cc068520bf6985`.
The earlier failed harness is retained separately at
`/private/tmp/seedkeep-r5-settings-diagnostic/`. No named action, picker,
camera, live CloudKit or global setting was activated. Both fixture and test
runner stopped; DD9's lease was returned.

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

At the November 5 checkpoint, CSV import/roundtrip, table-row selection/
inspector, grid keyboard behavior and Mac Discard confirmation/cancel were
unverified. The November 6 follow-up below verifies the three prepared flows;
grid/keyboard/Tab-order acceptance remains open. Coordinate probes
did not reach the controls; subsequent read-only AX traversal timed out and
one batched repair failed with `-1700`. The owned fixture was quit. These
helper failures are not application defects. A temporary macOS XCTest target/scheme was prepared only in an isolated
worktree. It compiled after correcting unsupported Mac `.rows` queries to
`.cells`; its local fixture app passed strict codesign. The runner then timed
out enabling automation mode and exited 65 before any test body: **zero tests
started**, no app UI actions or screenshots reached. This is a tool failure,
not evidence of an application defect. No permission, trust, automation,
VoiceOver or security settings changed. All owned processes stopped and the
Mac lease returned. At that checkpoint the three prepared flows remained
unverified; see the later owner-attended results below. Nothing from this QA
target is shipping.

The frozen QA-only patch is
`/private/tmp/seedkeep-r5-local/mac-ui-harness.patch` (SHA-256
`9a11bdf40488070a8a0aaa7691e829fecde1ea5a142288fad3c73b753952dd5b`);
corrected probe source SHA-256 is
`5aadb6ed0c42bacffff290f7cde7170c2f0f2373820654ad6eff0fc609f6f4a5`.
Raw compile/run logs and the result bundle are
`mac-ui-probe.log`, `mac-ui-probe-corrected.log` and
`mac-ui-probe-corrected.xcresult` under the R5 artifact root. At that checkpoint
the original export was unchanged; no derived import file had been created
because no test ran.

A subsequent read-only system-log check established a concrete prerequisite:
at 22:14:06, testmanagerd's writer daemon required authentication to enable
automation and LocalAuthentication evaluated “Enable UI Automation”; the
runner timed out at 22:15:06. Scoped retained events and the exact query are
in `/private/tmp/seedkeep-r5-local/mac-automation-diagnosis/`. The trace does
not establish a missing Accessibility grant or whether the prompt was visible.
The owner was asked to attend one future bounded retry; it had not run at
that checkpoint. The later owner-attended run is recorded below.

To make that retry concrete, the frozen QA-only patch was restored over
`3ded648` in `seedkeep-ios-wt/r5-mac-qa-ready`. Build-for-testing succeeded
and produced a real run specification; the app and runner passed strict
signature verification. This preparation launched neither app nor tests.
`/private/tmp/seedkeep-r5-local/mac-ui-ready-manifest.json` binds the source,
app, test bundle and generated `.xctestrun`; its SHA-256 is
`51532b5b8e86e7bb4f1e70ab67360dba85581b132eef3a2e20594bf9d8e9ddb0`.
The run spec SHA-256 is
`fa5e63538c11c196289fabb9fb0071e4e39bebab4142cc22b80210394bfc8164`.
`mac-ui-ready-invocations.txt` records the exact unexecuted command and log
paths. That manifest records preparation-time hashes; subsequent QA rebuilds
reused derived products, so it does not attest their current binary contents.
The target and scheme remain excluded from main shipping configuration.

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

## November 6 owner-attended Mac follow-up

The owner reported the Mac unlocked and automation enabled. XCTest then ran
without another authentication prompt. The first run executed three methods:
Gone confirmation → Cancel passed for owner and participant, preserving the
inventory label; the other two failed in temporary harness setup/selectors.
A Luna repair rerun also failed. Those failures are retained, not counted as
application defects or passing suites.

A bounded Sol repair reached the substantive CSV checkpoints but both methods
failed on inspector lookup. The final narrow Luna correction normalized the
checkbox value instead of treating it only as a String. Actual receipts show
`__NSCFNumber`, value `1`, normalized `true`; the helper no longer closed the
open inspector. No application source, shipping project or system setting was
changed by the agents.

The final focused run **passed two methods, zero failures/skips, exit 0**:
selection displayed inspector identity fields Name=Brandywine and Company=
Baker Creek; the original export previewed 20 unchanged with Apply disabled
and cancelled safely; the edited copy previewed 19 unchanged + one update,
applied with a one-update result, and read back packet count 2 in the table
plus the correct inspector identity. These join the first run's Gone pass as
**three unique passing scenarios across two runs**. No final all-three-case
green suite is claimed. No final Keep/Discard was invoked.

Evidence under `/private/tmp/seedkeep-r5-local/`:
`mac-ui-owner-retry.{log,xcresult}`, `mac-ui-owner-retry-focused.{log,xcresult}`,
`mac-sol-repair/` and `mac-luna-bool-repair/`. The latter folders retain actual
run/source/binary hashes, checkpoints and results; the original export remains
SHA-256 `92a3db62776347827c188b9ccfd7d7ae3c3b1346465b34ed934391bbf249ab21`.
Screenshots include the menu bar and thin background/desktop edges; they are
private local evidence, not strictly app-window-only captures. Exact owned
app/runner/build PIDs stopped and the Mac UI lease was returned.
The lead inspected the final selection and packet-2 screenshots. The final
QA-only patch SHA-256 is
`49c58f21e1971b7c7d9429fb7229491ef71c4aa9d014f0416db0a130d0b58a3e`;
its source and evidence are archived privately in native Git metadata at
`.git/seedkeep-agent-patches/2026-11-06-r5-mac-owner-followup/`.

This verifies the prepared Mac interactions, not normal-use launch behavior,
grid keyboard/Tab order, VoiceOver, the 345 unresolved audit reports, a device
upgrade or live CloudKit acceptance. All prior release boundaries remain.

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

## Follow-up commit verification

The required main-checkout gate was rerun on unchanged shipping source
`3ded648` before this follow-up handoff: exit 0; Kit 25, CloudKit 176, iOS
1,439 passed + one expected fixture-generator skip, Mac 1,454 passed + the
same skip; zero failures. Full raw log and both result bundles are in
`/private/tmp/seedkeep-r5-followup-gate/`. Gate-log SHA-256:
`f3bb1bd2f6c09bb3e2816bfb3ac0ef8c864203da129307fc07b057b3005eee78`.

A fresh signed Debug Mac build from main and strict codesign passed using
existing default development signing. App:
`/private/tmp/seedkeep-r5-followup-signed-derived/Build/Products/Debug/Seedkeep.app`.
Build log: `/private/tmp/seedkeep-r5-followup-signed-build.log`; strict receipt:
`/private/tmp/seedkeep-r5-followup-codesign.log`. These are source/build checks,
not the owner-attended Mac UI run. Temporary Settings diagnostics and the
Mac UI target remain excluded from shipping source/configuration.

## November 6 pre-commit verification

After the UI lease returned, the exact full main-checkout DD9 gate ran on
`5da57e1` with unchanged shipping source: exit 0, Kit 25 / CloudKit 176 / iOS
1,439 passed + one expected fixture-generator skip / Mac 1,454 passed + the
same skip; zero failures. No standalone retry was needed. Raw log and both
xcresults: `/private/tmp/seedkeep-r5-mac-owner-followup/main-gate/`.
Gate-log SHA-256:
`c674d8a9341825cbfc2c6f18175f85b44867960e7581c910112f22f5da9812c4`.

A fresh main Debug Mac build with existing default development signing and
strict deep codesign passed. Build and identity/verification receipts:
`/private/tmp/seedkeep-r5-mac-owner-followup/signed-build.log` and
`codesign.log` in that directory. Build-log SHA-256:
`ecf37b8337da9d615b9bb46a59f37832e427908380fe50c7904239c1b36e9d8c`;
codesign-log SHA-256:
`692835de6d34754ab8ff97d1aa562811d65ff189790903d49d6e2b86e90ca85a`.
The app is the main checkout's default DerivedData Debug `Seedkeep.app`,
team `K7CBQW6MPG`; the source runtime repair remains `3ded648`. No fixture UI
overlapped hosted tests. Both leases returned; this follow-up commits only
handoff documentation, with the temporary QA target excluded.

## Automated Mac keyboard follow-up — focus blocked

Neither intended keyboard scenario is verified. The temporary QA target builds
and passes strict app/runner signature checks, and owner prompt approval
resolved runner initialization. Actual tests then failed to establish the
required keyboard focus; no shipping defect or fix is established. Main app
source/configuration remain unchanged from `bd6b2b1` (sidebar repair `3ded648`).

| Actual run | Passed / failed | What the evidence establishes |
|---|---|---|
| Prompt-approved original QA | 0 / 2 | Harness assumed compact Garden navigation/sheet; numeric typing failed without editor focus. |
| Luna Mac harness repair | 0 / 2 | Danvers inspector opens on click; arrows/Return leave it unchanged. Visible numeric field does not acquire keyboard focus. |
| Sol numeric-only double-click repair | 0 / 1 | Focus remains on Outline/Cell; Packets stays 1 and typing draft 2 fails. Grid was not rerun. |

These are repeated attempts at two scenarios, not five distinct defects.
No numeric draft, Return commit, Escape cancellation, blur commit or subsequent
model readback was reached. The intended numeric readback would establish only
same-process in-memory state, not persistence across launches. Mac Garden uses
the bed switcher and persistent inspector; actual North-bed fixtures are Black
Seeded Simpson at `r8.s1` and Danvers 126 at `r8.s3`. The repaired grid assertion
requires a changed inspector position/identity, avoiding stale-detail success.

Luna corrected the Mac route/fixture/inspector assumptions and used the public
Window menu to move only the fixture window onto the captured display. After
that concrete attempt and repair failed, Sol tried public double-click entry
into the number editor once. Its post-click AX still shows the table cell,
rather than the TextField, with keyboard focus. No private focus API or new
permission/trust change was used. Capture files include desktop/other-app
context and remain private; they are not strictly app-only screenshots.

The host's read-only `AppleKeyboardUIMode` was 0. [Apple's focus guidance](https://developer.apple.com/videos/play/wwdc2023/10162/)
explains that Mac buttons do not acquire focus on click and need keyboard
navigation for Tab focus. The grid test's focus precondition is therefore
unproved; this does not establish that the app's arrow logic is defective or
that enabling the setting would make it pass. The global setting is unchanged.
Manual checks stay deferred, and no additional automatic retry is planned.

Evidence root: `/private/tmp/seedkeep-r5-keyboard/`.

- Original prepared QA patch: `prepared-qa.patch`, SHA-256
  `a8bef3e61a058541c793af69fa212e452dc5d1f5e4efa42155bb1250cc6599a9`.
- Luna repair: `run-manifest-prompt-approved-repair.json`, frozen
  `qa-keyboard-final.patch`, two-case xcresult and 17 exported attachments.
- Sol attempt: `sol-numeric/run-manifest.json`, SHA-256
  `da8bfbab95af9859b741c22983f500260c7064408f8fc0f93b92d4324d537756`,
  source/patch/product/spec/log/result hashes and nine private attachments.

Earlier ENOSPC build failures and both zero-method initialization failures
(LocalAuthentication Code -4, then automation-mode timeout) are retained.
The owner approved exactly five inactive generated-build folders for removal;
`cleanup-receipt.json` records only those deletions, 3.7 GiB before and 5.6 GiB
afterward. The current task's derived-data was then rebuilt. This is not a
claim of permanent free capacity or broader cleanup authority. Source, logs,
results, simulators and personal files were preserved. An unrelated physical-
device WebDriverAgent run was identified read-only and left untouched.
All task-owned app, runner and xcodebuild PIDs exited; Mac UI lease returned.

Fresh main verification is preserved in `main-precommit/`. The first full
gate had one Mac mapping/sorting timing failure: 50.358375 ms against 50 ms.
An incorrect focused filter ran zero tests and is discarded as pass evidence;
the corrected selector ran exactly one test and passed (reported 46 ms).
The exact full-gate retry then passed: Kit 25, CloudKit 176, iOS 1,439 passed
plus one expected skip, Mac 1,454 passed plus one expected skip; zero failures.
No threshold or app source changed. The default signed main Mac Debug build
and strict deep codesign passed with team `K7CBQW6MPG`; raw gate/build/signature
logs and all failed, focused and retry results are retained.

Frozen QA sources, patches and private evidence are copied/hash-verified under
`.git/seedkeep-agent-patches/2026-11-06-r5-mac-keyboard/`; DerivedData
is excluded. This follow-up changes handoff documentation only; the temporary
QA target stays outside main. `seedkeep-ios-k97.3` remains open. Normal-use
startup, Tab order, VoiceOver/manual accessibility, all 345 audit findings,
device/CloudKit checks and release approvals remain open. R5 is not complete.

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
