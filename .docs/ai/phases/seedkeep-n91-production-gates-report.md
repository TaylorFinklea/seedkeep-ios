# Production-Default CloudKit Test Gates

- Added `scripts/test-gate.sh` as the shared release-quality gate; it regenerates the gitignored Xcode project before selecting tests.
- CI and `scripts/release.sh` now call the shared gate; release tests still run before version mutation and `--skip-tests` remains explicit.
- Gate coverage: `SeedkeepKit`, `SeedkeepCloudKit`, serialized CloudKit-OFF app regression, and a test-scoped CloudKit-ON production-default contract that performs a seed mutation and rejects legacy POST flush traffic.
- Simulator accepts `SIM_UDID` / `--simulator-udid`, discovers an available iPhone otherwise, and rejects missing or zero-test results.
- Verify passed:
  - `swift test --package-path /Users/tfinklea/git/seedkeep-ios/SeedkeepCloudKit`
  - required app `xcodebuild test` command: 441 tests passed
  - `./scripts/test-gate.sh --simulator-udid FDDFB511-272B-40DD-8927-5E71311E96BA`: all required tests passed
