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

## Prepared next read and review boundary

A temporary headless Mac helper is built and signed using the existing exact
Seedkeep bundle/profile. It does not install or replace the owner's app. It
first compares the Mac CloudKit user hash with the privately derived phone
identity, then fetches only the original photo record from its owner/private
zone. It reports asset presence/readability, byte counts, hash agreement and
image decoding without printing identifiers or pixels. There are no explicit
SwiftData, defaults, Keychain, sync-engine or CloudKit mutation calls. Execution
can create OS-managed sandbox/CloudKit cache and temporary-download metadata.

The pinned launcher checks artifact hashes/signature, runs the exact executable
once with a 120-second deadline, and treats errors, identity mismatch,
incomplete output and timeout as inconclusive. Its completed classification
means only that a record callback was observed; a record-type mismatch must
still be interpreted as inconclusive for diagnosis. Callback completion alone
does not establish image integrity. Source-to-binary provenance and exact private
input were independently checked.

Separate native Terra and exact read-only Sol reviews approved this helper and
launcher. The sole DeepSeek dispatch timed out at 600 seconds with no nonempty
final verdict. That review is incomplete; no retry/fallback occurred. The owner
has been asked for a narrow exception to run this one read using the completed
reviews. **Neither helper nor launcher has run.** No CloudKit state/cause or
upgrade regression is established.

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
