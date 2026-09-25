# Current State

## Seasonal-care source qualification — 2026-09-24

The isolated `codex/seasonal-care` worktree contains the approved seasonal-care
foundation and CloudKit source integration: annual-window evaluation with
creation-day first eligibility, SwiftData task/completion models, local mutation
store, additive CloudKit manifest/values/merger/migration/applier/cascade paths,
and full-household reminder reconciliation on `AppEnvironment`.

The earlier host Xcode license blocker is cleared. The count-enforced full gate
passed both packages, 803 CloudKit-OFF app tests and 1 Production-default
CloudKit-ON test; focused seasonal tests passed 21 across 4 suites. Independent
reads confirmed the final serialized OFF/ON result bundles. The companion
`codex/seasonal-care-schema` artifact matches the manifest: 14 record types,
31 added lines and no removals. No live schema import occurred.

Seed Detail and Today include manual/template tasks, editing, annual completion
history and optional reminders. The starter pack contains three clearly labeled
Minnesota templates; manual tasks remain available for other crops/regions.
Independent Terra review found no unresolved material findings in the final
source fixes, test evidence and additive artifact. A second fresh unsigned
Simulator install/launch rendered the signed-out screen at unchanged
`1.0.0 (54)`; the accessibility snapshot timed out. Authenticated seasonal UI,
notification delivery and same-account convergence remain unrun for the later
combined hands-on session. No account bypass or new test infrastructure was added.
This qualifies the bounded source milestone, not parent feature/release
acceptance. See `seasonal-care-source-handoff.md` and
`evidence/2026-09-24-seasonal-care-qualification.md` for evidence and limits.

## Deferred V1 M1 — `seedkeep-27d.33` — 2026-09-10

The user deferred hands-on V1 QA until after the next feature. Keep it for one
later combined session; it is not waived. The canonical V1 checkout remains at
`f3e3c59`; this feature is isolated on `codex/seasonal-care`.

Build `1.0.0 (54)` remains rejected; its archive is retained, counter 54 is unchanged, and repair `b11195f` remains the source input.
RecommendationStore source tests and the newest-first build-55 changelog entry are ready; the existing URLSession injection is used with a suite-local URLProtocol fixture.
Initial full gate, before the final fixture/changelog corrections: SeedkeepKit 97, SeedkeepCloudKit 148, CloudKit-OFF app 769, Production-default CloudKit-ON 1.
Final focused gates after those corrections: RecommendationStore 5/5 and ChangelogData 3/3; no final full-gate rerun is claimed.
Authenticated iPad retry QA exercised both real Retry controls; Production asset sends were attempted but existing-record conflicts prevent fresh upload acceptance. Original synced-state was restored and the roster is empty. A fresh supported Add Photo check reached the native picker; the native screenshot shows the synthetic barcode as the first tile, but picker AX interaction is unavailable, so no fresh photo acknowledgment exists. A synthetic scalar Seed save received Production `savedRecords` acknowledgement, with no second-receiver convergence proof.
Remaining live gates: on iPad, select the first synthetic barcode tile in the visible PhotosPicker, then complete Add photo; on Roshar, scan the prepared online barcode with Camera, record raw detection and catalog hit, save, set local ZIP, and inspect live planting guidance.
Evidence: `.docs/ai/evidence/2026-09-10-m1-native-v1.md` and `2026-09-10-m1-live-retry-log.txt`; barcode card: `2026-09-10-m1-online-barcode-card.html`; approved spec: umbrella `.docs/ai/phases/2026-09-10-v1-successor-release-plan.md`; Bead: `seedkeep-27d.33`.
M2/build-55 archive, upload, and external release actions remain inactive.
