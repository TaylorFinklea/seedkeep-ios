# CloudKit Active Garden Context

## Goal

- One authoritative active-garden household ID for local household data.
- Shared participant: derive the owner's logical household ID from the adopted CKShare zone.
- Owner or CloudKit rollback: retain the signed-in server household ID.

## Scope

- Route all household-scoped local creates, edits, queries, notifications, and post-sync pet/weather work through the active-garden ID.
- Audit every `auth.state` household consumer; keep account, authentication, subscription, invite, and server-personal operations on the signed-in household where appropriate.
- Preserve the participant's parked solo records and prevent newly written shared records from being filtered out of CloudKit export.
- Add discriminating tests where participant and signed-in household IDs differ, plus owner and rollback coverage.

## Boundaries

- Work in place on the current `main` checkout; this repo's direct-to-main convention applies and no separate worktree is required.
- Do not implement the separate Postgres pending-write cutover, Sprout/MCP gating, or shared-photo product policy beads.
- Follow existing view and sync construction patterns after reading each touched call site; avoid unrelated refactors.

## Acceptance

- Shared-garden local rows are stamped with the owner-zone household ID and selected for upload.
- Existing parked solo rows remain untouched.
- Owner mode and feature-flag rollback use the signed-in household ID.
- Post-sync household work uses the same active context.
- The full iOS test suite passes.

## Review correction after `b0c2eee` (locked)

- Revert every `SyncEngine.swift` pending-write suppression from `b0c2eee`; `seedkeep-27d.2` owns that cutover and its pre-cutover queue policy.
- Restore the adopted wipe-and-rehydrate semantics in the 2026-06-29 product ADR: adopt wipes local household rows before the shared fetch; leave wipes shared local rows and rehydrates the parked solo CloudKit zone. Do not introduce simultaneous local gardens.
- Restore the legacy `AddSeedView` flush call; data-plane dispatch belongs to `seedkeep-27d.2` and per-mutation triggers to `seedkeep-27d.5`.
- Retain the active-ID resolver, owner/participant/rollback tests, queue-backed create call sites, active garden/library/picker routing, weather routing, and pet tick routing.
- Ensure locations/tags can only list, count, rename, and delete rows in the active garden.
- Ensure the weekly pet roundup counts only the active household.
- Do not change journal/checklist transport here; the newly discovered direct-server dual writer is split into P0 `seedkeep-27d.17`, which depends on this context.
- Do not implement photo, Sprout/MCP, save-trigger, or pending-write policy work.
