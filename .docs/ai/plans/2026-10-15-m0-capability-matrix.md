# M0 capability matrix (native macOS)

Contract: `2026-10-15-m0-mac-feasibility.md`. Toolchain: Xcode 27 with the iOS
27 and macOS 27 SDKs, deployment targets iOS 26 and macOS 26.

## How to read the evidence

- **Unsigned evidence:** comes from `CODE_SIGNING_ALLOWED=NO` builds and the
  hosted tests on this Mac (macOS 27). Entitlements do nothing in an
  unsigned build. So sandbox, iCloud, CloudKit, sharing, Sign in with Apple
  and Keychain behaviour cannot be shown unsigned.
- **Signed checks:** need macOS signing and provisioning (device
  registration and a macOS profile in the developer account). That is an
  external action that waits for the owner's approval. They run on this Mac
  and on the target MacBook (macOS 26).
- **Data safety:** they use a disposable test garden, never a family member's
  real data (`device-verify.md`).

## Matrix

1. **App Sandbox.**
   - **Unsigned:** declared in `Seedkeep-macOS.entitlements`; inactive.
   - **Signed check:** the signed app launches sandboxed (shown in Activity
     Monitor). The store, attachments and Keychain resolve inside the
     container.
   - **Fallback:** none needed; it's required for the Mac App Store.
2. **iCloud container `iCloud.app.seedkeep`, Production environment.**
   - **Unsigned:** declared and matches iOS. The coordinator's environment
     tag is unchanged.
   - **Signed check:** CloudKit account status is available, and the
     container identifier and environment match iOS.
   - **Fallback:** none; household sync requires it.
3. **SwiftData store location and offline relaunch.**
   - **Unsigned:** the same `ModelConfiguration("seedkeep", …, .none)`
     (unchanged). Hosted macOS app tests pass: CloudKit-OFF 770 and the
     CloudKit-ON contract.
   - **Signed check:** the store is created under the sandbox container. Add
     a seed, quit offline, relaunch: the data persists.
   - **Fallback:** none needed.
4. **CloudKit initial hydration.**
   - **Unsigned:** the code is shared with iOS and package tests pass
     (SeedkeepCloudKit 148).
   - **Signed check:** a fresh Mac signed in to the same Apple Account
     hydrates the owner's garden from Production.
   - **Fallback:** none; sync is core.
5. **CKShare.**
   - **Unsigned:**
     - **Accepting invitations:** cold and warm via
       `MacAppDelegate.application(_:userDidAcceptCloudKitShareWith:)` into
       `MacPendingShareQueue`. The drain waits for sign-in, terminal
       failures are removed, and transient ones are retried with a bound.
     - **Creating shares:** `NSSharingService(.cloudSharing)` with
       `registerCKShare`.
     - **Tests:** routing tests pass.
   - **Signed check:** create an invitation on the Mac, then accept it on the
     Mac cold and warm. Check participant changes and revocation across iPhone
     and Mac.
   - **Fallback:** share from iPhone or iPad; the Mac can still accept.
6. **Sign in with Apple.**
   - **Unsigned:** entitlement declared; the shared `AuthenticationServices`
     code builds.
   - **Signed check:** sign in on the Mac, restore after relaunch, sign out.
   - **Fallback:** none; it's the account system.
7. **Keychain token store.**
   - **Unsigned:** a generic-password item without
     `kSecUseDataProtectionKeychain`. That's the legacy file keychain on
     macOS.
   - **Signed check:** the token persists across relaunch in the sandbox, and
     there's no keychain prompt. Decide whether to opt into the
     data-protection keychain on macOS.
   - **Fallback:** if the legacy path is unreliable, add
     `kSecUseDataProtectionKeychain` on macOS only.
8. **Outgoing network** (seedkeep-server, catalog and recommendations, BYOK).
   - **Unsigned:** `com.apple.security.network.client` declared.
   - **Signed check:** catalog and recommendation calls succeed under the
     sandbox.
   - **Fallback:** none needed.
9. **Photo and file import.**
   - **Unsigned:** PhotosPicker builds on macOS. Camera scanning is iOS-only
     (the Library scan button is hidden on Mac). Photo resizing has its own
     macOS path, with iOS byte-identical.
   - **Signed check:** attach a photo from Photos and from Files under the
     sandbox (photos-library and user-selected entitlements).
   - **Fallback:** a file importer if the PhotosPicker sandbox access fails.
10. **WeatherKit and CoreLocation.**
    - **Unsigned:** entitlements declared; the existing ZIP fallback is
      unchanged.
    - **Signed check:** frost warnings work from the home ZIP. A location
      prompt appears only where it already did on iOS.
    - **Fallback:** the ZIP fallback.
11. **FoundationModels.**
    - **Unsigned:** the existing availability check and unavailable-model
      path are unchanged.
    - **Signed check:** on macOS 26, report the model's availability on the
      target MacBook. Extraction falls back cleanly when the model is
      unavailable.
    - **Fallback:** OCR or manual entry, as on unsupported iPhones.
12. **Notifications, including time-sensitive.**
    - **Unsigned:** `UNUserNotificationCenter` is shared code. `.ephemeral`
      is gated to iOS, and the macOS settings link opens System Settings.
    - **Signed check:** schedule and deliver a frost warning on the Mac;
      time-sensitive delivery works during Focus.
    - **Fallback:** standard (not time-sensitive) delivery.
13. **Associated domains and universal links** (`applinks:seedkeep.app`).
    - **Unsigned:** declared; `.onOpenURL` and `.onContinueUserActivity` are
      kept on macOS.
    - **Signed check:** `seedkeep://` and `https://seedkeep.app/invite/…`
      links open the Mac app. This depends on the AASA file including the Mac
      app ID.
    - **Fallback:** the custom URL scheme.
14. **Bundled fonts.**
    - **Unsigned:** `ATSApplicationFontsPath = .` in the Mac Info.plist,
      with the fonts copied flat into Resources.
    - **Signed check:** the unsigned launch smoke test (below) shows the
      Herbarium fonts rendering.
    - **Fallback:** system fonts. R1 replaces them with Public Sans and
      JetBrains Mono anyway.

## Unsigned launch smoke test

See the M0 status section in `current-state.md`: the unsigned app launches
and renders sign-in, with a screenshot.

## Go / no-go for native versus Catalyst

**Native is GO for build, test and unsigned launch.** The whole app compiles
for macOS 26 behind about 60 small, reviewed edits. The full hosted test
suite runs on macOS (770 + 1). iOS is unchanged: 769 + 1, with the share,
photo and lifecycle paths identical to HEAD.

The signed checks above are the remaining risk. None of them is solved better
by Catalyst. Catalyst would only remove the sharing and lifecycle porting,
which is already done.

## Review follow-ups for the signed-check round (Opus 5.5, non-blocking)

- **Retry timing:** Mac share retries fire only on the next activation,
  accept or sign-in change, not while the app stays frontmost.
- **Dropped shares:** after a terminal error, or 4 transient failures, the
  Mac drops a share; iOS keeps retrying. Confirm this is the intended UX
  during the signed checks.
- **Cancel shows an error:** filter the user-cancelled error from
  `NSSharingService`, so cancelling the share sheet doesn't show the
  "Couldn't share garden" alert. Confirm in a signed run.
- **Session leak:** check `canPerform(withItems:)` before
  `perform(withItems:)`, so a sharing session can't leak if no callback
  arrives.
- **Assistant photos:** on Mac, small rotated assistant photos are baked
  upright instead of keeping the EXIF tag. They look the same; the assistant
  is unwired for 1.0.
