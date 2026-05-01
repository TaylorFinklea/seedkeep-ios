# Seedkeep iOS

iOS client for [`seedkeep`](https://github.com/TaylorFinklea/seedkeep) — a household garden OS that starts as a seed-inventory replacement and grows into a planner, journal, AI assistant, and plant-care companion.

Phase 1 ships a seed library: inventory (active / wishlist / saved / archived), barcode + photo scan with AI catalog extraction, household sharing via Sign in with Apple, offline-first sync.

## Stack

- SwiftUI on iOS 18+
- SwiftData for the local store
- Sign in with Apple via `AuthenticationServices`
- Backend: Cloudflare Workers + D1 + R2 (`seedkeep` repo)
- `SeedkeepKit` Swift package — domain models, API client, sync engine
- Project file generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`

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

The checked-in project builds with generic defaults (bundle ID `com.example.seedkeep`, server `http://localhost:8787`). For local development:

1. Copy `Seedkeep/Config/AppConfig.example.xcconfig` to `Seedkeep/Config/AppConfig.local.xcconfig`.
2. Edit the values.
3. In Xcode, set `AppConfig.local.xcconfig` as the base configuration on the `Seedkeep` target.

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

See `/Users/tfinklea/.claude/plans/let-s-start-planning-this-generic-rocket.md` for the full plan and `.docs/ai/roadmap.md` for the active item list.
