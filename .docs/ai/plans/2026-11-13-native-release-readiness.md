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
| Main source gate and signed Mac build | Passed fresh November 13 checks | Kit 25; CloudKit 176; iOS 1,447 passed plus one expected fixture-generator skip; Mac 1,462 plus the same skip. Both 5,000-row yield cases passed, with no retry. Signed Debug build and strict deep codesign passed. The first build hit a sandbox cache-write denial; the same authorized build passed under host execution. |
| Mac routes, inline counts, grid activation/focus | Verified for recorded sample cases | `2c17004`, `52acc84`, `63b5709`; R5 Results distinguish keyboard, AX and pointer checks. |
| Bed / square-detail large-text checks | Passed two cases | Default and Accessibility XXXL normal rendering, without an audit call. The heading, sample event, Sugar Snap detail label, notes field and final action were wholly inside the measured viewport after scrolling. These samples do not map or resolve individual historical audit reports. |
| Add Seed large-text checks | Partial; helper repair blocked | XXXL State/Location/Source choices returned Wishlist/Garage shelf/Self-saved. Both initial Add Seed tests and their single bounded helper-repair rerun failed on Notes lookup/scrolling. Retained hierarchies show the lowercase AX header `notes` and a Notes AX frame inside the form viewport; its frame/isHittable assertion and Cancel step were not reached. No product defect is established. The required `worker_hard` role is unavailable; a separate native Terra exception is pending owner decision. |
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
path at different times and record different raw executable/dylib SHA-256s.
They are separate observations, not byte-identical artifacts; no UI rerun of
the later artifact is claimed. `artifact-observation-reconciliation.json`
records the chronology and both hash sets.

Working receipts: `/private/tmp/seedkeep-r5-readiness/` (`mac/`, `large-text/`,
`main-precommit/`, `reviews/`). The frozen QA-only patch remains uncommitted in
`seedkeep-ios-wt/r5-large-text`; it is not part of the shipping app or this
main-checkout patch. Its initial test-source snapshot was not retained;
the repaired source, both raw result bundles, logs and captures are retained.
Private archive target (must contain the receipts before commit):
`.git/seedkeep-agent-patches/2026-11-13-r5-readiness/`.
The original four-case run had two passes/two failures; the Add-Seed-only
repair run had two failed tests. No all-four-case green run is claimed.

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
