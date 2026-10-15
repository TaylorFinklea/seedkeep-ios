# M0: Mac feasibility (contract)

Umbrella plan: `~/git/seedkeep/.docs/ai/phases/2026-10-15-native-workbench-redesign-plan.md`
(approved 2026-10-15: native macOS, floor macOS 26, the redesign ships as 1.0).
Branch: `redesign/m0-mac`.

## Goal

The current app (Herbarium UI, unchanged) builds, launches and is tested as a
native macOS app from the same `Seedkeep` target. The iOS build keeps passing
everything it passes today.

M0 also produces a capability matrix. It records what works on Mac unsigned,
what needs a signed build, and the fallback for anything unavailable. **No
visual redesign happens in M0.**

## Out of scope

- The Workbench redesign
- New features
- Data model or CloudKit schema changes
- Signing, provisioning, App Store Connect, device installs, uploads

Signed capability checks wait for the owner's approval, which is a separate
step.

## Invariants

- The SwiftData store identity is unchanged: `ModelConfiguration("seedkeep",
  …, cloudKitDatabase: .none)` in `AppEnvironment.makeModelContainer`. No
  schema change.
- CloudKit container `iCloud.app.seedkeep` stays on the Production
  environment. The coordinator's environment tag matches the entitlement
  (`HouseholdCloudCoordinator.swift`, around line 886). `Local*` naming is
  unchanged (`SchemaRegistrationTests`).
- iOS behaviour is unchanged, including the CKShare acceptance path
  (`SeedkeepAppDelegate` and `ShareSceneDelegate`), tab bar fonts and the
  forced light mode.
- `.xcodeproj` is generated; edit only `project.yml`.
- Platform code goes through `Seedkeep/Platform/Platform.swift`
  (parent-owned). Use `#if os(iOS)` and `#if os(macOS)`, never
  `canImport(UIKit)`, for platform splits.

## Parent seed (this commit, reviewed by Sol)

Both slices start from this commit:
- **`project.yml`:**
  - `supportedDestinations: [iOS, macOS]` on `Seedkeep` and
    `SeedkeepTests`
  - macOS deployment target 26.0
  - per-SDK `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` pointing at the
    static `Seedkeep/Info-macOS.plist` (which includes `CKSharingSupported`
    and `ATSApplicationFontsPath = .`) and
    `Seedkeep/Seedkeep-macOS.entitlements`
  - `TEST_HOST[sdk=macosx*]` set to the Mac executable path
  - Catalyst and "Designed for iPad" off
- **`Seedkeep/Platform/Platform.swift`:** the seams.

Only the parent edits these files and runs project generation as part of
integration. A slice that needs a change asks.

