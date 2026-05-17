# Seedkeep iOS

iOS client for [Seedkeep](https://seedkeep.app) — a household garden OS that starts as a seed-inventory replacement and grows into a planner, journal, AI assistant, and plant-care companion. Pairs with [`seedkeep-server`](https://github.com/TaylorFinklea/seedkeep-server).

Phase 1 ships a seed library: inventory (active / wishlist / saved / archived), barcode + photo scan with on-device AI catalog extraction, household sharing via Sign in with Apple, offline-first sync.

## Stack

- SwiftUI on iOS 18.1+
- SwiftData for the local store
- Sign in with Apple via `AuthenticationServices`
- Apple Foundation Models (iOS 26+) + Vision OCR for free-tier on-device extraction
- StoreKit 2 for the Hosted subscription tier (feature-flagged off in v1)
- Backend: Bun + Hono + PostgreSQL + S3 ([`seedkeep-server`](https://github.com/TaylorFinklea/seedkeep-server))
- `SeedkeepKit` Swift package — domain models, API client, sync engine
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

The checked-in project builds with production defaults: bundle ID `app.seedkeep.ios`, Team ID `K7CBQW6MPG`, server `https://seedkeep-server.fly.dev`. For per-developer overrides (different bundle ID to avoid provisioning collisions, point at a local server, etc.):

1. Copy `Seedkeep/Config/AppConfig.example.xcconfig` to `Seedkeep/Config/AppConfig.local.xcconfig`.
2. Edit the values you want to override.
3. Update both `configFiles` lines in `project.yml` to reference `AppConfig.local.xcconfig`, then re-run `xcodegen generate`.

The `.local` variant is gitignored.

## Repo layout

```
Seedkeep/                 # Xcode app target sources
  App/                    # SwiftUI App entry, environment, navigation
  Features/               # Library, Add, Scan, Random, Settings
  Config/                 # xcconfig + Info.plist
SeedkeepKit/              # Swift package
  Sources/SeedkeepKit/
    Models/               # SwiftData @Model classes
    API/                  # SeedkeepClient (envelope-aware HTTP)
    Sync/                 # delta-sync engine
    Catalog/              # perceptual hash, barcode helpers
  Tests/                  # Swift Testing
project.yml               # XcodeGen spec
```

## Phase 1 scope

See [`.docs/ai/roadmap.md`](./.docs/ai/roadmap.md) for the active item list and [`.docs/launch.md`](./.docs/launch.md) for the v1 launch checklist (App Store metadata, privacy nutrition labels, signing/archive runbook).

## License

[MIT](./LICENSE) — © 2026 Taylor Finklea
