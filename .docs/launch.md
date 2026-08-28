# Launch — v1.0

Real content that gets pasted into App Store Connect plus the runbook for
signing, archiving, and uploading. Update when copy or labels change.

## App Store metadata

- **Name**: Seedkeep
- **Subtitle**: Your household seed library
- **Primary Category**: Lifestyle (Reference is secondary)
- **Content Rating**: 4+ (no objectionable content)
- **Support URL**: `https://seedkeep.app/support` (HTTP 200; content correction/deploy blocked by `seedkeep-27d.30`)
- **Marketing URL**: `https://seedkeep.app` (HTTP 200; content correction/deploy blocked by `seedkeep-27d.30`)
- **Privacy Policy URL**: `https://seedkeep.app/privacy` (HTTP 200; content correction/deploy blocked by `seedkeep-27d.30`)

### Promotional Text (170 char limit, editable without re-review)

> Track every seed packet you own across years, locations, and gardeners. Scan a packet — Seedkeep learns it once and remembers it forever.

### Description (4000 char limit)

> Seedkeep turns your seed collection into a garden you can plan, plant, and remember — together.
>
> Keep every packet organized, from active seeds and wish-list finds to saved seed and older packets you want to test. Track varieties, packet counts, storage locations, tags, notes, and viability in one library.
>
> Features:
>
> • Scan a barcode or photograph the front and back of a packet to prefill its details, then review everything before saving.
> • Plan garden beds and planting events, with date- and weather-aware guidance for your location.
> • Keep a journal with entries, checklists, and photos, and revisit what happened on this day in past garden years.
> • Get optional local reminders for planting events plus frost, heat, and watering alerts.
> • Share your garden through iCloud so household members see the same seed library, plans, and journal.
> • Keep working without a connection and sync when one is available again.
>
> Built for gardeners who want fewer mystery packets, clearer plans, and a lasting record of what worked.

### Keywords (100 char limit, comma-separated)

`seeds,garden,gardening,seed packet,vegetable garden,plant,sowing,household,inventory,wishlist`

### What's New (release notes)

> Welcome to Seedkeep — your household's seed library, finally out of the shoebox.

---

## Privacy nutrition labels (App Store Connect → App Privacy)

Answer **Yes, we collect data from this app**.

**Data Used to Track You**: *None.* No ads, advertising identifiers, tracking,
analytics, telemetry, or third-party SDKs.

**Data Linked to You** — for each item select *App Functionality*, linked to the
user, and not used for tracking:

- **Contact Info → Name, Email Address**: supplied by Sign in with Apple when the
  user chooses to share them; stored with the Seedkeep account.
- **Location → Coarse Location**: manually entered home ZIP plus derived forecast
  coordinates. Seedkeep does not request Core Location or background location.
- **User Content → Photos or Videos**: packet front/back scans are submitted to
  the shared catalog. Seed and journal photos sync through the user's CloudKit
  garden.
- **User Content → Other User Content**: packet/extraction metadata, catalog
  corrections, and user-created seed, garden, and journal content.
- **Identifiers → User ID**: Sign in with Apple subject and Seedkeep
  account/household identifiers.

**Data Not Linked to You**: *None.* The authenticated collection paths above are
treated conservatively as linked.

Do not select Purchases, Device ID, Usage Data, or Diagnostics for build 53.
There is no IAP and no integrated analytics, telemetry, or crash-reporting SDK.

Data-flow notes for review: Free packet extraction uses Vision/Foundation Models
locally, then submits packet images and the structured result to Seedkeep's
authenticated catalog service. BYOK sends the extraction request directly to
the selected Anthropic/OpenAI API using a Keychain-held key that Seedkeep never
receives, then submits the same catalog payload. Garden/journal records and
photos use CloudKit/CKShare. Catalog extractions and corrections use the
Seedkeep service.

When Hosted/IAP ships later, reassess every data type and add Purchase History
if receipts or transaction identifiers are collected.

---

## Export compliance

`ITSAppUsesNonExemptEncryption = false` is declared in `project.yml` and the
generated `Seedkeep/Info.plist`. Current source uses Apple-provided
HTTPS/URLSession, CloudKit, WeatherKit, system Keychain storage, and CryptoKit
SHA-256 integrity/digest checks. No AES encryption implementation or third-party
package is linked into the app target.

This is the project's current exempt-encryption classification, not a claim
that the app contains no cryptographic functionality. Reconfirm the exact
archive through App Store Connect's export-compliance questionnaire. If Apple
requests documentation, obtain and attach the approved declaration before
submission; do not change the answer merely to clear the build.

---

## Signing & TestFlight upload runbook

### One-time setup

Already done; this list is the inventory:

- **Team ID** — pinned to `K7CBQW6MPG` in `Seedkeep/Config/AppConfig.example.xcconfig`. Per-developer overrides go in `Seedkeep/Config/AppConfig.local.xcconfig` (gitignored).
- **App Icon** — 1024×1024 PNG at `Seedkeep/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`.
- **App Store Connect API key** — key ID and issuer resolve from the macOS Keychain services documented at the top of `scripts/release.sh`; the private key resolves from Apple's standard `~/.appstoreconnect/private_keys/AuthKey_<resolved-key-id>.p8` path unless explicitly overridden.
- **ExportOptions.plist** — `Seedkeep/ExportOptions.plist` (committed; references team ID and `app-store-connect` upload destination).

### Releasing (each TestFlight + App Store iteration)

One command:

```bash
./scripts/release.sh
```

