# Seedkeep iOS

The iPhone, iPad and Mac app for [Seedkeep](https://seedkeep.app), a garden notebook for seeds, beds, planting windows and a journal. It runs entirely on Apple services: data lives on the device and syncs through the user's iCloud account, and a garden is shared through iCloud. There is no Seedkeep server.

## Stack

- SwiftUI on iOS 26 and macOS 26
- SwiftData for the local store; CloudKit (`CKSyncEngine`) for sync and CKShare for sharing
- Apple Foundation Models and Vision OCR for on-device packet extraction; optional bring-your-own-key AI providers
- WeatherKit for frost and weather warnings
- `SeedkeepKit` Swift package: shared value types (write inputs, journal and pet types, `humanizeError`)
- `SeedkeepCloudKit` Swift package: the CloudKit record schema and sync engine plumbing
- Project file generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`
- Marketing site (`web/`) on SvelteKit + adapter-static, deployed to <https://seedkeep.app>

## Build

```bash
# One-time: install XcodeGen
brew install xcodegen

# Generate Seedkeep.xcodeproj from project.yml
xcodegen generate

# Open in Xcode
xed Seedkeep.xcodeproj
```

The `.xcodeproj` is gitignored — regenerate it after pulling changes that touch `project.yml`, `Seedkeep/`, or `SeedkeepKit/`.

## Configuration

The checked-in project builds with production defaults: bundle ID `app.seedkeep.ios`, Team ID `K7CBQW6MPG`. For per-developer overrides (for example a different bundle ID to avoid provisioning collisions):

1. Copy `Seedkeep/Config/AppConfig.example.xcconfig` to `Seedkeep/Config/AppConfig.local.xcconfig`.
2. Edit the values you want to override.
3. Update both `configFiles` lines in `project.yml` to reference `AppConfig.local.xcconfig`, then re-run `xcodegen generate`.

The `.local` variant is gitignored.

## Repo layout

```
Seedkeep/                 # app target sources (iOS and macOS)
  App/                    # App entry, environment, identity, navigation
  Core/                   # SwiftData models, sync, CloudKit, photos, notifications
  Features/               # screens: Today, Seeds, Garden, Windows, Journal, Settings, Scan
  DesignSystem/           # Workbench colours, type and components
  Config/                 # xcconfig
SeedkeepKit/              # Swift package: shared value types
SeedkeepCloudKit/         # Swift package: CloudKit schema and sync plumbing
SeedkeepTests/            # app unit tests (Swift Testing)
SeedkeepUITests/          # UI, screenshot and accessibility audit tests
scripts/                  # test gate, screenshots, audit, release
web/                      # marketing, privacy and support site
project.yml               # XcodeGen spec
```

## Plans and release

See [`.docs/ai/roadmap.md`](./.docs/ai/roadmap.md) for the active item list and [`.docs/launch.md`](./.docs/launch.md) for the v1 launch checklist (App Store metadata, privacy nutrition labels, signing/archive runbook).

## License

[MIT](./LICENSE) — © 2026 Taylor Finklea
