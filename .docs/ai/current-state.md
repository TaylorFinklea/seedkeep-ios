# Current State

## Branch

`main` (TestFlight 0.4.0 build 51; schema-generator repair pending commit).

## Plan

None active. Build 51 device pass found Production CloudKit missing `PlantingEvent`: the generated `.ckdb` omitted the required `DEFINE SCHEMA` wrapper and could never be imported. Generator fixed test-first; full SeedkeepCloudKit suite green. User imported an additive merge preserving `Users`, `cloudkit.share`, and legacy `ShareHandoff`, deployed to Production, and confirmed sync works.

## Blockers

- Continue the remaining build-51 device checklist before App Store submission.

## Open questions

- None.
