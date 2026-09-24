# Seasonal-care source handoff

Date: 2026-09-24
Worktree: `seedkeep-ios-seasonal-care`, branch `codex/seasonal-care`
Base: `f3e3c59`; tracker: umbrella `seedkeep-p49.1` (still open).
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

Validation evidence is limited to `git diff --check`, template JSON structural
validation, targeted static scans and source inspection. New Swift tests are
written but have not executed.
Swift package/Xcode tests and schema generation were attempted but blocked at
the Xcode license check (exit 69). No license acceptance or bypass was attempted.
No simulator/device QA, live CloudKit schema mutation, production change,
build increment, archive, upload, push or merge was performed.

Independent Terra source review found no unresolved material findings in the
final frozen diff. Repairs covered annual creation/rollover boundaries,
completion identity and parent/cascade isolation, full-household reminder
reconciliation and cancellation races, pack validation/error presentation,
completed-task controls/history, and observable day/timezone updates.
This source-only conclusion does not qualify the implementation without the
unrun compiler, test, simulator and schema checks.

Qualification must resume with focused tests, the existing count-enforced full
test gate, additive schema generation/parity in the companion worktree, and an
isolated simulator smoke. The canonical umbrella schema artifact and CI schema
pin remain unchanged. Production schema deployment and physical convergence
need their later explicit authorization and evidence. Source review cannot
substitute for any of these checks.

Later combined hands-on QA should cover care add/edit/complete/delete and
relaunch, notification denial/retry and next-year scheduling, date/timezone
boundaries, plus the deferred V1 retry/recommendation flows. Same-account care
convergence requires a qualified care-capable build and deployed schema.
Build 54 remains rejected; its older graph-transfer/digest code fails closed on
unknown care record types and cannot qualify a care-bearing household transfer.
