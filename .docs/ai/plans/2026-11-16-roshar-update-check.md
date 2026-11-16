# Roshar in-place update — 2026-11-16

## Scope and authority

The owner approved the exact prepared app/WDA test, waived the recent-backup
prerequisite, and separately approved continuing if the old app could not
provide a garden baseline. Roshar was the final explicit device target. Sel's
earlier automation attempt remained stopped. No reset, uninstall, garden edit,
account switch, photo picker, invitation or release was authorized/performed.
Normal application startup/sync could mutate data; no claim of a write-free
launch is made.

## Input and installation

Native input HEAD `199e47c19fc8ab8c9fd4bc090d0da6c5aa19a3a0`, application
source/config unchanged since `63b5709`, bundle `app.seedkeep.ios`, 1.0.0 (54),
Team `K7CBQW6MPG`, CDHash `21d85b63af83c622026c1a0a91dc1b6eb04d1d53`.
All 20 preserved input hashes/sizes and strict signature/profile checks passed;
the existing profile included Roshar. Signed CloudKit environment was
Production, container `iCloud.app.seedkeep`. Build 54 was reused; the old
installed source is unknown.

CoreDevice accepted that preserved candidate **in place** (exit 0). This binds
the verified installation input/receipt; the installed runtime binary was not
independently extracted and hashed. The old app was observed only at its
Apple sign-in timeout, without a garden; no sign-in action was taken.

## Observed outcome

- New startup opened Today/Garden without sign-in, recovery or choice UI.
- Two beds, two active seeds and sampled record/planting details were visible.
  The same samples remained after one controlled terminate/relaunch, with no
  unsaved workflow observed. This is a post-update/relaunch comparison only.
- Settings displayed initial upload complete and a current, later-advancing
  Last CloudKit sync value. Its diagnostics branch requires the source's
  current-session identity/guard gate; cached garden visibility or account
  status available alone would not establish that inference. Old-account
  equality and the literal identity were not independently compared.
- The displayed records-synced label read 11 then 3. Source defines this as
  `engine.store.count()`; it is not an acknowledged transfer count or proof
  of lost rows. The upload flag is durable migration state, not a complete
  remote round-trip.
- One existing photo tile resolved from a spinner to the fallback glyph.
  The image was unavailable; bytes and cause remain unknown. No photo retry,
  delete, picker or upload was attempted. Follow-up: `seedkeep-ios-6y0`.

## Runner and evidence

The WDA input/execution copy matched 203 preserved entries including modes
and symlinks. Initial sandbox execution failed on destination/log access;
the same artifact/command succeeded with host access. Runtime was iOS 27.2.1.
The owned runner and verified diagnostic child exited after the test. A
terminal Password prompt was left blank; no credential was entered. Fresh
connected-tunnel status refused connection. Seedkeep and WDA remain installed;
no further device activity is required for this receipt.

Private working evidence: `/private/tmp/seedkeep-roshar-20261116/evidence/`,
including `receipt.md`, artifact/install/metadata/runner/cleanup receipts,
app-only readbacks/captures and `wda-runner.xcresult`. Raw physical captures
stay task-temporary and are not committed or copied into the Git worktree.
Only redacted receipts/review/check summaries may be preserved in the native
private archive `.git/seedkeep-agent-patches/2026-11-16-roshar/`.

## Acceptance limits

No pre-upgrade comparison, complete row/photo preservation, precise old-source
migration, old-account equality or independent receiving-device round-trip is
established. The photo is unresolved. Minimum-26 runtime, all 345 historical
audit reports, deferred VoiceOver/manual checks, live throwaway-garden guard
cases and distribution/release approvals remain separate. R5 is not complete.
No shipping source/configuration changed and nothing was pushed or released.
Tracking: umbrella `seedkeep-30f.5`, native handoff `seedkeep-ios-ezm`.
