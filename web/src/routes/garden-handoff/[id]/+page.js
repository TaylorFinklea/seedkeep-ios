// Retired notice for old /garden-handoff/<id> links from test versions. The [id]
// parameter is unknowable at build time, so this route is not prerendered; the
// SPA fallback (200.html) serves it at runtime. The page reads no parameters and
// makes no requests.
export const prerender = false;
