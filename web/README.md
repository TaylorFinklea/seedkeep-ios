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

The repo ships a `wrangler.toml` that configures the project as static-only
(no Worker code, just assets). The Cloudflare Workers Builds dashboard
settings for a fresh project:

| Setting | Value |
|---|---|
| **Build command** | `npm install && npm run build` |
| **Deploy command** | `npx wrangler deploy` |
| **Path / root directory** | `/web` (where this README lives — *not* `/web/build`) |
| **Non-production deploy** | `npx wrangler versions upload` (default) |

After the first deploy:

1. Add the custom domain `seedkeep.app` in the Cloudflare dashboard → Workers
   & Pages → seedkeep-web → Custom domains. DNS resolves automatically if the
   domain is on Cloudflare; otherwise add the CNAME record the dashboard
   shows.
2. Validate the AASA file:
   ```bash
   curl -I https://seedkeep.app/.well-known/apple-app-site-association
   ```
   Expected `200 OK` + `content-type: application/json`. Apple's CDN cache
   warms up over the next ~24 hours at
   <https://app-site-association.cdn-apple.com/a/v1/seedkeep.app>.

## Manual deploy (alternative)

If you'd rather skip the Cloudflare dashboard wiring and deploy from your
machine:

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
