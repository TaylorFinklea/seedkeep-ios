# Current State

## Branch

`main` (TestFlight 0.4.0 build 51; schema-generator repair pending commit).

## Plan

- [x] `seedkeep-27d.13`: Swift 6 CloudKit isolation (`27a294d`); strict warnings-as-errors package gate green.
- [x] `seedkeep-27d.19`: await SwiftData projection before durable CKSyncEngine checkpoint (`1f694d6`); full `test-gate.sh` green.
- [ ] `seedkeep-27d.12`: implement approved cross-repo resumable deletion transfer; spec/plan in umbrella `phases/2026-07-23-cloudkit-account-deletion-{spec,plan}.md`.

## Blockers

- Continue the remaining build-51 device checklist before App Store submission.

## Open questions

- None.
