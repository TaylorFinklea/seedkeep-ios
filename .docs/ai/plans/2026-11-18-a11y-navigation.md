# OS 27 accessibility navigation safeguards

Owner-approved scope: restore the stateful audit routes, fix confirmed issues
and rerun all four configurations. Tracking: `seedkeep-ios-65p.2`, under `65p`.
Source starts at `11800a9`; material patch SHA-256 is
`36fcf201af5d06dce5c6fd918b57eec4970e13ba26e69433e571473d1354bc2f`.
Only `AccessibilityAuditTests.swift` and `AuditDriver.swift` change behavior;
application code, audit manifest and allowlist remain unchanged.

## Evidence and repair

The instrumented pre-repair light-default and light-XXXL walks reached the
previously missed routes, so the earlier three aborts' exact cause remains
unproven. Their pre-tap screenshots/trees show API Keys with about 11 points
exposed below navigation and Journal with about 14. The previous recovery
log also shows an unrelated New entry tap when Journal detail never opened.

The audit now positions those two rows inside the reported navigation/tab
viewport with a usable tap area. Lazy-row discovery and positioning remain
bounded; new drag starts avoid the never-touch controls. Existing/default
screenshot-driver behavior stays intact. Recovery attempts to leave a child
only when that child's screen exists; original failures still fail the test.

The no-audit recovery probe passed and its activity log contains no New entry
tap. Both default Settings probes reached API Keys with full rows visible,
but each retained 47 findings. The first displaced-Journal probe failed to
rediscover its absent row. A reviewed search repair reached/audited that entry
on retry with 243 points visible; its two contrast findings still caused
exit 65. Failed attempts, temporary source and corrected retries are retained.

## Main four-configuration walk

`./scripts/a11y-audit.sh DD9BE2B2-F191-459F-8B5B-1AD8B252B171` ran on the
main checkout with the reviewed patch and no private probes. Xcode/SDK 27.2,
iOS 27.0 simulator, isolated sample data. It took 1,892.7 seconds, script
exit 1 / Xcode exit 65, with no watchdog or free-space stop.

| Configuration | Audits | Unallowlisted callbacks | Suppressed |
|---|---:|---:|---:|
| Dark XXXL | 32 | 57 | 23 |
| Dark default | 27 | 100 | 64 |
| Light XXXL | 30 | 54 | 24 |
| Light default | 27 | 108 | 64 |
| Total | 116 | 319 | 175 |

Each configuration reached all 18 destination tops and five fixed extras:
Seeds/scrolled, Seed Detail/plantingPanel, Add Seed/scrolled, Bed Detail/grid
and Bed Detail/squareDetails. Variable Today/Settings page walks are retained
exactly; these totals do not independently prove every physical scroll
position or a defect-resolution delta against earlier runs.

There were no navigation aborts, audit API errors, timeouts or skipped tests.
Per-configuration raw finding descriptions, XCTest error records and exact
method/status xcresult failure nodes reconcile one-to-one at the frozen
audit call site (line 294); zero unmatched harness errors. All four cases
failed on their findings. The 319 unallowlisted and 175 suppressed callbacks
make 494 callbacks in total. Complete observed reachability is not a passing
accessibility audit; callback counts are not distinct defect counts.

## Focused callback observation

A private one-case Today probe repeated the actual `.all` top/page.1 sequence.
Its first build failed on an actor-isolated key path; a reviewed one-line
closure repair compiled and ran in 48.2 seconds without a watchdog stop.
Two callbacks and two matching XCTest/xcresult errors remained (exit 65),
with no additional automation error. No private probe is in the main target.

The captured THIS WEEK element is visible/hittable at y374–426 in an
874-point window. Its sRGB element image has background `#0F1311` (78,856
pixels) and dominant text stroke `#A2ACA5` (22,938 pixels), matching palette
tokens and measuring 8.0073:1. This describes that render, not XCTest's
internal sampled pixels. Empty navigation/status/keyboard queries do not
prove those surfaces absent. The Transplant callback's y1242 frame is an
out-of-window observation only. Neither finding or its family is waived;
no further product defect was confirmed from these observations.

## Regression, signing and preservation

The main full gate passed: Kit 25; CloudKit 176; iOS 1,449 passed/one expected
skip; Mac 1,464 passed/one expected skip, zero failures. Both app frameworks
remain required. Stable iOS and Mac result copies were verified before later
builds. Signed Mac Debug build, deep strict signature verification and offline
system code-signing trust passed, bound to the unchanged reviewed source.

Xcresult export added a cache to the analyzed main-audit copy; all 485 shared
files match the original. A separate pristine copy preserves exactly those
485 paths/hashes. Exported details/attachments and reconciliation have their
own main-audit manifest; that manifest is not the entire task archive.

Task-origin childless DTServiceHub processes outlived Xcode. An initial scoped
SIGTERM did not stop the audit-origin service when observed. Later identity/
session and separate zero-runner checks recorded the services without further
signals. The audit-origin service was later absent; callback/gate services
were recorded alive at final checks. No SIGKILL or global service reset was
used, and exclusive use of those services remains unknown. DD9 began and ended Shutdown; other simulators, photos,
personal devices and live CloudKit were not used. No push or release action.

Private source/failed probes, raw results, manifests, pixel receipt and review
dispositions are retained in `.git/seedkeep-agent-patches/2026-11-18-a11y-walk/`.
Required independent Terra and subscription Claude Code review precede commit.
Parent `65p` and broader R5 remain open, including unresolved findings, deferred
VoiceOver, device/data-preservation, live CloudKit and release acceptance.
