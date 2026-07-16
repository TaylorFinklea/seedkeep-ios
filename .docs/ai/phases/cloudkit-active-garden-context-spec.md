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
