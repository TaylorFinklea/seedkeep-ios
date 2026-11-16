# Existing photo loading diagnosis — 2026-11-16

The owner requested diagnosis of the existing unavailable photo after the
Roshar update check. This does not establish that the update caused it.
Tracking: `seedkeep-ios-6y0`. The investigation identified the failing read boundary and a conditional source defect. The owner subsequently authorized fix `seedkeep-ios-8ii` and testing on Sel; the fix and its device results are recorded below.

## Verified observations

The original extra photo's row exists and records 87,110 bytes. The copied
phone database passed `quick_check`; main/WAL/SHM metadata remained unchanged
across copying. The photo, seed, visible active garden, cached identity and
owner/private guard binding match. No target gone/retired marker was found.
Both exact production-household phone byte-store listings succeeded with no
matching image. One ordinary reopening after session readiness still showed
the fallback and did not fill the cache.

One exact original image exists in the Mac production-household PhotoCache:
87,110 bytes, matching its content-addressed filename hash, successfully decoded
by ImageIO. A single protected temporary recovery copy matches the source;
the source hash and file identity/mtime remained unchanged. Nothing was copied
back to the phone or uploaded. This proves a recovery source, not remote asset
availability or the phone failure's cause.

A second photo row on the same seed also lacks local bytes. Settings' specific
missing-bytes staging error identifies that second row. It does not explain
the original image. Earlier UI was not exhaustive, so the second row's creation
time/origin is unproven.

## Loading path and evidence limits

`AuthedImage` uses the same fallback for missing data, fetch errors and decode
failure, and discards the error. The cache-miss callback can silently return
nil at its environment/account/writable-garden gates. Exact fetch errors do not
update Settings' sync-pass error. No existing per-photo log reconstructs the
failed stage.

The direct fetch returns a CKRecord before asset materialization, while normal
receive materializes during its callback. Existing tests retain stable asset
files. Asset URL lifetime is a hypothesis only; source inspection does not
prove an Apple API lifetime violation or this photo's cause.

## One approved exact remote read — completed

The owner approved a narrow exception to the incomplete Ollama review for
this one read. Separate native Terra and exact read-only Sol reviews had
approved the temporary Mac helper/launcher; the sole earlier DeepSeek review
timed out without a final verdict and was not retried. The unchanged pinned
launcher then ran exactly once, exited 0 and emitted a complete record result.

The current Mac CloudKit user hash passed the phone-identity comparison before
the exact owner/private-zone fetch. The selected record was `SeedPhoto`; its
asset was present and readable both during and after the callback. The 87,110
bytes matched the phone metadata and remote byteSize, matched the remote
record's declared assetSHA256, and decoded with ImageIO. Separate native Terra
review approved this interpretation. This establishes remote asset viability
at observation, not its equality with the independent Mac cache copy or the
cause of the phone failure. No second helper fetch or CloudKit mutation was
performed.

The helper did not initialize Seedkeep's model/defaults/Keychain/sync engine,
or install/replace an app. It used the exact existing signed identity/profile;
OS-managed sandbox/CloudKit metadata and temporary asset-cache effects remain
possible. The original controlled source/build/launcher receipts are retained.

## Reviewed diagnostic preparation

Existing source retains no photo-read error, and prior evidence confirms a
fresh navigation from the active Seeds list after Settings readiness, not just
a retained view restored by a tab switch. The photoID-only retry caveat alone
does not explain that persistent failure.

A temporary worktree at native `d82399d` adds instrumentation only to the
existing photo-read path. It requires DEBUG plus the explicit
`-SeedkeepPhotoReadDiagnostics` launch flag. Per-photo hashed aliases and
task-local load-attempt sequence numbers expose ephemeral accessibility traces
of the gates, local read, remote fetch, materialization, final cache read,
unavailable-hint update and image decoding. No raw identifiers, paths, pixels,
image hashes, error descriptions or userInfo are displayed; no new storage,
read retries, account/guard/defaults/Keychain/model changes or CloudKit writes
are introduced. Existing loading and normal sync behavior is retained.

