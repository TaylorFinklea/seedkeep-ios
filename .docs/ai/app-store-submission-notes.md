# App Store submission notes — Seedkeep 0.4.x (prep, 2026-06-14)

> Drafted for M5. This is a **prep checklist** to paste/configure in App Store Connect — not a submission. Finalize values in ASC yourself. 1.0 ships **free + BYOK** (no IAP this submission — see decisions.md 2026-06-10).

## App Review — "Notes for Reviewer" (paste into ASC → App Review Information)

```
Seedkeep is a household gardening companion (seed inventory, garden planning,
journal, weather-driven care reminders).

SIGN-IN: Sign in with Apple is the only authentication. No demo account is
needed — creating an account with the reviewer's Apple ID lands in a working,
empty household immediately.

ACCOUNT DELETION (Guideline 5.1.1(v)): In-app, under the "You" tab → "Delete
account" (confirmation-gated). It permanently deletes the account and all of
the household's data server-side.

AI ASSISTANT ("Sprout") — BYOK, OPTIONAL: The conversational assistant is a
bring-your-own-key feature. It is OFF until the user pastes their own Anthropic
or OpenAI API key in Settings; the rest of the app is fully usable without it.
No key is bundled and none is required for review. (Seedkeep does not sell or
include AI credits in this build.)

NOTIFICATIONS / Time-Sensitive: Local notifications only (no push/APNS). Used
for weather warnings (frost / heat / watering), planting-event reminders, and
catalog-correction outcomes. Time-sensitive interruption is used for
frost/heat/watering because they are time-bounded gardening actions the user
asked to be alerted about.

WEATHERKIT: Used for the planting-window and weather-warning features;
attribution is shown in Settings.

LOCATION: Coarse only — the user sets a home ZIP (resolved to lat/lon) to
localize planting recommendations. No continuous/background location.
```

## Privacy "Nutrition Label" inputs (ASC → App Privacy)

Data the app collects (all **linked to identity**, **not used for tracking**):
- **Contact Info** — name + email (from Sign in with Apple). Purpose: App Functionality (account).
- **Location** — coarse (home ZIP → lat/lon). Purpose: App Functionality (planting recommendations + weather warnings).
- **User Content** — photos (seed packets, journal), free text (journal, catalog corrections). Purpose: App Functionality.
- **Identifiers** — user/household IDs. Purpose: App Functionality.
- **Diagnostics** — none collected by us (no third-party analytics SDK).

Note: BYOK API keys are user-provided secrets stored AES-256-GCM at rest server-side; they are not "collected" data about the user — but be ready to describe BYOK handling if asked.

## Export compliance (ASC → Encryption)

- App uses **standard HTTPS** + standard platform crypto + AES-256-GCM for BYOK key storage — all exempt categories.
- Set `ITSAppUsesNonExemptEncryption` appropriately (typically **NO** for standard exempt encryption). Confirm against current Apple guidance before submitting; if set in Info.plist it skips the per-build encryption question.

## Screenshots (required sizes — capture on device/sim)

Suggested flow to screenshot (sells the product): Today (sun-arc + specimens), Library (pressed-specimen grid), a Seed detail with the recommendation panel, Garden bed layout, Journal feed, You/Settings. Capture on the required iPhone display sizes (6.9" + 6.5" at minimum per current ASC requirements — verify the current required set).

## Pre-submit checklist (gates, in order)

1. **Deploy the account-deletion route to prod** (`fly deploy` from seedkeep-server) — the iOS Delete-account button 404s until the server route is live. ⚠️ This must be live in prod before the submitted build is reviewed.
2. **Cut the TestFlight build** (`scripts/release.sh --build`) carrying account deletion + the 5-tab consolidation.
3. **Device-verify** that build (`device-verify.md`) — the authoritative iOS-18 pass.
4. Fill the above (notes, privacy labels, encryption, screenshots) in ASC.
5. Submit. No IAP bundled.

## Known non-blockers to mention only if asked

- Hosted (server-side AI) tier exists in code but is feature-flagged OFF (no IAP this release).
- MCP/OAuth surface (external client access) exists but is not a consumer-facing feature.
