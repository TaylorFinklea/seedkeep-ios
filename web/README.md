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

## Deploy notes

**Cloudflare Pages** is the easiest path. Connect this repo's `web/` directory,
set the build command to `npm run build`, output directory `build`. The
`static/_headers` file is honored automatically.

If you deploy somewhere that doesn't read `_headers` (e.g. plain GitHub Pages),
configure the host to serve `/.well-known/apple-app-site-association` with
`Content-Type: application/json` — Apple's universal-link validator rejects
anything else.

## Validating the AASA file after deploy

```bash
curl -I https://seedkeep.app/.well-known/apple-app-site-association
```

Expected: `200 OK` with `content-type: application/json`. Also test the live
validator at <https://app-site-association.cdn-apple.com/a/v1/seedkeep.app>
once propagated — Apple caches AASA via that CDN.
