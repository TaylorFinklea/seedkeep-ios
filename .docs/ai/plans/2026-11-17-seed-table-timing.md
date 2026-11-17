# Seed-table timing follow-up — 2026-11-17

Tracking: `seedkeep-ios-219`. Owner-approved scope: resolve the existing timing
gate, verify the bounded change and record a reviewed local commit. Device,
live CloudKit and release work remain outside this task.

## Final implementation and measurement contract

`SeedsTableModel.sorted` keeps precomputed sort values but moves original-array
indices instead of complete row snapshots. It projects complete original rows
at the end of the synchronous call. Input indices stay valid; no cross-call
cache or model change is introduced. Localized comparison, blanks-last rules,
comparator priority, numeric ordering and ascending ID ties remain unchanged.
A mixed-key regression covers natural numeric names, blanks, missing years
and ID ties. The row mapper is unchanged; all tag-cache prototypes were rejected.

The strict benchmark is a dedicated `@MainActor` XCTest case. On the tested SDK,
the observed XCTest phase runs before the parallel Swift Testing phase. All
functional tests remain in Swift Testing. App gates explicitly require positive
counts from both frameworks; package-mode behavior is unchanged. Failed test
commands still fail even when both positive summaries appear.

The benchmark still times exactly one full 1,000-seed map, name sort and year
sort with `ContinuousClock`, then asserts 1,000 rows and elapsed time below
50 ms. There is no averaging, best-of selection, skipped case or hidden retry.
The original ten-row warmup now exercises mapping and both sort paths, matching
the existing intent to exclude one-time initialization. It never warms a full
1,000-row pass. Results therefore describe **warmed operations**, not cold launch
or first-use latency; the separate manual scroll check remains open.

Frozen six-file implementation patch SHA-256:
`1089f0fee8607799c193c334230aff65cb2aa30c3cab38fded403a7ea308bd1f`.
Production sort file SHA-256:
`f88744249b53d094ce1447eaae9cf78a12976edf0dc39d5e1d2a229b7c10ca8b`.
The final clock, full measured workload and hard assertions are byte-identical
to the first XCTest candidate; retained comparison SHA-256:
`6f6dcd38e09b83f992cd4ff6c02c938dc8a7820d88721ce947ad65d7fdc51634`.

The worker made no commits. The lead integrated frozen patches with
`git apply --index`, verified hashes and regenerated Xcode. Existing unrelated
umbrella changes and old worktrees were preserved.

## Focused verification

- Final warmed candidate: Mac and iOS each passed 16 cases, zero failures/skips:
  exactly one XCTest benchmark first, followed by 15 Swift Testing cases.
  Both real mixed-framework guard commands exited 0.
- The measured elapsed value is not printed on success. Whole-case durations
  include fixture creation and warmup and must not be reported as operation time.
- Count guard: 11 fake-backed checks passed, including missing/zero counts from
  either framework, unrelated count text, failed commands and package defaults.
  Shell syntax and diff checks passed. Replaying counts alone is not acceptance.
- Independent native Terra review approved the exact final source, strict
  workload, warmup bounds and count guard without waiving earlier failures.

## Main validation

The final main checkout ran
`scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171`
on Xcode 27.2 (27B52), iOS/macOS SDK 27.2. It exited 0.

| Stage | Passed | Skipped | Failed |
|---|---:|---:|---:|
| SeedkeepKit | 25 | 0 | 0 |
| SeedkeepCloudKit | 176 | 0 | 0 |
| iOS app, combined frameworks | 1,449 | 1 | 0 |
| Mac app, combined frameworks | 1,464 | 1 | 0 |

Each app ran exactly one XCTest benchmark first, then its full Swift Testing
suite (1,449 total on iOS and 1,464 total on Mac, each including the expected
fixture-generator skip). Both strict 50 ms assertions passed and the mixed
count guards accepted both frameworks. Case wall times include setup and are
not the measured elapsed values. Both large CSV checks passed (80.673 seconds
iOS, 30.697 seconds Mac); no isolated retry was needed.

The signed main Mac Debug build exited 0. Strict deep signature verification
exited 0 and reported a valid signature satisfying its designated requirement.
No app launch, provisioning update or new credential was used. The integrated
implementation patch and production/mapper hashes remained unchanged. DD9 was
restored to its initial Shutdown state; no owned xcodebuild remained.

Separate native Terra source review approved the final patch. The private
archive retains the frozen implementation and review evidence, with redacted
validation and final snapshot receipts added for the completed handoff. Earlier
failed runs below are preserved, not relabeled as passes.
This closes the bounded timing-gate verification, not broader R5 acceptance.

## Earlier failures and investigation limits

The first index-sort candidate retained the old Swift Testing benchmark.
Its focused Mac suite passed 16/16, while focused iOS failed only the 50 ms
case at 61.468 ms. Its main gate passed Kit 25, CloudKit 176 and iOS 1,449 +
one skip, but Mac reported 1,463 passed / one skipped / one failure at
56.864625 ms. Both large CSV checks passed. These failures remain recorded.

The first isolated XCTest candidate retained map-only warmup. Mac passed;
iOS ran its benchmark first and failed at 59.688708 ms, then all 15 functional
cases passed. The guard correctly propagated the failure.

A fresh diagnostic-only iOS case measured first map/name/year times of
16.333/24.205/17.781 ms (58.319 total), then three totals of 42.894–46.892 ms
with comparable mapping and faster sorts. Outputs and string UTF-8 bytes matched.
Changing host load prevents attribution of the difference or any historical
failure. This diagnostic had no 50 ms assertion and is not acceptance.

Warm synthetic pairs supported moving indices: ten pairs reported old sorting
26.66–30.39 ms versus 21.02–23.59 ms, with identical complete 1,000-row results.
The exact initial diagnostic test source was not retained; logs/model snapshots
alone cannot fully reproduce that experiment. Later diagnostic sources were
retained exactly. These measurements do not promise general load reliability.

Additional prototypes were rejected: caching tie IDs gave only 0.385 ms median
paired gain with five slower samples; dictionary tag reuse gained 2.33 ms for
repeats but lost 1.77 ms for distinct sets; last-value reuse gained 1.53 ms but
lost 2.18 ms. Each comparison preserved full results; the final tag-repair diagnostic also
checked all string UTF-8 bytes. None of these prototypes is in the final mapper/sorter.
Initial sandbox cache denials and zero-selection attempts are setup failures,
not passing tests. No historical timing-failure cause is claimed.

## Evidence and boundaries

Private source/review/curated evidence archive:
`.git/seedkeep-agent-patches/2026-11-17-seed-table-timing/`.
Raw temporary evidence remains in the task directories:

- `/private/tmp/seedkeep-seed-table-timing-evidence/` (initial measurements);
- `/private/tmp/seedkeep-seed-table-timing-main-checks-20261117/` (failed first gate);
- `/private/tmp/seedkeep-seed-table-timing-recovery-evidence/` (rejected cache probes);
- `/private/tmp/seedkeep-seed-table-timing-xctest-evidence/` (first isolated case);
- `/private/tmp/seedkeep-seed-table-timing-cold-evidence/` (cold/steady diagnostic);
- `/private/tmp/seedkeep-seed-table-timing-warmup-evidence/` (final focused cases);
- `/private/tmp/seedkeep-seed-table-timing-final-main-checks-20261117/` (final gate/build).

Only DD9 was used for simulator checks; every completed focused run restored
its initial Shutdown state. No picker, personal-device test, live owner-account
app launch, CloudKit action, schema change, push or release occurred. Wider R5
acceptance, cold/scroll runtime checks and deferred manual checks remain open.
