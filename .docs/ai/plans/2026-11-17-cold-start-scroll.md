# Cold startup and rendered scrolling — 2026-11-17

Tracking: `seedkeep-ios-5ff`. The owner requested cold-start and scrolling QA
after timing commit `914bff3`. Shipping source remains unchanged.

## Method and isolation

A private worktree builds `app.seedkeep.coldscrollqa` with `DEBUG`,
`COLD_SCROLL_QA` and `-O`. This is an optimized diagnostic fixture, not a
Release archive. Its launch guard requires both fixture arguments before live
factories can run. The fixture uses an in-memory SwiftData store, fake identity,
dedicated defaults and scratch paths, no live CloudKit/services, and no production
entitlements, URL handlers or sharing capability. A separate native Terra
review approved the exact source, compiled artifact inventories and runtime plan
before launch.

The fixture inserts exactly 1,000 deterministic active seeds before views are
created. Names span `QA Seed 0000` through `QA Seed 0999`; years span 2000–2025.
It contains no photos, tags or locations. Mac and regular-width iPad exercise
the workbench Table; iPhone exercises the compact list. The compact list orders
the sample by recent updates, opposite the table's initial ascending name order.

Each target's first UI attempt precedes pipeline-only measurements. Later
launches use a new process, without rebooting, purging caches or asserting
disk-cold conditions. Fixture insertion is included in app startup; this differs
from loading a persisted owner garden. Automation duration is not first-frame
or responsiveness latency. Only populated, interpretable trace metrics can
support quantitative launch or hitch claims.

A separate fresh process maps and sorts once without warmup. Timing excludes
fixture insertion/fetch and ends before output validation. Assertions then
check every expected name, ID and year, all 1,000 unique IDs in both outputs,
and descending year with ascending ID ties. This simpler fixture differs from
the warmed benchmark, so its result is not compared to the 50 ms gate.

## Results

| Target | Fresh-process UI observations | Rendered scrolling | Separate first-use pipeline |
|---|---|---|---|
| iPhone simulator DD9, iOS 27.0 | PIDs 34763 / 39174 / 39480 reached the fixture; later launches retained count 1,000 and first row 0999 | Retained snapshots show middle 0471–0460, end 0010–0000, return 0999–0992, and detail 0999 / Variety 39 / QA Company | 18.800375 ms; full output assertions passed |
| iPad simulator 1B4EF142, iOS 27.0 | PIDs 40801 / 42085 / 42385 reached the table with count 1,000 and first row 0000 | One native UI test passed: first 0000–0016, middle 0495–0511, end 0983–0999, return 0000–0016; ascending checkpoint assertions and screenshots retained | 22.744791 ms; full output assertions passed |
| Mac | Fresh PIDs 62118 / 62574 / 62881 each showed the actual 1,000-row table and recognized ascending visible rows 0000–0022 | Guarded wheel probe passed on PID 72411: first 0000–0022, middle 0399–0422, end 0976–0999, return 0000–0022; actual movement and sampled ascending order validated | 13.843959 ms; full output assertions passed |

The exact simulator targets were DD9BE2B2-F191-459F-8B5B-1AD8B252B171 and
the previously approved 1B4EF142-DF45-475C-979C-FBCBE4CA4E59. Each pipeline
number is one first-use operation sample, not an average or launch duration.

The iPhone's original first Seeds AX capture was not retained. Its first Today
screenshot, later launch snapshots, full traversal samples and detail readback
are retained. Initial MCP automation setup timed out, then a bounded retry
returned the actual UI. Its simulator was restored to Shutdown afterward.

The iPad's first actual table/count capture and screenshot are retained. MCP
exposed navigation/toolbar scroll targets but no table scroll target; two
attempts left the rows unchanged and are not counted as traversal. A private
case in the existing iOS UI-test target provides the fallback; it uses the exact
private app and runner, asserts visible table-row order and limits gestures.
Its exact invocation disables parallel testing and selects only the approved
existing iPad and one test method. The final command enables test timeouts with
a 900-second maximum allowance. Independent source/artifact review preceded
each execution. The passed command elapsed 580.415 seconds; its test case took
571.860 seconds. Those durations include the automation workload and are not
app startup or frame-performance measurements.

The first native iPad attempt failed because the driver queried an XCUI Table;
the actual retained hierarchy represents the SwiftUI table as a CollectionView.
The next attempt was deliberately stopped after 257.88 seconds, around row
0218: repeated remote metadata queries made its 50-swipe cap insufficient.
Both result bundles remain preserved as failed/interrupted outcomes. A bounded
Sol recovery cached per-row metadata before local sorting and grouped actual
swipes between readbacks, retaining all checkpoint assertions. Its final run
passed one test, with zero failures/skips; separate native Terra review checked
the summary, target association and all four screenshots. Both simulators were
returned to their original Shutdown states.

