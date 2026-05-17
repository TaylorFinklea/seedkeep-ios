# Launch — v1.0

Real content that gets pasted into App Store Connect plus the runbook for
signing, archiving, and uploading. Update when copy or labels change.

## App Store metadata

- **Name**: Seedkeep
- **Subtitle**: Your household seed library
- **Primary Category**: Lifestyle (Reference is secondary)
- **Content Rating**: 4+ (no objectionable content)
- **Support URL**: `https://seedkeep.app/support` (TODO before submission)
- **Marketing URL**: `https://seedkeep.app`
- **Privacy Policy URL**: `https://seedkeep.app/privacy` (TODO before submission)

### Promotional Text (170 char limit, editable without re-review)

> Track every seed packet you own across years, locations, and gardeners. Scan a packet — Seedkeep learns it once and remembers it forever.

### Description (4000 char limit)

> Seedkeep is the seed library your shoebox always wanted to be.
>
> Track every packet you own — what it is, when you bought it, where you stored it, what's still viable, what's a leftover from three Aprils ago. Built for households that share a garden, with last-write-wins sync so two people editing on two phones never lose work.
>
> **Scan once, remember forever.** Point your camera at a seed packet's barcode or take a front+back photo. Seedkeep extracts the common name, variety, company, and instructions on-device using Apple Intelligence. The first scan of any packet seeds a shared catalog — every Seedkeep user after gets an instant lookup.
>
> **Three ways to extract.** *Free* uses Apple's on-device Foundation Models — no servers, no cost, no data shared. *BYOK* lets you bring your own OpenAI or Anthropic key for higher accuracy; the key lives in your device's Keychain and never reaches our servers.
>
> **Offline-first.** Add a packet in the seed aisle without signal. Sync when you get home.
>
> **Built for the daily trip.** Filter by what's active, what's on the wishlist, what you've saved from your own harvest. Tag by crop family, sun preference, anything you want. Tap "Random pick" when you can't decide what to start.
>
> **Households, not accounts.** Sign in with Apple, share a household with one tap, and now two phones see the same seeds. Older packets get a 3-year-old warning so you know what to test before you waste a row.
>
> v1.0 ships the seed library — what's in your shoebox, on the rack, in the freezer. Future updates add the garden plan, the journal, and the local-extension-service planting calendar.

### Keywords (100 char limit, comma-separated)

`seeds,garden,gardening,seed packet,vegetable garden,plant,sowing,household,inventory,wishlist`

### What's New (release notes)

> Welcome to Seedkeep — your household's seed library, finally out of the shoebox.

---

## Privacy nutrition labels (App Store Connect → App Privacy)

Apple groups privacy disclosures into *Data Used to Track You*, *Data Linked to You*, *Data Not Linked to You*, and *Data Not Collected*. Seedkeep's v1 surface area:

**Data Used to Track You**: *None.* No third-party trackers, no ad SDKs, no analytics that share identifiers off-device.

