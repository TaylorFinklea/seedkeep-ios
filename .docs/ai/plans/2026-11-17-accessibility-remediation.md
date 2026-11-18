# Automated accessibility investigation and prompt repair

Owner-approved scope: refresh the four-configuration iPhone audit, classify
reports from retained evidence, and repair confirmed native accessibility
issues. Tracking: `seedkeep-ios-65p.1`, under `seedkeep-ios-65p`.
Manual VoiceOver, OS 26 runtime, device/CloudKit and release acceptance remain
separate. This report does not declare the audit or R5 accepted.

## Unchanged-source baseline

Source: native `3559ecf` (shipping source `914bff3`). Xcode 27.2, approved
DD9 simulator, isolated sample fixture, English/US. The unchanged
`scripts/a11y-audit.sh DD9BE2B2-F191-459F-8B5B-1AD8B252B171` completed all
four effective configurations on November 17. Its script exited 1 and
xcodebuild exited 65 on findings, with no audit API errors, aborts, test
skips or timeouts.

| Configuration | Audited checkpoints | Finding callbacks | Suppressed |
|---|---:|---:|---:|
| Dark, accessibility XXXL | 40 | 88 | 23 |
| Dark, default | 28 | 141 | 64 |
| Light, accessibility XXXL | 29 | 59 | 24 |
| Light, default | 27 | 120 | 64 |
| Total | 124 | 408 | 175 |

The 408 callbacks comprise contrast 240, Dynamic Type 100, clipping 64 and
text detection four. No unused allowlist entry was reported. They are
occurrences, not distinct bugs. Seventy-nine lack element identity; the
baseline logger cannot distinguish a nil element from a non-existing one.
The former 345-report raw bundle is unavailable, so no exact regression or
resolution comparison is possible. Relative sample dates and scroll history
also prevent interpreting an aggregate difference as a regression.

The taxonomy reconciles every raw finding and suppressed callback. Its
family grouping includes both kinds of callbacks and is not a defect count.
All four element-detection callbacks join by ordinal and issue text to an
xcresult issue description and app screenshot, but none exposes an element
screenshot or target region. Nearby bed hierarchies predate the square-details
sheet. These reports remain unresolved; OCR or a full-screen screenshot
alone does not identify their source element.

## Focused normal-render comparison

Private diagnostic source SHA-256:
`88b34c2a3655187fb556e0358b707d231f89b39190700ec7e000feb22f44a4b3`.
Each target/mode used a fresh isolated fixture launch. All callbacks were
retained; the handler returned false. Tests compared normal BEFORE/AFTER
images, hierarchies and control metadata around contrast-only and all-types
audits. Dark default and dark XXXL each completed six captures, with 22 and
14 callbacks respectively, and zero setup/audit API errors. xcodebuild exited
65 on findings; the outer watchdog was not triggered. DD9 was restored to
Shutdown. The packet includes 24 screenshots and 24 hierarchies.

- Sunrise did not reproduce a target-specific finding at the selected visible
  position. Baseline images place its value partly beneath top system chrome.
  This supports an occlusion hypothesis, not clearance of every report.
- The visibly clear week summary did not receive the focused contrast
  callbacks. The callbacks named other labels, including content behind the
  tab bar or outside the window. All-types auditing also changed some frames.
  Callback-time pixels and complete chrome geometry remain unproven.
- Add Seed's Cancel is enabled, whereas the empty form's Save is disabled.
  The owning-button and navigation-bar metadata distinguish them; both still
  receive audit reports. An inactive-control contrast exception cannot cover
  the enabled Cancel button. No suppression was added for either.
- Missing chrome/keyboard geometry is explicitly unknown. Window containment,
  hittability or a readable screenshot alone is not a complete visibility,
  contrast or VoiceOver proof. Truly nil callbacks also occur in the focused
  diagnostic and remain unresolved.

## Confirmed normal-render issue and bounded repair

The normal Add Seed identity fields convey their purpose only through their
empty-field prompts. Standard-library pixel sampling of the retained sRGB
dark-default BEFORE image finds dominant full-stroke RGB `#656569` on uniform
row RGB `#2C2C2E`, approximately 2.4016:1. This is independent of the audit's
Cancel/Save callbacks. The existing field titles and source identify these
as active prompts, rather than disabled controls or decoration.