Unsigned evidence is limited. With `CODE_SIGNING_ALLOWED=NO` the
entitlements do nothing, so sandbox, iCloud, CloudKit, sharing, Sign in with
Apple and Keychain behaviour can only be shown in signed checks (which need
the owner's approval). The unsigned app launches to sign-in. CRUD is proven
by the hosted app tests on macOS, not by clicking through the UI.

## Slice A — lifecycle, sharing, gate (Luna)

You own (never `project.yml`, `Platform.swift`, or the Mac plist and
entitlements; ask the parent):
- `Seedkeep/App/SeedkeepApp.swift`, `Seedkeep/App/SeedkeepAppDelegate.swift`,
  `Seedkeep/App/ShareSceneDelegate.swift`, and a new
  `Seedkeep/App/MacAppDelegate.swift`
- `Seedkeep/Features/Settings/CloudSharingControllerView.swift`
- `scripts/test-gate.sh`, `scripts/release.sh` (no behaviour change for iOS),
  `.github/workflows/ci.yml`
- new tests named `Mac*Tests.swift`

Requirements:
1. **Lifecycle:**
   - On macOS, use `@NSApplicationDelegateAdaptor(MacAppDelegate.self)`. Its
     `application(_:userDidAcceptCloudKitShareWith:)` deposits into
     `PendingShareInbox` and runs `processPendingShare()`, for both warm
     acceptance and acceptance that arrives before the environment exists.
   - Keep the metadata until the environment is ready, and drain it one
     share at a time (serialized).
   - Keep the existing `.onOpenURL` and `.onContinueUserActivity` invite
     routing on macOS.
   - The UIKit tab-bar font appearance is iOS-only.
   - Test the share-acceptance routing at the `PendingShareInbox` and
     environment boundary.
2. **Sharing UI:** on macOS, sharing a household uses `NSSharingService` with
   a CloudKit share. Register the already-saved share with
   `NSItemProvider.registerCKShare(_:container:allowedSharingOptions:)`
   (private, read-write), then present it through
   `NSSharingService(named: .cloudSharing)`.
   - Retain the service and its delegate.
   - Handle save, stop and error callbacks on the MainActor.
   - Keep the coordinator integration the iOS controller uses.

   iOS keeps `UICloudSharingController` unchanged.
3. **Gate:** `scripts/test-gate.sh` also runs the app tests on
   `platform=macOS` in the same two modes, CloudKit-OFF and the CloudKit-ON
   contract. It uses `CODE_SIGNING_ALLOWED=NO` and the same nonzero-count
   gate. It prints the Xcode, iOS and macOS SDK versions and any
   unavailable destination.
   - Host startup in tests must never touch live CloudKit; the CloudKit-ON
     contract mocks networking and checks routing.
   - Record baseline counts: SeedkeepKit 97, SeedkeepCloudKit 148, and the
     iOS app counts from the first green run.
   - **CI:** the workflow builds and tests the macOS destination too.
   - **Release:** `release.sh` keeps archiving iOS exactly as today; a Mac
     archive is a later, approved step.

## Slice B — platform seams across features (Haiku 5.5)

You own the remaining UIKit call sites:
- `Seedkeep/DesignSystem/Herbarium/HerbColor.swift`
- `Seedkeep/Core/Photos/PhotoResizer.swift`
- `Seedkeep/Core/AI/CornerVisionAnalyzer.swift`
- `Seedkeep/Core/Notifications/WeatherWarnings/WeatherWarningsService.swift`
- `Seedkeep/Features/Garden/CornerSuggestionsView.swift`
- `Seedkeep/Features/Garden/WhatToPlantView.swift`
- `Seedkeep/Features/Scan/ScanFlow.swift`
- `Seedkeep/Features/Scan/CameraView.swift`
- `Seedkeep/Features/Today/TodayView.swift`
- `Seedkeep/Features/Journal/JournalEntryView.swift`
- `Seedkeep/Features/SeedDetail/AuthedImage.swift`
- `Seedkeep/Features/Assistant/AssistantThreadView.swift`
- `Seedkeep/Features/Settings/MCPSettingsView.swift`
- any other app or test file that fails the macOS build, except slice A's
  files and parent files (`project.yml`, `Seedkeep/Platform/**`,
  `Info-macOS.plist`, `Seedkeep-macOS.entitlements`)
- the four UIKit-importing tests: `CornerVisionAnalyzerTests`,
  `CornerSuggestionsViewModelTests`, `PhotoResizerTests`,
  `CornerSuggestionsFlowTests`

Requirements:
1. **Use the seams:**
   - `UIImage` becomes `PlatformImage` with `PlatformImageCoding`.
   - `UIColor` dynamic tokens become `PlatformColor.dynamic`.
   - `UIPasteboard` becomes `Pasteboard.copy`.
   - `UIScreen` scale: read SwiftUI's `@Environment(\.displayScale)` in the
     view and pass it down. There is no global scale seam; validate that the
     scale is positive.
   - The UIApplication foreground notification becomes
     `PlatformLifecycle.willEnterForeground`.
   - Settings URLs become `PlatformSettings`.
   - `UIGraphicsImageRenderer` resizing becomes a cross-platform resize
     (ImageIO or CoreGraphics) in `PhotoResizer`, reused by the assistant
     view.
2. **Behaviour on iOS:** image output (JPEG quality, pixel sizes, orientation
   and EXIF handling) is identical to today. `PlatformImageCoding.pixelSize`
   returns pixels or `nil`, never points. Existing tests must pass unchanged in their
   assertions; adapting types only is fine.
3. **Camera and scanning:**
   - `CameraView` and live camera capture are iOS-only.
   - On macOS, every scan entry point is hidden or replaced with "choose a
     photo" (PhotosPicker or a file importer), using
     `PlatformCapabilities.supportsCameraScanning`.
   - No dead buttons.
4. **Unavailable features on Mac fall back the way they do on iOS:**
   - FoundationModels uses its existing unavailable-model path.
   - WeatherKit and CoreLocation use the ZIP fallback.
   - Don't add Mac-only features.

## Parent

- `Seedkeep/Platform/Platform.swift` is the contract.
- Integration and merging.
- The capability matrix: `.docs/ai/plans/2026-10-15-m0-capability-matrix.md`.
- **Unsigned launch smoke test on macOS:** the app launches and renders
  sign-in, with a screenshot. CRUD is covered by the hosted macOS app tests.
- The SDK-27 build succeeding is not runtime verification on macOS 26. The
  target Mac runs 26, so a signed run on it is part of the signed checks.

## Capability matrix (parent fills; each row: unsigned result, signed check, fallback)

1. Sandbox
2. iCloud container and Production environment
3. SwiftData store location (sandbox container) and offline relaunch
4. CloudKit initial hydration
5. CKShare: create, accept (cold and warm), participant changes, revoke
6. Sign in with Apple
7. Keychain token store (legacy keychain vs the data-protection keychain on
   macOS)
8. Outgoing network: the server and BYOK providers
9. Photos and file import, including security-scoped URLs
10. WeatherKit and CoreLocation, with the ZIP fallback
11. FoundationModels availability and fallback
12. Notifications, including time-sensitive
13. Associated domains and universal links
14. Fonts

## Gates

- `xcodegen generate`
- Both packages: `swift test`.
- iOS app tests on an iPhone simulator, in both modes. This needs the iOS 27
  Simulator runtime (download approved and in progress).
- macOS app tests in both modes.
- Unsigned macOS Debug and Release builds.

The iOS test counts must not drop. Report every count.
