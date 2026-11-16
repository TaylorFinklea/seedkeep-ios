# Existing photo loading diagnosis — 2026-11-16

The owner requested diagnosis of the existing unavailable photo after the
Roshar update check. This does not establish that the update caused it.
Tracking: `seedkeep-ios-6y0`. The task remains open; no repair is claimed.

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

## Prepared device capture — no Seedkeep installation or trace yet

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

The device QA skill permits one retry only after the owner confirms Sel is
unlocked and Settings → Developer → Enable UI Automation is ready. That
confirmation is pending. No further SDK attempt or Seedkeep install is
authorized by this checkpoint. First resolve automation and Sel's baseline;
do not silently treat installing the normal candidate as restoration of a
proven prior Sel build. The selected photo's exact failing phone stage remains
unresolved.

## Evidence and cleanup

Private evidence is under `/private/tmp/seedkeep-photo-diagnosis/` (directory
0700; recovery image 0600): `diagnostic-receipt.md`, targeted redacted proofs,
controlled build receipt, reviews and protected recovery image. Raw identifiers/preferences,
physical captures and image pixels are excluded from Git. Temporary raw
preferences/guard copies were removed after deriving minimal protected input.
The generic helper source is isolated under
`/private/tmp/seedkeep-photo-diagnosis-worktree/.diagnostics/one-photo/`.

The owned device runner and verified diagnostic child stopped; no password was
entered and the fresh endpoint refused connection. Seedkeep returned to Today;
its Seeds navigation stack retains the inspected detail. The diagnostic did
not edit photo rows or authored bytes, change phone settings, install a build,
or request CloudKit mutations. No release/push occurred. Native Terra approved the redacted factual receipt.