Mac's first direct process showed one frontmost window, while the next two
early trials established running processes only. The first helper stopped on
equivalent `/tmp` and `/private/tmp` spellings; the canonicalized helper then
hit its overall discovery deadline. A bounded structural AX search subsequently
verified the table and all three startup samples in the results row above.
Its wheel-event traversal did not reach the middle/end checkpoints; the last
viewport was not retained, so movement from that attempt is unverified.
Those trials are not counted as scrolling passes. A later targeted scrollbar
route stopped on unsupported/non-settable value or range metadata, without
verified movement. Its source and the failed compile/runtime attempts remain
retained.

The final, separately reviewed Mac probe uses ordinary WindowServer wheel
events only after fresh foreground, pointer, geometry and point hit-tests
identify the private PID and verified table ancestry. It stops on detectable
intervention. It exited 0 with actual changed row readbacks through all four
checkpoints; separate native Terra review checked the retained log. Its ordering
checks cover recognized intersecting rows, not every visible cell or every row
in the dataset. Native AX trust was available without a prompt; a read-only host
check also showed an unlocked console. No permission or system setting changed.
Owned private processes stopped and both simulators ended Shutdown. The guarded
pointer cleanup callback emitted no diagnostic, so pointer restoration was not
independently confirmed. Dedicated detail navigation was checked on iPhone;
there is no iPad/Mac inspector-detail claim.

The first Mac App Launch profiler attempt reached its 60-second limit but
stalled while finishing. The exact owned profiler ignored SIGINT/SIGTERM and
was killed; partial trace/log are retained. No usable launch metric or private
app PID was confirmed from that attempt. CUA app selection also timed out;
its completion call succeeded. Further profiler attempts were omitted after
this failure. First-frame, responsive-launch, frame/hitch rate and quantitative
smoothness are **unmeasured**, not zero or passing.

## Main validation

The unchanged main shipping source at `914bff3` passed the exact gate command:

```sh
scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171
```

| Stage | Passed | Skipped | Failed |
|---|---:|---:|---:|
| SeedkeepKit | 25 | 0 | 0 |
| SeedkeepCloudKit | 176 | 0 | 0 |
| iOS app | 1,449 | 1 expected | 0 |
| Mac app | 1,464 | 1 expected | 0 |

Both app frameworks and the existing strict warmed benchmark ran. The normal
signed Mac Debug build succeeded; strict deep verification with system trust
access passed. The initial sandbox-limited verification returned
`CSSMERR_TP_NOT_TRUSTED`; both outputs remain retained. No normal application
was launched. Main HEAD and the pre/post working-tree diff matched during
checks; only the lead's in-progress documentation edit was present. The gate
used its normal default DerivedData, without a wrapper or script change.
DD9 was returned to Shutdown. Main logs and result summaries:
`/private/tmp/seedkeep-cold-scroll-main-checks/`.

## Retained evidence

The curated private archive is
`.git/seedkeep-agent-patches/2026-11-17-cold-scroll/`, with file hashes in
`manifest.sha256`. It retains generic fixture source, final and earlier driver
patches, inventories, compile/review receipts, raw readbacks, synthetic captures,
the four iPad checkpoint images and main-check summaries. Raw private-QA result bundles, build products and the partial trace remain in
`/private/tmp/seedkeep-cold-scroll-evidence/`. Main-gate result-bundle paths
are recorded in the retained logs and point into normal Xcode DerivedData;
the main-check directory contains their summaries and signed-build products.

Initial fixture patch SHA-256:
`8de13e8a5a1dafe8bcb706a684edae38a5c67d4104aa325fe1d2f9f0b893c18a`.
Final iPad QA patch:
`befe308b1c4af542ed09d78a0dd48a56d7585b53f17c7ec14ccb9656948519c8`.
Final Mac helper source:
`5ac7de756d08dcc43676dc711f5c7ddbe4243a9183614c4b2a4021ae857ee019`;
its executable:
`ed0c1fa9a84d2f6973472e4f7d71f313040de9e67ee69f5ea48a1e1c6bd17f17`.
The private fixture and drivers were not integrated into shipping source.

## Boundaries

These checks exclude physical devices, the normal installed application,
owner-account startup, live CloudKit, photo-heavy inventories, reboot/disk-cold
startup, minimum-26 compatibility and release qualification. The deferred
VoiceOver work, historical accessibility findings and wider R5 acceptance remain
open. Trackpad behavior and quantitative smoothness also remain unverified.
No picker, owner-data edit, push or release is part of this task.