That runs the full pipeline: bump `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate the Xcode project, archive Release for generic iOS, reject any archive whose signed identity or entitlements do not match the release contract, export with the App Store Connect API key, upload to TestFlight, commit the version bump. Mirrors the same script used by Open Feelings and SimmerSmith.

Flags for version planning and marketing-version bumps:

```bash
./scripts/release.sh --patch    # 0.1.0 → 0.1.1
./scripts/release.sh --minor    # 0.1.0 → 0.2.0
./scripts/release.sh --major    # 0.4.0 → 1.0.0; archive + upload + commit
./scripts/release.sh --major --plan-version  # print plan only; no mutation
```

Build-only bumps are the right default for routine TestFlight iteration.
`--patch`, `--minor`, and `--major` mutate the version and run the archive,
upload, and Git-commit pipeline, so use them only in a clean Git-enabled context
with explicit current authorization. `--plan-version` is the safe preflight.

### After upload

App Store Connect takes 10–30 min to process the build. Watch under TestFlight → iOS Builds → your new build row. Once processing completes:

1. Add yourself as an Internal Tester (instant — no review needed)
2. Install via the TestFlight app on your phone
3. The TestFlight app surfaces new builds with an "Update" tap

Material problems (missing icon, missing export compliance, validation failures) surface immediately as red emails from App Store Connect. The script also pipes the export log to `/tmp/seedkeep-export.log` for debugging.

### TestFlight

Once the build appears in App Store Connect (~10–30 min after upload, look at the **TestFlight** tab):

1. Confirm the build's **Export Compliance** status in App Store Connect. The
   declared key should streamline the questionnaire, but the ASC readback is
   authoritative; do not infer clearance from the plist alone.
2. Add yourself as an **Internal Tester** (no review needed, instant TestFlight).
3. Optionally add **External Testers** (requires a one-time Beta App Review, ~24 hours).
4. The build's "What to Test" notes go to testers — keep these crisp (~3 bullets).

---

## v1.0 launch checklist

Open items before public submission. Items already done are checked.

- [x] Bundle ID registered (`app.seedkeep.ios`) at developer.apple.com
- [x] App record created in App Store Connect
- [x] Production backend deployed (`https://seedkeep-server.fly.dev`)
- [x] Build 52 baseline green for simulator + real-device Release; the exact build 53 gate remains below
- [x] Export classification declared (`ITSAppUsesNonExemptEncryption = false`); exact archive still gets an ASC readback
- [x] Hosted tier feature-flagged off — Free + BYOK packet extraction only; no IAP/Sprout/MCP surface
- [x] App Icon PNG in `AppIcon.appiconset` (sprout-keep on cream, 1024×1024)
- [x] `DEVELOPMENT_TEAM = K7CBQW6MPG` pinned in `AppConfig.example.xcconfig`
- [x] Marketing-site scaffolded at `web/` (SvelteKit + adapter-static)
- [x] Privacy Policy + Support pages drafted (`web/src/routes/{privacy,support}`)
- [x] Apple-App-Site-Association generated (`web/static/.well-known/apple-app-site-association`) with `K7CBQW6MPG.app.seedkeep.ios` + `/invite/*`
- [x] Marketing site live at `https://seedkeep.app` (Cloudflare); AASA verified `application/json`
- [x] `scripts/release.sh` for one-command TestFlight upload (mirrors Open Feelings)
- [ ] **Public site content** — correct/deploy homepage, privacy, and support under `seedkeep-27d.30`; verify rendered claims, not only HTTP 200
- [ ] **Production schema gate** — publish parity CI (`seedkeep-27d.23`), then explicitly approve and complete additive Production deploy (`seedkeep-cko.8`)
- [ ] **Release-source simulator gate** — package suites + full serialized iOS suite with recorded nonzero counts
- [ ] **Version preflight** — `./scripts/release.sh --major --plan-version` prints exactly `0.4.0 (52) → 1.0.0 (53)`
- [ ] **Archive + TestFlight upload** — explicit authority, clean Git-enabled context, `./scripts/release.sh --major`; preserve build 53 unchanged
- [ ] **Exact-build acceptance** — Production single-account first run, seed/journal/photo lifecycle, relaunch/sync, recommendation, and deletion recovery; two-account checks remain unperformed/deferred (`seedkeep-cko.4`, `seedkeep-27d.25`) without blocking V1
- [ ] **Screenshots** — same source/version after archive freeze: one coherent 6.9-inch iPhone set plus one 13-inch iPad set, one to ten images each, no alpha
- [ ] **ASC metadata** — all mandatory fields, reviewer notes, privacy/export answers, URLs, screenshots, and build 53 selected; no IAP
- [ ] **App Store submission and release** — submit, resolve review, release after approval, then verify the public listing is live and installable

## v1.1 — Hosted tier unlock (deferred)

Code already exists; gated by `AppPreferences.isHostedTierEnabled`. To unship-block:

- [ ] App Store Connect — register subscription products `app.seedkeep.ios.hosted.{monthly,yearly}`
- [ ] App Store Connect → My Apps → App Information — generate App-Specific Shared Secret
- [ ] `fly secrets set APPLE_IAP_SHARED_SECRET=<value>`
- [ ] `fly secrets set ANTHROPIC_API_KEY=<value>`
- [ ] Flip `AppPreferences.isHostedTierEnabled = true`
- [ ] Update App Privacy labels to add Purchases → Purchase History
- [ ] Submit a new version with the IAP products selected on the version page