The frozen final diagnostic patch is `phone-probe-attempts.patch`, SHA-256
`1a2afeeafbcbe728c5c49ceb2250952c6111aa6e05bd7d2c781b5193945c07fd`.
Synthetic tests passed flag gating, alias correlation, sensitive-error
redaction and isolation of two overlapping same-photo loads with actual older
load cancellation. The repaired patch's generic-iOS correctness compile,
signed iOS/Mac Debug builds, strict signatures, separate native Terra
code/artifact/plan reviews and exact Sol code review passed. The final DeepSeek
fix-round stalled with a thinking-loop error; its harness signaled an automatic
retry, so the lead stopped only that owned review group. No new retry/fallback
was dispatched. The final Ollama review is incomplete, not approval. The
previous owner exception covered only the single Mac read; the proposed phone
session needs a separate review exception as well as install/restore authority.

Final diagnostic candidate:
`/private/tmp/seedkeep-photo-phone-probe-build/attempt-check/Build/Products/Debug-iphoneos/Seedkeep.app`,
CDHash `44d4bc5bbd3cf21b027e615f66f6c4d2f7c4660a`, executable SHA-256
`76661b71ddfc5d7455603ed6f4a913ef9505fbd407bc2a2a42b442da952b35c8`.
The exact signed original normal restore candidate remains at native
`.git/seedkeep-agent-patches/2026-11-13-r5-device-readiness/candidate/Seedkeep.app`,
CDHash `21d85b63af83c622026c1a0a91dc1b6eb04d1d53`. Both full inventories,
strict signatures, matching entitlements/profile and phone coverage were
independently checked; the normal candidate's 20-file manifest matched.
Signing receipt: `phone-probe-attempts-signing-receipt.json`, SHA-256
`4bbaaa3a90e4525afec81285dd3afe2574b29a6c6bca3975cd1e139bad4d59f6`.
Full inventory: `phone-probe-attempts-full-inventory.json`, SHA-256
`fd831f30e7b99359c8f5aa4e17aa30104d5afab56903919c583230a2ed9a18cf`.
Superseded artifacts are retained and must not be used.

Earlier Sol review found indistinguishable final-cache/bookkeeping errors and
mixed overlapping-load traces; both were corrected. A completed DeepSeek
review of the superseded patch also found overlap. Its claimed actor-isolation
build blocker was rejected against actual source: all three caller classes
and the callback are MainActor-isolated, and Debug builds passed. The final
review packet includes that surrounding source context. These are diagnostic
patch reviews, separate from the earlier incomplete Mac-helper review.

The proposed separately approved session is: revalidate both exact signed
artifacts and the authorized phone; stop for lock/authentication or competing
automation; start one verified owned runner during preflight and inspect only
Seedkeep, stopping for another foreground app/phone use, unsaved work or a
blocking prompt; keep that same runner through diagnostic in-place install,
flagged launch, navigation to the existing target seed and redacted attempt
readback, then the exact normal in-place restore, unflagged launch and limited
known garden readbacks; finally stop the owned runner and verify endpoint
closure. Frozen plan: `phone-probe-proposed-session.md`, SHA-256
`26ee4c0667f60add9ac21603f9c76cf1619c92895cdf731a1503bdeff3005081`.
No uninstall, Retry/Delete, picker, Reset/Keep/Discard or manual CloudKit write
is included. Normal startup/sync/cache effects can occur; this is not a
write-free phone session. Unexpected choices, authentication or restore failure
stop the session. Both exact artifacts and the frozen sequence passed native review for owner
consideration; this is not device execution evidence. On-device trace and
restoration remain unverified. The original question targeted Roshar; the
owner instead selected Sel, then asked to be told when XCTest requests Touch
ID. The Sel-specific preflight below supersedes assumptions about Roshar's
installed baseline. No Roshar access occurred after the switch.

## Sel preflight and current external step

Sel was connected, unlocked and Developer Mode enabled. Both exact candidates
and the protected WDA runner passed signature/profile coverage checks for Sel;
full candidate inventories matched. A successful include-all app inventory
found no enumerated bundle/name match for Seedkeep. However, CoreDevice
reported hidden apps excluded with no supported inclusion option, so neither
a clean slate nor absence of retained app data is proven. No Sel app data or
preferences were read, no Seedkeep UI baseline was available, and neither
Seedkeep candidate was installed or activated. The Roshar-specific baseline
and backup waivers are not transferred to Sel.

The single owned, 203-file-verified WDA runner attempt started, but timed out
while enabling automation mode. Output did not confirm Touch ID or a canceled
prompt; the timeout does not prove Enable UI Automation is off. The subsequent
terminal Password prompt was left blank. The owned xcodebuild and its verified
diagnostic child stopped, no matching owned process remained and the fresh
Sel tunnel endpoint refused connection. Xcode may have installed/updated its
WDA runner during startup; no claim of a mutation-free automation attempt is
made.