The private repair supplies explicit prompt Text using the existing dynamic
`WBColor.muted` token for Name, Variety and Company. The product patch SHA-256
is `ef82bdb0ae896087a9260b6ba30fd2f405a196086eb8f703fbbdcd10afedbc51`:
three changed lines, preserving titles, bindings, capitalization and save
rules. No palette, global form style, layout or allowlist was changed.

All twelve empty-field captures have measured full-stroke colors and flat
row backgrounds. The pixel sampler binds each image to its configuration,
field title and AX frame; all PNGs carry sRGB metadata. Separate Terra review
reproduced the samples, hashes and arithmetic.

| Appearance and size | Before (dark captures only) | Repaired foreground / background | Repaired contrast |
|---|---:|---|---:|
| Dark default | 2.4016:1 | `#A2ACA5` / `#2C2C2E` | 5.9600:1 |
| Dark XXXL | 2.4016:1 | `#A2ACA5` / `#2C2C2E` | 5.9600:1 |
| Light default | Unmeasured | `#56605A` / `#FFFFFF` | 6.5289:1 |
| Light XXXL | Unmeasured | `#56605A` / `#FFFFFF` | 6.5289:1 |

Name, Variety and Company match within each configuration; no sample was
unmeasured. These are measured empty-state colors, not a complete accessibility
acceptance or typed-content contrast claim.

The first draft QA run passed both default-size configurations. Both XXXL
cases captured all three empty fields and retained a long typed Name, then
failed the private helper's Variety scroll. The failure-proximate image shows
no software keyboard covering the fields; AX reports a keyboard below the
app window. The failure cause remains unproven. A separately reviewed,
private one-line test repair changes its preflight from hittability to the
existing whole-frame check before an ordinary tap and exact value assertions.
The retry of only the two failed cases passed (52.779s dark / 44.801s light;
xcodebuild exit 0, outer watchdog not triggered, 135s overall). It verifies
all three retained draft values, disabled Save while empty, enabled Save
after typing, and enabled Cancel, without saving. These four configurations
passed across the initial run and retry, not in one all-green run. First
failures remain preserved; no product change was made in response to this
QA failure. The normal simulator was restored to Shutdown.

W3C's [contrast minimum guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
includes placeholder text. Screenshot samples describe these exact renders;
they do not establish contrast on every OS, display or system setting.

## Post-repair full-walk result

The unchanged main audit rerun started at 20:05 CST, November 17. All four
configurations emitted effective-configuration checks and summaries; its raw
log ends TEST FAILED. The desktop update interrupted the parent console and
outer exit receipt, so no exact script/outer exit is inferred. All raw data
is retained. The three navigation aborts mean this is incomplete coverage.

| Configuration | Audited checkpoints | Finding callbacks | Suppressed | Missing destination |
|---|---:|---:|---:|---|
| Dark XXXL | 30 | 61 | 23 | None observed |
| Dark default | 28 | 142 | 63 | API Keys: 15-second appearance timeout |
| Light XXXL | 30 | 59 | 21 | Journal entry: scroll-into-view failure |
| Light default | 26 | 122 | 63 | API Keys: 15-second appearance timeout |
| Total | 114 | 384 | 170 | Three aborted destinations |

The reconciled finding types are contrast 201, Dynamic Type 110, clipping 69
and text detection four. Seventy-five callbacks lack element identity;
raw `element=nil` cannot distinguish a truly nil element from a non-existing
one. Five source-entry/configuration allowlist pairs were unused. The
allowlist and manifest were not changed. Different walk counts and missed
destinations prevent treating 408 versus 384 as a defect-resolution count.

Both default API Keys failure-time AX trees still show the Settings root,
its navigation bar and tab bar, with no `screen.apiKeys`, after a logged tap.
This proves the expected screen was not reached, not why. There is no
reliable failure-time screenshot: the nearby dark image is What's New after
recovery, and no light image falls within the failure window.

A separate private diagnostic ran once for the three missed checkpoints,
each in a fresh isolated fixture. Source SHA-256:
`361520426ef1c10ca3dc226c606b3e86dfed580b4e57a878ff082540a3063133`.
Independent Terra review verified the source, all 42 compiled product hashes,
xctestrun and exact bounded command before execution. The class selected
only these three methods on DD9, serially, with a 300-second per-method
limit and 1,200-second process-group watchdog.

