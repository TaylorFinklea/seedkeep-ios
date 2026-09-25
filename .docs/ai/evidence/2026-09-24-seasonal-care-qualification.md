# Seasonal-care qualification — 2026-09-24

Scope: `seedkeep-p49.1`, isolated branch `codex/seasonal-care`, source checkpoint
`e5dedcf` plus the reviewed qualification fixes. Canonical V1 remains at
`f3e3c59`; build 54 is unchanged and rejected.

The host's earlier Xcode license blocker is cleared. The fresh compiler probe
exited 0 with Apple Swift 6.4; no agent accepted or bypassed the license.
Testing uses the newly created iPhone 17 Pro simulator
`5F9A1AF0-4405-4387-8D02-F70D5B6DBCD3` (`Seedkeep Seasonal Care QA 20260924-2`),
iOS 27. Existing signed-in simulators and physical devices were not used.

## Results

| Check | Evidence |
| --- | --- |
| Focused seasonal app tests | Worker reports 21 passed across 4 suites using the existing nonzero-count wrapper. The full app run also covers the top-level annual-window tests. |
| Full `scripts/test-gate.sh` | Luna reports a successful rerun, including both count-enforced package stages, 803 CloudKit-OFF app tests, and 1 Production-default CloudKit-ON test. Exact package counts were not retained. |
| Clean serialized CloudKit-OFF confirmation | Bundle independently read by the lead and Terra: **803 passed, 0 failed, 0 skipped**, result `Passed`. |
| Clean serialized CloudKit-ON confirmation | Bundle independently read by the lead and Terra: **1 passed, 0 failed, 0 skipped**, result `Passed`. |
| Additive schema generation/parity | `scripts/cloudkit-schema write` and `check` passed in the companion worktree against the feature iOS source. 14 record types; 31 added lines, no removals. |
| Isolated simulator smoke | Reused tested unsigned app; install and launch succeeded on a second fresh simulator. Signed-out screen captured and visually inspected. Accessibility snapshot timed out. Authenticated seasonal flows unrun. |

Qualification fixes restore the ordinary evaluator's optional first-year
parameter and require explicit eligibility context before selecting a previous
ordinary occurrence. Pure notification-identifier helpers are nonisolated.
Test-only fixes correct imports, multiline JSON/expected ordering, copied-ID
SwiftData predicates, fixture dates, actor-safe snapshots, and timezone checks.
The behavioral assertions are retained. Terra reviewed the final six-file
delta, OFF/ON result bundles and additive schema without material findings.
The app test run includes annual boundaries, next-incomplete evaluation,
reminders, store mutations, templates and CloudKit parent handling.

## Evidence and rerun history

All bundles below are in
`/Users/tfinklea/Library/Developer/Xcode/DerivedData/Seedkeep-gdmbqandxfthrpecyczloowygyha/Logs/Test/`.

- Focused: `Test-Seedkeep-2026.09.24_22-11-28--0500.xcresult`.
- First full gate: `Test-Seedkeep-2026.09.24_22-12-44--0500.xcresult`;
  failed `ordinaryBoundaries()` (802 passed, 1 failed), then repaired.
- Full-gate rerun OFF: `Test-Seedkeep-2026.09.24_22-15-53--0500.xcresult`.
- Full-gate rerun ON: `Test-Seedkeep-2026.09.24_22-16-40--0500.xcresult`.
- Clean serialized OFF: `Test-Seedkeep-2026.09.24_22-18-14--0500.xcresult`.
- Clean serialized ON: `Test-Seedkeep-2026.09.24_22-23-05--0500.xcresult`.

An owned focused wrapper remained alive after its reported success and
overlapped later work. The worker identified and stopped only its owned PIDs
61905/61913. The standalone serialized confirmations remove ambiguity from
that overlap. A malformed ON confirmation passed `SEEDKEEP_TEST_CLOUDKIT_ON`
as a separate action and exited before running tests; it is not a test pass.

The full-gate invocation was `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/test-gate.sh --simulator-udid 5F9A1AF0-4405-4387-8D02-F70D5B6DBCD3`.
Standalone confirmations used `scripts/require-nonzero-tests.sh` around
`xcodebuild test`, the same simulator, `-parallel-testing-enabled NO`,
`CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`. OFF skipped
`SeedkeepTests/ProductionDefaultCloudKitGateTests`; ON selected only that suite
and passed the quoted single argument
`'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG SEEDKEEP_TEST_CLOUDKIT_ON'`.

## Additive schema artifact

Companion: `/Users/tfinklea/git/seedkeep-seasonal-care-schema`, branch
`codex/seasonal-care-schema`. Both `./scripts/cloudkit-schema write --ios-root
/Users/tfinklea/git/seedkeep-ios-seasonal-care` and the corresponding `check`
succeeded. Artifact `.docs/ai/cloudkit/seedkeep-schema.ckdb` SHA-256:
`eb4d130517a25761353f6966d67470292ae7275aebf0370d08f5063029922873`.
The two added records are `SeasonalCareTask` and `SeasonalCareCompletion`;
their fields and references match the manifest/model builders. Future live
application must preserve the container's system types and merge additively;
this app-manifest artifact is not a full-container replacement.

## Isolated launch smoke

Luna applied the `ios-debugger-agent` skill and used XcodeBuildMCP to install,
launch, capture and stop the tested app on newly created simulator
`A0BB7BC5-D8BD-43FF-A1BD-3F6DF11A656A` (`Seedkeep Seasonal Care Smoke 20260924-1`,
iPhone 17 Pro, iOS 27). The simulator was shut down afterward. No rebuild was
needed. Artifact:
`/Users/tfinklea/Library/Developer/Xcode/DerivedData/Seedkeep-gdmbqandxfthrpecyczloowygyha/Build/Products/Debug-iphonesimulator/Seedkeep.app`.
Metadata: `app.seedkeep.ios`, version `1.0.0`, build `54`.

Screenshot `2026-09-24-seasonal-care-smoke-signed-out.jpg` was visually inspected
by Luna and the lead: Seedkeep branding and Sign in with Apple render. The
accessibility snapshot timed out, so no accessibility smoke pass is claimed.
Screenshot SHA-256: `2c25dc54142a0b85bbb1e055149a8c8b790450f558fb6bc4ab337650a348cfc3`.
No sign-in or synthetic-auth operation was performed. The root requires signed-in
auth and an active household to reach seasonal screens; no existing account-free
UI host was found. Seasonal interactive CRUD, reminders, UI relaunch persistence
and cross-device convergence remain explicit unrun checks for the later session.

No signing, archive, build-number change, upload, push, merge, live schema
mutation, authenticated account change, or physical-device QA is included.
Production schema deployment, same-account convergence, and the deferred V1
hands-on checks remain separate acceptance gates.