The owner then confirmed readiness and approved the visible XCTest prompt.
The single retry became ready and reported SpringBoard foreground without
capturing its content, then its owned runner/diagnostic stopped and endpoint
closed. This resolved the automation setup, not Sel's unknown app baseline.

## Approved adjusted Sel session — completed

After that preflight the owner explicitly approved the adjusted Sel diagnostic
install/read/known-normal finish and waived only the incomplete final Ollama
review for this diagnostic. Unknown prior Sel build/retained data and normal
Production iCloud startup/sync effects were disclosed. The adjusted plan passed
native Terra review; Roshar-specific backup/baseline waivers were not reused.
This was not authorization to implement a shipping fix or mutate photo records.
Adjusted plan: `sel-adjusted-session.md`, SHA-256
`eb27edf7b82dbe420e6ac7de045da261d4e791e8504635d7deb3a1d32b7e7372`.

The final diagnostic app was preserved byte-for-byte in the native private
archive `.git/seedkeep-agent-patches/2026-11-16-photo-device-diagnostic/candidate/Seedkeep.app`;
full inventory and strict signature matched its reviewed input. One new owned
WDA session remained ready through the entire approved sequence. Both diagnostic
installation and flagged launch exited 0. Seedkeep opened the existing iPad
Seeds workspace with the target seed and no sign-in, garden choice or recovery
UI. Its normal background startup/sync effects were not measured.

The privately correlated original-photo alias had one retained attempt:

- local row fetched; pending and cache stores missed;
- cloud, identity, guard, writable-garden and signed-in gates all true;
- remote fetch and asset materialization succeeded;
- immediate cache-file read failed with Cocoa 260, then the view caught that
  same failure; image decoding was not reached.

The inspector tree truncates the accessibility label; the full stage sequence
is supported by the separate retained trace file. Native Terra independently
matched the target alias and approved this bounded interpretation. The result
identifies Sel's post-materialization local read failure; it does not prove
Roshar failed at that same stage or that any photo was repaired.

The exact normal candidate was then installed and launched unflagged (both
exit 0). Installed metadata reported `app.seedkeep.ios` 1.0.0 (54), developer-built;
normal Seedkeep foreground showed the same two named seeds without blocking
UI. This binds the verified install input and readback, not an independently
extracted runtime-binary hash or a restore of Sel's unknown prior build. The
photo was not reopened to force another fetch or claim a normal-build fix.

The same runner was then stopped. Its verified diagnostic child stopped after
the terminal Password prompt was left blank; no matching owned host process
remained and the Sel endpoint refused connection. Cleanup is recorded in the
receipt; separate raw cleanup output is not present in that evidence folder.
No uninstall, picker, manual sync, retry/upload/delete, account/settings change,
recovery choice or deliberate photo-row edit was performed. No Roshar action.

Receipt: `/private/tmp/seedkeep-sel-diagnostic-evidence/receipt.md`, SHA-256
`dbfd5d7434fab5a8b7f4b2b5fd44eb537552f4f6a72c529209f2495ae4a93406`.

## Conditional cache defect — reproduced offline

`PhotoByteStore.write` writes a content-addressed file, then deletes enumerated
files whose URL compares unequal to the constructed final URL. The unchanged
production struct was extracted verbatim; only its external root provider was
stubbed to private synthetic scratch directories. Real Foundation enumeration
produced unequal URL representations for the same file under `/tmp` aliases,
symlink roots, relative/base URLs and dot-component roots. In all four cases
production first-write cleanup removed its new file; the returned reference
was absent and immediate Data read failed with Cocoa 260. A canonical root
containing an encoded space retained the file and read the expected payload.
The probe used no mocked enumeration, actual app data or cloud/device access.
It did not exercise an already-existing identical-content write.

Native Terra approved this **conditional source defect**. It matches Sel's
observed failure sequence and is a leading explanation, but Sel's actual URL
representations were not captured. Neither this probe nor Sel establishes
Roshar's historical cause. Standardizing URLs alone did not cover every
symlink case. Comparing the filename within the single enumerated directory
is a proposed fix for separate implementation/review; it needs alias,
idempotent-write, overwrite/stale-retention and prefix/collision coverage.
No shipping fix was made during that diagnosis stage. The later owner-approved
implementation and Sel verification of `seedkeep-ios-8ii` follow below.

