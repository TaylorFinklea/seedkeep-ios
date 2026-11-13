# App Store submission notes — Seedkeep 1.0.0 (prep, 2026-08-22; updated 2026-11-13 for N2-E guard-only scope)

> Local preparation to paste/configure in App Store Connect — not evidence of an upload or submission. The build is free, with no IAP, no sign-in, no account, and no Seedkeep server. The assistant, MCP, subscription, and account-deletion surfaces are removed by N3 before this build is cut; the text below describes the post-N3 build. Current source reads version 1.0.0, build 54 (`project.yml`). The version and build that are submitted are set in R5, not here. Finalize values in ASC only after selecting the exact archive.

## App Review — "Notes for Reviewer" (paste into ASC → App Review Information)

```
Seedkeep 1.0.0 is a household gardening companion for seed inventory,
garden beds and planting events, journal entries, photos, and planting reminders.

SIGN-IN AND ACCOUNTS: Seedkeep has no sign-in, no account, and no demo
credential. Garden data is kept in the user's private iCloud database (CloudKit).
For CloudKit and sharing tests, the review device must be signed in to iCloud.

PACKET SCANNING: Settings → AI provider offers two options.
• Free: Apple Vision reads the packet on the device. Apple's on-device foundation
  model sorts the text into fields when the device has it.
• BYOK (bring your own key): the user enters their own Anthropic or OpenAI API
  key in Settings → API keys. The key is stored in the device Keychain. The packet
  photos are sent directly from the device to the chosen provider's API, using that
  key, under the provider's terms. Seedkeep runs no server for this and never
  receives the photos or the key. Testing BYOK needs a provider key; the Free
  option needs none.

WEATHERKIT: WeatherKit refines planting windows and powers opted-in weather
warnings. The app sends the coordinates of the home location to Apple WeatherKit.
Those coordinates are derived from the ZIP code the user enters. Apple Weather
attribution appears at Settings → Notifications.

LOCATION: Settings → Home location accepts a manually entered 5-digit US ZIP code.
The ZIP is looked up in a table bundled in the app (no network request), for USDA
zone and frost data. The app does not request Core Location access or background
location.

GARDEN SHARING: With a garden open, Settings → Share garden via iCloud presents
Apple's CloudKit sharing sheet. A second user accepts with their own Apple ID. A
participant can leave with Settings → Leave shared garden.

NOTIFICATIONS: All notifications are scheduled locally on the device. This build
has no remote push entitlement.

DATA DELETION: The app creates no account, so account deletion under Guideline
5.1.1(v) does not apply. Data deletion is described in the privacy policy.
```

## Privacy label assessment (provisional — blocker until resolved)

**Provisional answer: "Data Not Collected."** This is the owner's decision of 2026-10-22 (umbrella `decisions.md`, "[2026-10-22] N3"). It stays provisional until the open checks below are resolved, and any unresolved finding blocks submission.

Basis for the submitted build:

- The app runs no Seedkeep server and sends nothing to the developer. The server-era code is removed by N3.
- Garden records and photos stay in the user's iCloud (CloudKit) and on the device.
- BYOK packet photos go from the device directly to the user's own Anthropic or OpenAI account, under that provider's terms. Seedkeep never receives them.
- WeatherKit receives the home location's coordinates, derived from the ZIP code, from the device for forecasts.

Open checks:

1. **BYOK provider retention (blocker).** The provider may retain the photos under its own policy and the user's account settings. Apple's definition of "collect", as we read it (confirm the wording in App Store Connect's current App Privacy help before relying on it), covers transmitting data off the device in a way that lets the developer or third-party partners access it for longer than needed to service the request in real time. Decide whether the user's chosen provider falls under that definition. If it does, the answer becomes "collected": Photos or Videos and Other User Content, not linked to the user, not used for tracking, for App Functionality.
2. **WeatherKit as Apple's own service (blocker).** Decide whether sending the home coordinates to WeatherKit counts as collection under Apple's definition, given that Apple provides the service. Record the reasoning in this file.
3. **Earlier builds (blocker).** Test builds before October 2026 sent packet photos and extracted fields to the Seedkeep server, and that data remains until the server-retirement runbook (`~/git/seedkeep/.docs/ai/phases/2026-10-22-server-retirement-runbook.md`) completes. Confirm that "Data Not Collected" is accurate for the submitted build while the developer still holds that data, and that the privacy policy discloses it.
4. **Deleted-garden guard acceptance (release blocker).** The approved [N2-E contract](plans/2026-10-22-n2e-deleted-garden-guard.md) is guard-only for 1.0; in-app “Delete Seedkeep data” is deferred until after 1.0. The privacy policy describes deletion through Apple's iCloud storage settings and removal of the Mac app's local folder. Verify the guard on iPhone, iPad and Mac using the separately approved throwaway-garden checks: a deleted garden is not recreated, and the local copy can be kept under a new garden ID or discarded. Check the policy and reviewer note against that behavior and the accepted limits before submission.

## Export compliance (ASC → Encryption)

- `project.yml` and the generated `Seedkeep/Info.plist` already declare
  `ITSAppUsesNonExemptEncryption = false`.
- Current source uses Apple-provided HTTPS/URLSession (BYOK provider requests and WeatherKit), CloudKit, and CryptoKit SHA-256 digests. Re-verify this list against the N3 archive. The BYOK key is stored by the system Keychain; no AES encryption implementation or third-party package is linked into the app target.
- Treat `false` as the project's current **exempt-encryption classification**,
  not as a claim that the app uses no cryptography. Reconfirm the exact archive
  through App Store Connect's export-compliance questions. If Apple requests
  documentation, obtain approval and attach it before submission rather than
  changing the answer to force clearance.

## Screenshots (current required sets — capture after the archive is frozen)

Seedkeep ships on iPhone, iPad and Mac (decided 2026-10-20), so prepare the
highest-resolution iPhone and iPad sets and a Mac set. App Store Connect accepts
one to ten `.png`, `.jpeg`, or `.jpg` images per set; no alpha channel.

- **iPhone 6.9-inch:** portrait `1260×2736`, `1290×2796`, or `1320×2868`.
- **iPad 13-inch:** portrait `2064×2752` or `2048×2732`.

Freeze and gate the exact 1.0 archive first. Then capture simulator screenshots
from the same source/version at the required dimensions, using non-sensitive
sample data, and spot-check them against the archived build. Suggested six-frame
story for each device: Today, Seeds, Seed detail/recommendation, Garden bed,
Journal, and Settings. App Store Connect scales the highest-resolution sets
for smaller displays.

## Pre-submit checklist (gates, in order)

1. Correct and deploy the public homepage/privacy/support copy under
   `seedkeep-27d.30` with separate public-write authorization; recheck all three
   rendered pages, not just HTTP 200. N3 slice D does not deploy.
2. CloudKit schema: the schema-parity CI and the additive Production schema gate
   were completed on 2026-08-27 (umbrella roadmap). Verify that evidence and the
   current parity against the release source; a new Production schema action is
   needed only if additions are identified, and then with explicit approval.
3. Run the full package and serialized iOS simulator gates on the release
   source. Do not rely on an archive command as a substitute for recorded test
   counts. Confirm the archive has no Sign in with Apple entitlement, no
   `SeedkeepAPI*` Info.plist keys, and no StoreKit product code.
4. Set the release version and build in R5. Current source reads 1.0.0 (54),
   from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Record
   the version and build that R5 produces, and confirm the archive matches them.
   These notes give no version-bump command.
5. Archive and upload only the R5 build, and only with explicit archive and upload
   authority. Any verification failure stops before export or upload.
6. Gate the submitted build unchanged against Production CloudKit: first-run
   garden creation, seed/journal/photo create-view-delete-retry, relaunch/sync, and
   recommendation spot-check. Account deletion recovery is removed by N3, so it is
   not part of this gate. The two cross-account checks were not performed and
   remain owner-waived for V1 as `seedkeep-cko.4` and `seedkeep-27d.25`; do not
   claim otherwise.
7. After the archives are frozen and gated, capture the iPhone, iPad and Mac
   screenshot sets above from the same source/version. The Mac app needs its own
   archive and upload, and the macOS platform must be added to the App Store
   Connect record (an external action with its own owner approval).
8. Complete every required App Store Connect field: age rating, content rights,
   categories, subtitle, keywords, promotional text, pricing/availability,
   support/marketing/privacy URLs (support contact support@finklea.dev), review
   contact, reviewer notes (no demo credential: there is no sign-in), privacy
   answers (see the assessment above), export compliance, and screenshots. Select
   the R5 build; include no IAP.
9. Submit, monitor review, resolve any rejection against the same gates, choose
   the release option after approval, and verify the public App Store listing is
   live and installable before closing V1.

## Known non-blockers to mention only if asked

- BYOK packet extraction is available and is distinct from the assistant: keys
  stay in the Keychain, and provider requests go from the device directly to the
  provider.
- No subscription or in-app purchase ships in this build, and the hosted path is
  removed by N3.
- No assistant or MCP surface ships in this build.
