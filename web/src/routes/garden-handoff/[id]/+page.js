// This route handles universal link fallback for /garden-handoff/<id>?token=<token>
// paths. The [id] parameter is the transfer ID, which is unknowable at build time,
// so we disable prerendering and rely on the adapter-static fallback (200.html)
// to serve this route at runtime.
export const prerender = false;