Offline receipt:
`/private/tmp/seedkeep-photo-diagnosis/offline-store-probe/receipt.md`, SHA-256
`b5a4dcb913d3dea82983e894ca5855e73f21bdca87ad57f23819c984b357587e`.
The extracted production struct SHA-256 is
`8f19ed1c3cdb71ba24fb90b5a63a022c8f29f5e8eb699920031dd4f20a84e8a8`.

## Owner-approved cache fix and Sel verification

The owner explicitly requested fixing the cache bug and testing the fix on Sel.
The updated working agreement makes the separate native Terra reviewer the
required independent review; optional supplemental reviews do not gate this
change. No additional device-install confirmation was needed for this same
explicitly authorized fix/test scope.

The implementation compares `lastPathComponent` values while enumerating the
single store directory. The optional internal directory seam supports real
filesystem tests; existing production calls still derive the same environment,
lifetime and household namespace. Hashing, atomic publication, stale-version
removal and neighboring-record filtering remain in place. No photo retry/UI,
guard, account, schema or sync changes were added.

Frozen implementation patch: SHA-256
`9faa0ecf2b35789624cbcec15aa11ac9d395ab5b3468fdc9a46c1395cae31c64`.
The worker used an isolated worktree and made no commits there; the lead applied
the binary patch with `git apply --index`, regenerated Xcode and verified both
source hashes. Existing staged diagnosis documents and unrelated umbrella edits
were preserved.

The old predicate reproduced Cocoa 260 for both pending/cache parameter cases.
Before the green run, the test's real root was canonicalized to make its first
case a genuine control, so red and green test source are not byte-identical.
The final tests cover canonical, symlink, relative and dot-component directory
URLs, first writes, same-byte rewrites, replacement/stale removal and a
neighboring record prefix. Isolated roots avoid shared state. Both iOS and Mac
focused suites passed 17/17; signed iOS/Mac builds and strict verification passed.
Native Terra reviewed the exact code, test evidence and signed artifact.

The fixed normal candidate has CDHash
`eb568ea3d65f99f6a015e30a470585f346ab5d3f`; its complete inventory SHA-256 is
`54c9e47bdae9b10039acab24b898b365509b8df6627daef13ed8d3659667a2a3`.
It is `app.seedkeep.ios` 1.0.0 (54), Team `K7CBQW6MPG`, Production
`iCloud.app.seedkeep`. Its signed entitlements and provisioning profile match
the prior normal candidate and cover Sel; application identifiers match and
neither has an explicit keychain-access-groups entitlement. The candidate
contains no temporary photo-read diagnostic instrumentation or launch flag.

One owned Sel automation session stayed active through in-place installation,
unflagged launch, photo checks and one controlled Seedkeep-only relaunch.
Installation and launch succeeded. The original oldest extra photo on the
existing target seed visibly rendered on first load and after relaunch. Its
selected cache directory had one matching 87,110-byte file; before and after,
its contents matched the filename hash and the protected Mac original, and
filename/mtime/hash were unchanged. Both temporary SDK verification copies were
removed; source and recovery copies were not changed. Hash comparisons are
retained redacted proof assertions, not independently rehashable retained
device-file copies. Retained app-only crops show the same seedling image.

The fixed normal build remains installed on Sel. No picker, manual sync,
retry/upload/delete control, cache eviction, user edit, recovery choice or
Roshar action was used. Normal startup/sync/cache effects remain incidental
and unmeasured; no claim of a forced refetch, runtime-binary extraction,
complete data preservation, Roshar acceptance or captured Sel URL spelling is
made. The exercised photo's rendering and persistent cache are established.

Owned runner 2432 and its verified diagnostic child stopped; the terminal
Password prompt was left blank, no matching owned host process remained and
the Sel endpoint refused connection. Separate native Terra review approved the
bounded device evidence. Receipt:
`/private/tmp/seedkeep-sel-photo-fix-evidence/receipt.md`, SHA-256
`cac4d3a35674d8109ab06af008c7317b4f8e44b8780206f8a816d04344741205`.
Code/build receipts: `/private/tmp/seedkeep-photo-fix-evidence/`.

### Final main-checkout validation

