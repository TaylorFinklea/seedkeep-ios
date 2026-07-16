# CloudKit Active Garden Context Report

## Result

- Participant writes and active garden views now use the adopted owner's zone-derived household ID.
- Owner and CloudKit rollback paths retain the signed-in server household ID.
- Weather, pet ticks, and weekly pet roundup use the same active context.
- Partial participant markers cannot redirect household work.

## Boundaries Preserved

- `SyncEngine` pending-write behavior is unchanged; `seedkeep-27d.2` owns the cutover.
- Adopt/leave still wipe and rehydrate local household data per the 2026-06-29 ADR.
- Journal/checklist transport remains for `seedkeep-27d.17`; historical row recovery remains for `seedkeep-27d.18`.

## Verification

- Full iOS suite: 405 tests in 48 suites passed on 2026-07-15.
- `git diff --check` passed.
