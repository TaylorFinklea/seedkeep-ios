# App Store submission notes — Seedkeep 1.0.0 / build 53 (prep, 2026-08-22)

> Local preparation to paste/configure in App Store Connect — not evidence of an upload or submission. Build 53 ships free, with no IAP and no user-facing assistant or MCP surface. Finalize values in ASC only after selecting the exact archive.

## App Review — "Notes for Reviewer" (paste into ASC → App Review Information)

```
Seedkeep 1.0.0 (build 53) is a five-tab household gardening companion for seed
inventory, garden planning, journal entries, photos, and care reminders.

SIGN-IN: Sign in with Apple is the only authentication method. Seedkeep has no
app-specific username/password or demo credential. A reviewer can use Sign in
with Apple to create a fresh account; the app immediately opens an empty garden.
For CloudKit and sharing tests, the review device must also be signed in to
iCloud.

PACKET EXTRACTION: You → Settings → AI provider offers Free (on-device) and
BYOK; the Hosted/subscription path is disabled in this build. Free uses Apple
Vision and Foundation Models on the device. BYOK sends the packet photos
directly to the selected Anthropic or OpenAI API using a key stored in the
device Keychain; Seedkeep never receives the key. After either path, the
front/back packet images and structured result are submitted to Seedkeep's
authenticated shared-catalog service so future scans can match the packet. No
IAP is included in this submission.

ICLOUD DATA AND SHARING: Garden records and photo assets are stored in the
user's private iCloud database. From You → Settings, an owner can choose "Share
garden via iCloud" to present Apple's system CKShare controller. A second user
accepts the CKShare while signed in with their own Apple ID. A participant sees
"Leave shared garden" in the same Settings section. The Seedkeep server does
not receive the garden record contents during CloudKit sharing or transfer.

ACCOUNT DELETION (Guideline 5.1.1(v)): Choose You → "Delete account". Opening
the flow performs no deletion; the reviewer must confirm "Delete my account".
The app determines the user's CloudKit role, checkpoints each irreversible
step, supports retry after interruption, and deletes the server account last:

• Participant: leaves the accepted CKShare and verifies that shared zone is no
  longer active before deleting the participant's Seedkeep account. The
  owner's and other members' shared garden is not deleted.
• Solo owner: deletes the owned private CloudKit garden zone, verifies that it
  is absent, then deletes the Seedkeep account.
• Owner with accepted participants: deletion first creates a one-time handoff
  link that works only for an existing participant. The successor creates an
  owned destination zone; both devices verify record counts and a canonical
  content digest after the copy. Only then may the source zone and departing
  owner's account be deleted. The original remains intact and the owner can
  cancel until source deletion is irreversibly leased. The flow is resumable
  across relaunches.

NOTIFICATIONS / TIME SENSITIVE: All notifications are scheduled locally on the
device; this build has no APNs remote-push entitlement. They cover opted-in
planting reminders, catalog-correction outcomes, and frost, heat, or watering
warnings. Time Sensitive interruption is used only for enabled, time-bounded
weather actions.

WEATHERKIT: WeatherKit refines planting windows and powers opted-in weather
warnings. Apple Weather attribution appears at You → Settings → Notifications.

LOCATION: You → Settings → Home location accepts a manually entered 5-digit US
ZIP, used for USDA zone/frost data and coarse forecast coordinates. The app does
not request Core Location access or continuous/background location.
```

## Privacy "Nutrition Label" inputs (ASC → App Privacy)

Answer **Yes, we collect data from this app**. Select the following as **Data
Linked to You**, used only for **App Functionality**, and **not used for
tracking**:

- **Contact Info → Name, Email Address** — received from Sign in with Apple when
  the user chooses to share them; stored with the Seedkeep account.
- **Location → Coarse Location** — the manually entered home ZIP and derived
  forecast coordinates; no Core Location permission or background location.
- **User Content → Photos or Videos** — front/back packet scans are submitted
  to the shared catalog; seed and journal photos sync in the user's CloudKit
  garden.
- **User Content → Other User Content** — packet/extraction metadata, catalog
  corrections, and user-created seed, garden, and journal content.
- **Identifiers → User ID** — Sign in with Apple subject plus Seedkeep
  account/household identifiers.

