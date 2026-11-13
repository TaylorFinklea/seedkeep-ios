# Native release readiness — 2026-11-13

## Scope and source

This is a local evidence checklist for iOS, iPadOS and native macOS. It does
not select a release build or authorize a device install, live CloudKit
mutation, public website change, push, archive/upload or App Store action.
Application source at the start of this pass: `63b5709` on
`redesign/r2-design-system`. `project.yml` still declares 1.0.0 (54), with
an iOS/macOS 26.0 floor. A signed Debug build is not a distribution archive.

## Local evidence

| Item | Status | Evidence and limits |
| --- | --- | --- |
| Deleted-garden guard implementation | Verified locally | G1 `a5add72`, G2 `c239d06`, G3 `cf64db0`; N2-E contract Results and accepted residual limits. Live deletion/Keep/Discard/stop-sharing is still open. |
| Main source gate and signed Mac build | Passed final full retry / signing | Kit 25; CloudKit 176; iOS 1,447 passed plus one expected fixture-generator skip; Mac 1,462 plus the same skip. A sole iOS 50 ms mapping/sort check failed at 58.55 ms, then passed in isolation and on one full retry; the zero-test selector attempt was discarded. Both final 5,000-row cases passed. No app or threshold changed; signed Debug build/strict deep codesign passed. |
| Mac routes, inline counts, grid activation/focus | Verified for recorded sample cases | `2c17004`, `52acc84`, `63b5709`; R5 Results distinguish keyboard, AX and pointer checks. |
| Bed / square-detail large-text checks | Passed two cases | Default and Accessibility XXXL normal rendering, without an audit call. The heading, sample event, Sugar Snap detail label, notes field and final action were wholly inside the measured viewport after scrolling. These samples do not map or resolve individual historical audit reports. |
| Add Seed large-text checks | Passed two focused cases after helper correction | The owner approved a separate native Terra agent. The helper now matches the Notes header case-insensitively and selects the actual TextField. Both default/XXXL tests pass full-frame/isHittable checks and Cancel/form dismissal. XXXL State/Location/Source read back Wishlist/Garage shelf/Self-saved. Earlier helper failures remain recorded; no product defect or historical audit-report resolution is claimed. |
| Mac initial window / focused keyboard | Verified sample cases | Two current signed fixture launches had one main window at first observation and through 10 seconds, without New Window recovery. After Cmd+F, Tab and Shift+Tab, fresh AX focus readbacks were TextField → Outline → TextField; the final capture shows the search caret. The outline was not independently identified in the log. Keyboard navigation stayed 0. Full application Tab order and normal owner-account startup remain open. |
| Accessibility audit acceptance | Open | 345 historical unresolved reports, including repeated checkpoint reports; no blanket suppression. Original raw November 5 bundle/tally paths are now absent, preventing fresh per-element comparison. Retained plan/curated diagnostics preserve aggregate results and limits. |
| Local CloudKit schema parity | Passed offline | `scripts/cloudkit-schema check --ios-root /Users/tfinklea/git/seedkeep-ios` matched the checked-in artifact to the current code manifest. This does not establish Production schema deployment or every runtime/legacy field. |
| VoiceOver speech/read order | Deferred by owner | Existing AX/capture harness does not verify actual spoken output. |
| Release command safety checks | Verified local dry run and synthetic tests | `release.sh --plan-version` proposes 1.0.0 (54) → 1.0.0 (55); no bump or credential lookup. Five existing fake-auth/archive/version tests passed. Real export/upload/auth and the Mac release path were not exercised. |

## Provenance and limits

This pass ran on the existing DD9 simulator (iOS 27.0), with macOS 27.0.1
and Xcode 27.2. It does not establish runtime acceptance on the declared
26.0 minimum OS versions. No device or simulator OS was changed.
The signed Mac Debug artifact retained CDHash
`c1b84371c49e0df48d5a5e0ce54b1f0d2ea60ee1`; application source was unchanged.
The runtime and later signed-build receipts observe the same reused DerivedData
path at different times and can record different raw executable/dylib SHA-256s.
They are separate observations, not byte-identical artifacts; no UI rerun of
the later artifact is claimed. `artifact-observation-reconciliation.json`
records the initial chronology and hash sets; subsequent signing receipts
remain separate observations at that reused path.

Working receipts: `/private/tmp/seedkeep-r5-readiness/` (`mac/`, `large-text/`,
`main-precommit/`, `reviews/`, plus `add-seed-terra/` and the Terra-follow-up
precommit/review receipts). The initial/final QA worktrees, `seedkeep-ios-wt/r5-large-text` and
`seedkeep-ios-wt/r5-add-seed-terra`, remain uncommitted outside main. The
initial first-run test-source snapshot was not retained; the final Luna and
Terra sources, all three UI result bundles, logs and captures are retained.
Private archive target (must contain the receipts before commit):
`.git/seedkeep-agent-patches/2026-11-13-r5-readiness/`.
The original four-case run had two passes/two failures; the Luna Add-Seed-only
repair run had two failed tests. After the narrow owner-approved Terra
fallback, one further Add-Seed-only run passed two tests with zero failures
and zero skips. All four unique cases have passing evidence across runs; no
single all-four-case green run is claimed. The final selectors strengthen the
Notes target identity without weakening the visibility/hittability assertions.
The first failed follow-up gate's raw `10-53-56.xcresult` bundle is unavailable;
its command/log receipts remain. Four other main-check raw bundles (zero-test
selector, isolated pass, iOS retry and Mac retry) were copied and hash-verified.
All three UI diagnostic bundles remain preserved.

## Before an approved release

- Select and qualify the exact release source, version/build and changelog.
  The source still says 1.0.0 (54); no bump has occurred. Existing build-55
  changelog text predates N3/N2-E and needs review against the chosen release.
- Finish normal-use device acceptance and the older-build upgrade on the
  exact owner-approved device/build. Preserve app data; synthetic fixture
  launches do not establish upgrade or personal-account startup behavior.
- Run the separately approved live CloudKit cases on a throwaway garden,
  including remote deletion and Keep/Discard/stop-sharing. Optional spikes
  remain restricted to approved `seedkeep-spike-*` zones.
- Complete the required accessibility acceptance; the current owner deferral
  leaves VoiceOver open. A passing
  screenshot/reachability sample does not resolve all historical audit
  reports or establish VoiceOver speech/read order.
- Resolve the existing provisional App Privacy assessment in
  `../app-store-submission-notes.md`: BYOK retention, WeatherKit and the
  legacy-server data-retention status. The legacy server-retirement runbook starts with a
  Postgres export and needs its own approval; website-trial deletion did not
  authorize or prove that legacy retirement.
- Reconcile local privacy/support/home copy with the accepted guard-only
  contract. The confirmed 1.0 decision defers in-app “Delete Seedkeep data”;
  it is not a missing 1.0 feature. Public-page deployment and rendered
  verification remain separately authorized actions.
- Freeze and verify separate iOS and Mac distribution archives. Current
  `scripts/release.sh` explicitly handles iOS only; the Mac archive/upload
  path has not been exercised. The current verifier expects an iOS-style
  executable layout, so do not treat it as Mac archive validation.
- Verify exact archive identity, Production CloudKit entitlements and current
  schema parity, then capture final iPhone/iPad/Mac screenshots from the same
  frozen source. Store fields, macOS platform setup, privacy/export answers,
  uploads, submission and public release each retain owner approval.

R5 remains open. The next action is determined by the unresolved evidence;
this document is not release approval. Independent review receipts must be retained with the frozen patch and evidence
before commit.
