# Device Verification Checklist

TestFlight builds that introduce destructive CloudKit operations, universal-link-dependent flows, or user-facing compliance features (Apple 5.1.1(v) account deletion) MUST be device-verified on Production CloudKit with real Apple IDs before App Store submission.

---

## Build 52 — Account Deletion + Transfer (2026-07-25)

**Target:** 0.4.0 (52)  
**Features:** Resumable account deletion with shared-owner transfer-by-copy, universal link handoff, CloudKit zone/share destruction.

### Hard Prerequisites

These MUST be satisfied before ANY device gate is attempted:

- [x] **Web/AASA deployed and propagated**
  - [x] `seedkeep-ios/web` built and deployed to Cloudflare Workers Static Assets (`seedkeep-web`, custom domain `seedkeep.app`)
  - [x] AASA origin verified: `200 OK`, `content-type: application/json`, `/garden-handoff/*` present
  - [x] Apple CDN propagation confirmed: `/garden-handoff/*` present in the cached AASA
  - [x] Propagation gate satisfied by direct Apple CDN verification on 2026-07-26

- [x] **Server deployed and smoke-tested**
  - [x] `seedkeep-server` deployed via `./scripts/deploy.sh`; migrations 0024–0029 applied by release command
  - [x] Health check green: `https://seedkeep-server.fly.dev/api/health` reports healthy, current worker tick, fresh backup
  - [x] Authenticated `DELETE /api/me` passed through build 52 on a disposable participant account
  - [x] `GARDEN_TOOLS_ENABLED` absent from Production secrets (expected fail-closed default; Sprout/MCP disabled)

- [x] **iOS build processed**
  - [x] Build 52 uploaded to TestFlight
  - [x] Processing complete in App Store Connect
  - [x] Build installable on test devices

### Production CloudKit Gates

All gates use **Production CloudKit environment** with **disposable test accounts only**. Never use real user data for destructive verification.

#### Gate 1: Participant Deletion

- [x] Sign in to a shared garden as a **participant** (not owner)
- [x] Tap **You → Delete Account**
- [x] Observe phase: "Leaving shared garden"
- [x] Deletion completes
- [x] **Verify CloudKit**: fresh sign-in shows no share
- [x] **Verify server**: deleted account does not persist
- [x] **Verify local**: cold relaunch shows no prior household data

#### Gate 2: Solo Owner Deletion

- [x] Sign in to a garden with **no participants** (solo owner)
- [x] Tap **You → Delete Account**
- [x] Observe phase: "Deleting garden zone"
- [x] Deletion completes
- [x] **Verify CloudKit**: immediate fresh sign-in has no prior garden/seed
- [x] **Verify server**: immediate fresh sign-in recreates the deleted account
- [x] **Verify local**: throwaway seed does not return

#### Gate 3: Two-Account Shared-Owner Transfer

**Requires:** Two physical devices, two different iCloud accounts with Production CloudKit access, one shared garden with an accepted CKShare participant.

##### Owner (Departing) Side:
- [ ] Owner signs in on Device A
- [ ] Tap **You → Delete Account**
- [ ] Flow recognizes shared ownership → "Transfer your garden first"
- [ ] Tap **Transfer Garden**
- [ ] Select successor from participants list
- [ ] Tap **Create Handoff Link**
- [ ] **Share link via Messages or AirDrop** (exercises real universal link, not manual paste)

##### Successor (Receiving) Side:
- [ ] Successor taps the received link on Device B
- [ ] **CRITICAL**: App MUST open (not Safari). If Safari opens, STOP — AASA not propagated or invalid.
- [ ] "Inspect Handoff" sheet appears with garden preview
- [ ] Tap **Accept Handoff**
- [ ] Observe phase: "Creating destination"
- [ ] Observe phase: "Copying garden"
- [ ] Observe phase: "Verifying copy"
- [ ] Both digests match (green checkmark)
- [ ] Successor now owns the garden

##### Owner Completion:
- [ ] Return to Device A
- [ ] Owner observes "Successor accepted" → "Delete Source"
- [ ] Tap **Delete Source**
- [ ] Observe: "Deleting source zone"
- [ ] Observe: "Deleting account"
- [ ] Deletion completes
- [ ] **Verify CloudKit (owner)**: Original zone deleted, account deleted
- [ ] **Verify CloudKit (successor)**: New zone exists, successor is owner, all records present
- [ ] **Verify successor continuity**: Successor can add/edit entries, sync works independently

### Rollback Conditions

- **Gate 1 or 2 fails**: Do NOT proceed to Gate 3. File issue, debug, fix, recut build.
- **Gate 3 handoff link opens Safari instead of app**: AASA not propagated. Wait longer or verify CDN cache.
- **Gate 3 digest mismatch or copy failure**: Server/CloudKit/copier bug. Do NOT ship.
- **Any gate leaves orphaned data**: Account deletion contract violated. Blocking.

### Post-Verification

- [ ] Update `.docs/ai/current-state.md` with build 52 gate results
- [ ] Update umbrella `seedkeep/.docs/ai/phases/2026-07-23-cloudkit-account-deletion-plan.md` Task 6 checklist
- [ ] Close `seedkeep-27d.12` bead only after all three gates pass

---

## Build 51 — What's New UI (2026-07-21)

**Target:** 0.4.0 (51)  
**Features:** Changelog sheet, Settings → What's New drill-down.

- [x] Fresh install shows "What's New" on first launch
- [x] Changelog entry for build 51 appears
- [x] Settings → What's New shows history
- [x] Unseen dot badge works correctly