**Data Used to Track You:** none. **Data Not Linked to You:** none. Do not select
Purchases, Device ID, Usage Data, or Diagnostics for this build: there is no
IAP, advertising, analytics, telemetry, crash-reporting SDK, or third-party SDK.

Data-flow clarification: Free extraction runs locally but then submits the
packet images and structured result to Seedkeep's authenticated catalog
service. BYOK sends the extraction request directly to the chosen model
provider, with the API key held only in the device Keychain, and then makes the
same catalog submission. Garden/journal data and their photos use CloudKit;
catalog extractions and corrections use the Seedkeep service.

## Export compliance (ASC → Encryption)

- `project.yml` and the generated `Seedkeep/Info.plist` already declare
  `ITSAppUsesNonExemptEncryption = false`.
- Current source uses Apple-provided HTTPS/URLSession, CloudKit, WeatherKit, and
  CryptoKit SHA-256 for integrity/digest checks. The BYOK key is stored by the
  system Keychain; no AES encryption implementation or third-party package is
  linked into the app target.
- Treat `false` as the project's current **exempt-encryption classification**,
  not as a claim that the app uses no cryptography. Reconfirm the exact archive
  through App Store Connect's export-compliance questions. If Apple requests
  documentation, obtain approval and attach it before submission rather than
  changing the answer to force clearance.

## Screenshots (current required sets — capture after the archive is frozen)

Seedkeep targets iPhone and iPad, so prepare both highest-resolution sets. App
Store Connect accepts one to ten `.png`, `.jpeg`, or `.jpg` images per set; no
alpha channel.

- **iPhone 6.9-inch:** portrait `1260×2736`, `1290×2796`, or `1320×2868`.
- **iPad 13-inch:** portrait `2064×2752` or `2048×2732`.

Freeze and gate the exact 1.0 archive first. Then capture simulator screenshots
from the same source/version at the required dimensions, using non-sensitive
sample data, and spot-check them against the archived build. Suggested six-frame
story for each device: Today, Library, Seed detail/recommendation, Garden bed,
Journal, and You/Settings. App Store Connect scales the highest-resolution sets
for smaller displays.

## Pre-submit checklist (gates, in order)

1. Correct and deploy the public homepage/privacy/support copy under
   `seedkeep-27d.30` with separate public-write authorization; recheck all three
   rendered pages, not just HTTP 200.
2. Publish the schema-parity CI in a Git-enabled context (`seedkeep-27d.23`),
   then obtain explicit approval and complete the additive Production CloudKit
   schema gate (`seedkeep-cko.8`).
3. Run the full package and serialized iOS simulator gates on the release
   source. Do not rely on an archive command as a substitute for recorded test
   counts.
4. Run `./scripts/release.sh --major --plan-version` and require the exact plan
   `0.4.0 (52) → 1.0.0 (53)` immediately before the cut.
5. In a clean, Git-enabled context and only with explicit archive/upload
   authority, run `./scripts/release.sh --major`. It bumps versions, regenerates
   Xcode, archives, verifies the signed app identity and Production entitlements,
   exports/uploads to TestFlight, and commits the bump. Any verification failure
   must stop before export or upload.
6. Gate build 53 unchanged against Production CloudKit: first-run account and
   garden creation, seed/journal/photo create-view-delete-retry, relaunch/sync,
   recommendation spot-check, and single-account deletion recovery. The two
   cross-account checks were not performed and remain owner-waived for V1 as
   `seedkeep-cko.4` and `seedkeep-27d.25`; do not claim otherwise.
7. After the archive is frozen and gated, capture the iPhone and iPad screenshot
   sets above from the same source/version.
8. Complete every required App Store Connect field: age rating, content rights,
   categories, subtitle, keywords, promotional text, pricing/availability,
   support/marketing/privacy URLs, review contact, Sign in with Apple demo-
   credential statement, reviewer notes, privacy answers, export compliance,
   and screenshots. Select build 53; include no IAP.
9. Submit, monitor review, resolve any rejection against the same gates, choose
   the release option after approval, and verify the public App Store listing is
   live and installable before closing V1.

## Known non-blockers to mention only if asked

- BYOK packet extraction is available and is distinct from Sprout: keys remain
  in Keychain, provider requests go device-to-provider, and catalog submissions
  still go to Seedkeep as disclosed above.
- Hosted extraction/subscription is feature-flagged off; no IAP is submitted.
- Sprout and MCP have no user-facing entry point in this build.