| Fresh-fixture target | Screen reached | Audit API completed | Unfiltered callbacks |
|---|---|---|---:|
| Dark default API Keys | Yes | Yes | 3 |
| Light default API Keys | Yes | Yes | 3 |
| Light XXXL journal entry | Yes | Yes | 3 |

No setup or audit API error occurred and the watchdog did not trigger.
Xcodebuild exited 65 on nine unhandled finding callbacks; this is not a
passing audit. The callback handler returned false for every issue, so these
unfiltered counts cannot be merged with the full walk's 384 unallowlisted
findings. Normal screenshot/AX captures are before and after navigation,
with the target image taken before its audit; there is no post-audit image
comparison in this diagnostic.

Fresh direct reachability does not reproduce or resolve the original full
walk's three navigation failures. No shared driver, product, manifest or
allowlist was changed. These failures and other audit reports remain with
parent `seedkeep-ios-65p`; accessibility and release acceptance remain open.

## Dispositions and practical limits

| Evidence family | Disposition |
|---|---|
| Three active Add Seed identity prompts, normal dark renders | Confirmed low contrast; repaired and measured in all four configurations, with draft behavior checked across runs. |
| Repeated Today contrast callbacks | Selected baseline text is partly obscured; selected normal in-view targets do not reproduce the same callback. Position dependence is supported; complete family clearance is not. |
| System toolbar contrast and Dynamic Type | Enabled Cancel and disabled Save are distinct. Sampled normal dark Cancel contrast is about 6.05:1, but callback-time rendering, other contexts and Dynamic Type reports remain unresolved. |
| Plain-label clipping and system field reports | Normal screenshots and native horizontal scrolling supply useful evidence. They do not clear every callback or prove full assistive interaction. |
| Missing element identity and text-detection reports | Source element/region is unavailable. Retain as unresolved; no nil-element allowlist or inferred defect attribution. |
| Other raw callback groups | Retain their configuration, destination, checkpoint, type and available identity in the taxonomy. No generic pass disposition is assigned. |

This is a representative evidence classification, not a claim that all raw
callback groups have been individually diagnosed. Parent `seedkeep-ios-65p`
retains the unresolved audit work. The repair does not waive manual VoiceOver
or convert a nonzero audit result into accessibility acceptance.

## Evidence and remaining acceptance

The private archive is
`.git/seedkeep-agent-patches/2026-11-17-a11y-remediation/` in the native repo:
`baseline/`, `taxonomy/`, `diagnostic/`, `prompt-qa-initial/`,
`prompt-qa-retry/`, pixel samplers/results, `main-audit-first/`,
`main-taxonomy/`, `main-checks/` and `missed-checkpoints/`, with SHA-256
manifests and the complete private QA recovery patch.
It preserves the failing baseline and complete diagnostic result bundles,
raw logs, exported attachments, taxonomy source and mappings. Diagnostic
build products remain temporary; their product hashes and command receipts
are archived. No personal-device or live-account data was collected.

The reviewed product patch was integrated into the main checkout using the
worktree binary patch and `git apply --index`; `xcodegen generate` passed.
The full main gate exited 0 with both app runs reporting TEST SUCCEEDED:

| Main check | Passed | Expected skipped | Failed |
|---|---:|---:|---:|
| SeedkeepKit | 25 | 0 | 0 |
| SeedkeepCloudKit | 176 | 0 | 0 |
| iOS app (combined frameworks) | 1,449 | 1 | 0 |
| Mac app (combined frameworks) | 1,464 | 1 | 0 |

Both app totals include the mandatory serial XCTest. Canonical xcresult
summaries, raw gate log and exit receipt are retained. The signed Mac Debug
build and strict deep signature verification passed using system trust.
No successful gate or signed build was repeated after the desktop update.
A fresh state read confirmed DD9 Shutdown after the follow-up.
Captured contrast and normal-draft evidence covers the four iPhone simulator
configurations on OS 27.2; no new iPad/Mac runtime or minimum-26 claim is made.

The first post-repair full walk remains incomplete, and the separate fresh
checkpoint diagnostic remains nonzero on findings. The interrupted parent's
exact outer exit is unknown. Final staged review is the commit prerequisite;
its actual approval is recorded in the commit trailer and private receipt.
No finding is cleared from source inspection, a count reduction or
non-reproduction alone. Manual VoiceOver, minimum-26 runtime, full device/data
preservation, live CloudKit and release boundaries remain open.