After physical automation cleanup, the main checkout ran the required full
`scripts/test-gate.sh --simulator-udid DD9BE2B2-F191-459F-8B5B-1AD8B252B171`.
It exited 1. Package results were Kit 25 and CloudKit 176 passed. The xcresult
summaries report iOS 1,448 passed / one expected skip / zero failures, and Mac
1,462 passed / one expected skip / one failure. The sole failure was the
unchanged `SeedsTableModelTests.mapAndSortPerformance()` budget: 78.495834 ms
against 50 ms. Its one-test isolated retry also failed, at 72.914291 ms, so no
further full-gate retry was run. These are failures, not passing results.

The separately signed main Mac Debug build and strict signature verification
passed; both integrated source hashes stayed unchanged. DD9 returned to its
initial Shutdown state. No performance threshold, benchmark source or simulator
data was changed. Logs, readable xcresults and summaries are under
`/private/tmp/seedkeep-photo-main-checks-20261116/`.

The same unchanged benchmark failed before this cache fix, as preserved below.
Independent native Terra source review found no direct path intersection: the
benchmark maps synthetic seed rows and performs in-memory sorts, without
calling `PhotoByteStore`. High aggregate host load was recorded but does not
prove the failure's cause or exclude every indirect effect. The scoped cache
fix has passing focused regressions and Sel runtime evidence; the full-gate
failure remains open separately as `seedkeep-ios-219`. No overall green gate
or complete R5 acceptance is claimed.

The fixed signed candidate is retained privately at
`.git/seedkeep-agent-patches/2026-11-16-photo-cache-fix/candidate/Seedkeep.app`,
with its inventory, generic patch, redacted receipts, review and validation
summary. Raw device screenshots, accessibility trees, photo copies and private
CloudKit inputs are excluded from that archive and Git.

## Earlier pre-fix main validation and handoff limit (preserved)

The first fresh main gate was interrupted after a chooser-discard test made
no progress for 486.6 seconds; its exact, one-test focused rerun passed in
0.199 seconds. The bounded full-gate retry then failed only the unchanged
1,000-seed mapping/sorting budget: 98 ms against 50 ms. A verified one-test
isolated rerun also failed at 59.132 ms. This is a real validation failure,
not a passing transient result. The yielding 5,000-row case passed.

The full retry reported Kit 25 and CloudKit 176 passed, iOS 1,446 passed /
1 failed / 1 expected skip; it did not reach Mac tests. Its xcresult is
readable; the focused mapping bundle lacks Info.plist, so only its log is
retained evidence. The separately completed signed Mac Debug build and strict
signature verification passed. No app launch or provisioning update occurred
for that build. DD9 was restored to its initial Shutdown state.

Aggregate host load/memory context was retained without a process listing;
it is context, not proof of the timing failure's cause. No performance
threshold, shipping code or simulator data was changed, and no further
performance retries were made. Logs and summaries:
`/private/tmp/seedkeep-ios-6y0-sel-final-checks-20261116/`.
At that pre-fix checkpoint, result documentation remained staged, not
committed, because the required full gate was not passing. Independent Terra/Sol reviews approved the diagnosis
content before this final validation annotation; any later commit must
revalidate its exact frozen patch and required checks. Fix `seedkeep-ios-8ii`
remains separately scoped.

## Evidence and cleanup

Private evidence is under `/private/tmp/seedkeep-photo-diagnosis/` (directory
0700; recovery image 0600): `diagnostic-receipt.md`, targeted redacted proofs,
controlled build receipt, reviews and protected recovery image. Raw identifiers/preferences,
physical captures and image pixels are excluded from Git. Temporary raw
preferences/guard copies were removed after deriving minimal protected input.
The generic helper source is isolated under
`/private/tmp/seedkeep-photo-diagnosis-worktree/.diagnostics/one-photo/`.

In the earlier Roshar read-only phase, the owned runner and verified
diagnostic child stopped without a password; the endpoint refused connection.
Seedkeep returned to Today with the inspected detail retained in its Seeds
stack. No Seedkeep build was installed in that phase. The later Sel install,
normal-build finish, foreground and cleanup are described separately above;
app-only physical captures remain under
`/private/tmp/seedkeep-sel-diagnostic-evidence/`, not in Git. No deliberate
photo-row/authored-byte edit, phone setting change or manual CloudKit mutation
was requested. Normal startup/cache/sync effects remain unmeasured. No
release/push occurred. Native Terra reviewed the bounded evidence receipts.
