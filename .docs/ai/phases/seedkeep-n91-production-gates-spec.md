# Production-Default CloudKit Test Gates

## Goal

- Make the gate used by both CI and TestFlight release exercise the shipping CloudKit default,
  while retaining an explicit legacy flag-OFF regression lane.
- Fail closed when a required package, app contract, or simulator test executes zero tests.

## Current evidence

- `.github/workflows/ci.yml` runs the `SeedkeepKit` host suite and one serialized app-scheme run;
  it never invokes the `SeedkeepCloudKit` package suite.
- `scripts/release.sh` duplicates a narrower app test command and hard-codes an iPhone 16 destination.
- `FeatureFlags.cloudKitHouseholdSyncEnabled` defaults ON in production but OFF whenever XCTest is
  loaded; existing CloudKit regression tests opt in explicitly through UserDefaults.
- `CloudKitPendingWriteRegressionTests` already contains the mutation and zero-server-request
  contracts to mirror; do not invent a second routing seam.

## Required contract

1. One executable script under `scripts/` owns the release-quality test gate. CI and
   `scripts/release.sh` invoke it instead of carrying divergent package/simulator commands.
2. The shared gate runs both host package suites (`SeedkeepKit`, `SeedkeepCloudKit`), the serialized
   legacy flag-OFF app suite, and a deterministic production-default CloudKit-ON contract lane.
3. The production-default lane clears any explicit UserDefaults override, proves the shipping
   default resolves ON, performs at least one representative household mutation, and proves the
   legacy Postgres dispatch/flush path receives zero requests. It must fail if the default silently
   returns to the test-host OFF behavior.
4. Preserve explicit user override precedence. Any test-only selection mechanism must be visibly
   test-scoped and must not alter release behavior.
5. Simulator selection must accept a supplied UDID and otherwise discover an available iPhone;
   absence is a hard error. Every required xcodebuild result must be checked for a non-zero executed
   test count, not only process exit status.
6. The release script runs the shared gate before version mutation. Keep `--skip-tests` as the
   existing explicit escape hatch and warning; verification must never archive, export, upload, or
   bump a version.
7. Keep the generated Xcode project in sync with `project.yml` if project configuration changes.

## Boundaries

- Do not change CloudKit data-plane behavior, production feature defaults, release credentials,
  archive/upload flow, or unrelated tests.
- Read and mirror the existing CI simulator discovery and serialized app-test patterns.
- One implementation commit for `seedkeep-n91`, including this spec, a terse report, and cleared
  `.docs/ai/current-state.md` Plan.

## Acceptance

- CI and release call the same gate and cannot omit either package suite.
- A missing simulator, zero selected app tests, package failure, legacy-lane failure, or
  production-default routing regression stops the gate before release mutation.
- Existing explicit ON/OFF tests remain deterministic; the full required local verification passes.

## Verify

```bash
swift test --package-path /Users/tfinklea/git/seedkeep-ios/SeedkeepCloudKit && xcodebuild test -project /Users/tfinklea/git/seedkeep-ios/Seedkeep.xcodeproj -scheme Seedkeep -destination 'platform=iOS Simulator,id=FDDFB511-272B-40DD-8927-5E71311E96BA' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