**Data Linked to You** (collected and linked to the user's identity):
- **Identifiers → User ID**: We store the Apple Sign in `sub` claim so the same Apple ID resolves to the same account on a second device. Purpose: *App Functionality*. Not used for tracking.
- **User Content → Photos**: When the user enables catalog contributions (default on), seed-packet front/back photos sync to our server so other households scanning the same packet get an instant match. Purpose: *App Functionality*. Not used for tracking.
- **User Content → Other User Content**: Seed metadata the user enters (name, notes, packet count, location) syncs to the server for household sharing. Purpose: *App Functionality*. Not used for tracking.

**Data Not Linked to You**:
- **Diagnostics → Crash Data**: If/when crash reporting ships in v1.1+, declare here. Currently none.

**Data Not Collected**:
- Health, financial, contacts, location, browsing history, search history, audio, gameplay, sensitive info, purchases (other than Apple IAP, which Apple itself handles).

> Note: When the Hosted tier ships, add **Identifiers → Purchase History** (the App Store receipt / original_transaction_id stored server-side) — *App Functionality*, not tracking.

---

## Export compliance

`ITSAppUsesNonExemptEncryption = false` declared in Info.plist. All crypto used by the app is the standard HTTPS/URLSession stack, which falls under Apple's "exempt" category. No annual self-classification report needed.

If we ever add custom client-side crypto (e.g. AES-encrypting seed photos before upload), flip the flag and file the report.

---

## Signing & TestFlight upload runbook

### One-time setup

1. **Apple Developer Team ID** — find it at developer.apple.com → Membership → Team ID (10-char string like `A1B2C3D4E5`).
2. Copy `Seedkeep/Config/AppConfig.example.xcconfig` to `Seedkeep/Config/AppConfig.local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM = <YOUR_TEAM_ID>`. Alternative: set it once via Xcode → Signing & Capabilities and xcodegen will preserve it across regenerations (but reverify after every `xcodegen generate`).
3. **App Icon** — `Seedkeep/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` currently has one 1024×1024 slot with no PNG. Drop a 1024×1024 icon PNG there before archiving. Without one, App Store Connect rejects the upload with "Missing required icon."
4. **Increment build number** — bump `CURRENT_PROJECT_VERSION` in `project.yml` for every upload. App Store Connect refuses duplicates.

### Archive + upload (each release)

```bash
# 1. Regenerate the project (in case project.yml changed)
xcodegen generate

# 2. Archive for release
xcodebuild \
  -scheme Seedkeep \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -archivePath build/Seedkeep.xcarchive \
  archive

# 3. Export an .ipa from the archive (needs ExportOptions.plist — see below)
xcodebuild \
  -exportArchive \
  -archivePath build/Seedkeep.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export

# 4. Upload to App Store Connect
xcrun altool --upload-app \
  --type ios \
  --file build/export/Seedkeep.ipa \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

`build/ExportOptions.plist` template:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>YOUR_TEAM_ID</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
```

Or skip the CLI entirely and use Xcode → Product → Archive → Distribute App → App Store Connect for the first few releases — the GUI does all this for you and is fine when you're not shipping daily.

### App Store Connect API key (for the altool upload step)

App Store Connect → Users and Access → Integrations → App Store Connect API → Generate a new key with **App Manager** role. Download the `.p8`, note the Key ID and Issuer ID. Save the `.p8` to `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` (the path altool reads by default).

### TestFlight

Once the build appears in App Store Connect (~10–30 min after upload, look at the **TestFlight** tab):

1. Wait for **Export Compliance** to clear (automatic since we declared the encryption flag).
2. Add yourself as an **Internal Tester** (no review needed, instant TestFlight).
3. Optionally add **External Testers** (requires a one-time Beta App Review, ~24 hours).
4. The build's "What to Test" notes go to testers — keep these crisp (~3 bullets).

---

## v1.0 launch checklist

Open items before public submission. Items already done are checked.

- [x] Bundle ID registered (`app.seedkeep.ios`) at developer.apple.com
- [x] App record created in App Store Connect
- [x] Production backend deployed (`https://seedkeep-server.fly.dev`)
- [x] iOS build green for both simulator + real-device Release
- [x] Export compliance declared (`ITSAppUsesNonExemptEncryption = false`)
- [x] Hosted tier feature-flagged off — Free + BYOK only for v1
- [x] App Icon PNG in `AppIcon.appiconset` (sprout-keep on cream, 1024×1024)
- [x] `DEVELOPMENT_TEAM = K7CBQW6MPG` pinned in `AppConfig.example.xcconfig`
- [x] Marketing-site scaffolded at `web/` (SvelteKit + adapter-static)
- [x] Privacy Policy + Support pages drafted (`web/src/routes/{privacy,support}`)
- [x] Apple-App-Site-Association generated (`web/static/.well-known/apple-app-site-association`) with `K7CBQW6MPG.app.seedkeep.ios` + `/invite/*`
- [ ] **Deploy `web/` to seedkeep.app** — `npm install && npm run build && upload build/ to Cloudflare Pages` (or any static host that honors `_headers`)
- [ ] **Validate AASA after deploy** — `curl -I https://seedkeep.app/.well-known/apple-app-site-association` should return `application/json`; also check Apple's CDN cache at `https://app-site-association.cdn-apple.com/a/v1/seedkeep.app`
- [ ] **Screenshots** captured at 6.7" (iPhone 15 Pro Max), 6.5", and 5.5" simulator sizes — at least 3 each
- [ ] **F5 real-device verification** — sideload, sign in, scan a packet via Free path, switch to BYOK with a test key, scan again, verify both paths POST a `catalog_extractions` row server-side
- [ ] **Archive + TestFlight upload** — internal testing first
- [ ] **App Store submission** — fills out remaining metadata, gets reviewed, ships

## v1.1 — Hosted tier unlock (deferred)

Code already exists; gated by `AppPreferences.isHostedTierEnabled`. To unship-block:

- [ ] App Store Connect — register subscription products `app.seedkeep.ios.hosted.{monthly,yearly}`
- [ ] App Store Connect → My Apps → App Information — generate App-Specific Shared Secret
- [ ] `fly secrets set APPLE_IAP_SHARED_SECRET=<value>`
- [ ] `fly secrets set ANTHROPIC_API_KEY=<value>`
- [ ] Flip `AppPreferences.isHostedTierEnabled = true`
- [ ] Update App Privacy labels to add Identifiers → Purchase History
- [ ] Submit a new version with the IAP products selected on the version page
