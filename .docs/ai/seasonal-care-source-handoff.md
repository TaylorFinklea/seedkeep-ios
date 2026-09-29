# Seasonal-care source handoff

## Current handoff — 2026-09-29

Canonical status and the ordered combined QA procedure live in the umbrella
checkout: `/Users/tfinklea/git/seedkeep/.docs/ai/current-state.md` and
`/Users/tfinklea/git/seedkeep/.docs/ai/phases/2026-09-29-combined-qa-session.md`.
No new hands-on result was reported after the source qualification below. The
isolated source remains `3e62f2e`; its additive schema companion remains
`d936cff`.

`seedkeep-p49.1` source qualification and `seedkeep-p49.2` QA preparation are
closed; parent `seedkeep-p49` remains open. V1 `seedkeep-27d.33` and the
historical build-54 `seedkeep-27d.32` remain open, with build 54 rejected and
its counter unchanged. Run the approved V1 checks first. Before any seasonal
record write, establish the supported isolated same-account QA household/store
and obtain the separate schema/import and exact signed-install approvals; if
that isolation is unavailable, defer care writes until V1 acceptance. No live
schema deployment, signing/install, build increment, archive, upload or merge
has been run or approved by this handoff refresh. The user authorized scoped
documentation/Beads commits and branch pushes; verified publication and remote
readback are recorded in the canonical
`/Users/tfinklea/git/seedkeep/.docs/ai/phases/2026-09-29-session-handoff.md`.

The qualification record below is historical evidence from 2026-09-24 and is
preserved unchanged.

## Historical qualification record — 2026-09-24

Date: 2026-09-24
Worktree: `seedkeep-ios-seasonal-care`, branch `codex/seasonal-care`
Base: `f3e3c59`; source-qualification tracker: umbrella `seedkeep-p49.1`.
Parent `seedkeep-p49` retains live schema and device acceptance.
Companion schema worktree: `seedkeep-seasonal-care-schema`, branch
`codex/seasonal-care-schema`, base `e272a9c`.

The source changes implement the approved seasonal-care foundation and
CloudKit mapping. Public contracts are:

- `AnnualCareWindow` derives first eligibility from a creation date in the
  supplied calendar/time zone; `AnnualCareState` and `AnnualCareEvaluation`
  preserve overdue occurrences until the next annual start. Its separate
  `nextIncompleteEvaluation` path advances past completed years for Today and
  reminders while Seed Detail retains current-year completion state.
- `SeasonalCareTaskDraft`, `SeasonalCareAttributionSnapshot`,
  `SeasonalCareStore`, `LocalSeasonalCareTask`, and
  `LocalSeasonalCareCompletion` provide validated local mutations with stable
  `taskID:gardenYear` completion identity.
- `AppEnvironment.seasonalCare` is the mutation store,
  `seasonalCareTemplates` is the template repository, and
  `seasonalCareReminders` is the reminder reconciler.
- A missing or invalid bundled template pack is retained as a typed repository
  failure, allowing the UI unavailable-pack state to render instead of
  silently returning no templates.
- `AppEnvironment.reconcileSeasonalCareReminders(allowAuthorizationRequest:)`
  collects all active household tasks and schedules one full-household diff;
  passive callers use the default `false`, while an explicit enable may pass
  `true`. Local store commits, successful sync/remote projection, foreground
  sync, calendar-day changes, time-zone changes, and sign-out are wired to the
  same reconciler lifecycle.
- Date-based projections observe `seasonalCareEvaluationDate`; AppEnvironment
  refreshes it before foreground sync and on calendar-day/time-zone notifications.

Seed Detail supports manual tasks, adding and editing attributed template
snapshots, completion, deletion, and per-task reminder preferences. Today shows
Due, Overdue and Upcoming work; completed history remains associated with its
task and garden year. The bundled starter pack has three Minnesota-specific
UMN Extension templates, with visible applicability labels. It is intentionally
limited; manual creation is available for other crops and regions.

CloudKit source paths add both record types, additive schema fields and refs,
record-value adapters, merge dispatch, migration ordering/export filtering,
remote projection, LWW/hard-delete identity handling, seed/task tombstone
cascade cleanup, and schema registration. Valid orphan children are retained
locally for later parent arrival and excluded from export until their active
parent exists; malformed ref types are ignored.

Qualification resumed after the host's Xcode license blocker cleared; no agent
accepted or bypassed the license. Focused seasonal tests passed 21 across 4
suites. The existing count-enforced full gate passed both packages, 803
CloudKit-OFF app tests and 1 Production-default CloudKit-ON test. Final clean
serialized OFF/ON bundles were independently inspected by the lead and Terra.
The companion schema artifact was generated and checked against this source:
14 record types, 31 added lines, no removals. Existing V1 records are preserved.

Independent Terra review found no unresolved material findings in the final
source delta, test evidence and additive schema. Repairs covered annual creation/rollover boundaries,
completion identity and parent/cascade isolation, full-household reminder
reconciliation and cancellation races, pack validation/error presentation,
completed-task controls/history, and observable day/timezone updates.
An unsigned install/launch on a second fresh iPhone 17 Pro simulator rendered
the signed-out entry screen; screenshot inspected, accessibility snapshot timed
out. Artifact identity remains `app.seedkeep.ios`, `1.0.0 (54)`. There is no
existing account-free route to seasonal screens, so authenticated CRUD,
notification delivery, relaunch persistence through UI and device convergence
remain unrun. No shipping authentication switch or new host infrastructure was
added. Detailed commands, result bundles, rerun history and screenshot:
`evidence/2026-09-24-seasonal-care-qualification.md`.

The canonical iOS V1 checkout, umbrella schema artifact and CI schema pin remain
unchanged. No signing, live schema mutation, production change, build increment,
archive, upload, push or merge occurred. Production schema deployment and
physical convergence need their later explicit authorization and evidence.

Later combined hands-on QA should cover care add/edit/complete/delete and
relaunch, notification denial/retry and next-year scheduling, date/timezone
boundaries, plus the deferred V1 retry/recommendation flows. Same-account care
convergence requires a qualified care-capable build and deployed schema.
Build 54 remains rejected; its older graph-transfer/digest code fails closed on
unknown care record types and cannot qualify a care-bearing household transfer.
