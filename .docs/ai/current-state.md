# Current State

## Branch

`main` (TestFlight 0.4.0 build 52 uploaded; processing/installability pending).

## Plan

- [x] `seedkeep-27d.13/.19` hardened after Opus 5 adversarial review: send/fetch-symmetric projection rollback, disk-backed owner/participant relaunch tests, structural engine-generation isolation (`7072ee3`, `979acda`). Sol re-review CLEAN. Strict package 79 + full gate 70 kit / 79 CloudKit / 476 app / 1 production-default green.
- [x] `seedkeep-27d.12` Task 2 CloudKit graph digest/copier (`4f6acb4`, fail-closed review fixes `1feb00e`): expected-zone canonical SHA-256 + counts, unknown app data rejected, exact Date encoding, deterministic parent-first copy, enforced `.allKeys` batch saver. Sol re-review CLEAN. Fresh full gate: 70 kit / 138 CloudKit / 476 app / 1 production-default.
- [x] `seedkeep-27d.12` Task 3 typed transfer client + durable checkpoint (`4e64bfa`, review fixes `1ecc54f` + `7e62d6c`): strict DELETE disposition, successor/crash-window phases, atomic rename, fail-closed validation, opaque one-use lease CAS. Sol final review CLEAN. Fresh full gate: 89 kit / 138 CloudKit / 512 app / 1 production-default.
- [x] `seedkeep-27d.12` Task 4 role-specific deletion coordinator (`7b808d2`, hardening `0becac8`, `9b2a161`, `9cbc617`): source-deletion lease, source/destination digest equality, callback failure propagation, receipt-based sessionless recovery, real CloudKit role inspection, coordinator-routed YouView. Sol final re-review CLEAN. Fresh full gate: 96 kit / 138 CloudKit / 601 app / 1 production-default.
- [x] `seedkeep-27d.12` Task 5 successor handoff + truthful UI (`254f2f2`, hardening `5c42ec3`, `95db285`, `61780f1`, `72368e5`, `242ddb0`): authenticated link deferral, inspect-before-accept, durable successor resume/cutover, cancellation fence, exact-household restore, truthful phase copy, YouView coordinator-only deletion. Sol final re-review CLEAN. Fresh full gate: 97 kit / 138 CloudKit / 685 app / 1 production-default.
- [x] Task 6 rollout deployed: `seedkeep.app` AASA origin authorizes `/garden-handoff/*`; live fallback preserves the HTTPS URL, renders the exact `seedkeep://` deep link, and hides token text; matching server contract is live; build 52 uploaded. Full gate: 97 Kit / 138 CloudKit / 689 app / 1 production-default.
- [ ] Next: confirm build-52 processing/installability, run authenticated disposable-account smoke, then participant/solo-owner/two-account Production gates in `.docs/ai/device-verify.md`.

## Blockers

- Apple CDN AASA gate passed. Remaining gates require App Store Connect/TestFlight and physical devices with disposable Apple IDs.

## Open questions

- None.
