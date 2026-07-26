# seedkeep-web

Marketing site for [Seedkeep](https://seedkeep.app). Static SvelteKit, mirrors
the pattern used by Open Feelings / Joji.

## Run locally

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```

Output goes to `build/`. Drop that directory on any static host — Cloudflare
Pages, Netlify, GitHub Pages, S3 + CloudFront, whatever.

## What's here

- `/` — landing page (`src/routes/+page.svelte`)
- `/privacy` — Privacy Policy (`src/routes/privacy/+page.svelte`)
- `/support` — Support page (`src/routes/support/+page.svelte`)
- `/.well-known/apple-app-site-association` — universal-links file for the iOS
  app's household-invite deep links. Served as `application/json` via the
  `static/_headers` Cloudflare Pages directive.

## Deploy to Cloudflare

The repo ships a `wrangler.toml` for Cloudflare Workers Static Assets. Fixed
pages are static; the narrow `worker.js` route serves SvelteKit's generated
fallback for arbitrary `/garden-handoff/*` IDs. Workers Builds settings:

| Setting | Value |
|---|---|
| **Build command** | `npm install && npm run build` |
| **Deploy command** | `npx wrangler deploy` |
| **Path / root directory** | `/web` (where this README lives — *not* `/web/build`) |
| **Non-production deploy** | `npx wrangler versions upload` (default) |

The Wrangler config owns the `seedkeep.app` custom domain. A deploy updates the
assets, the handoff fallback Worker, and that domain route together.
Validate the AASA file:

```bash
curl -I https://seedkeep.app/.well-known/apple-app-site-association
```
Expected `200 OK` + `content-type: application/json`. Apple's CDN cache warms
up over the next ~24 hours at
<https://app-site-association.cdn-apple.com/a/v1/seedkeep.app>.

## Manual deploy (alternative)

Deploy from the repository:

```bash
cd web
npm install
npm run build
npx wrangler deploy
```

Wrangler will prompt for auth the first time, then publish `build/` directly.

## Validating the AASA file after deploy

```bash
curl -I https://seedkeep.app/.well-known/apple-app-site-association
```

Expected: `200 OK` with `content-type: application/json`. Also test the live
validator at <https://app-site-association.cdn-apple.com/a/v1/seedkeep.app>
once propagated — Apple caches AASA via that CDN.
