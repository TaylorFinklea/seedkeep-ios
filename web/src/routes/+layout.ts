// Cascades prerendering to every child route. adapter-static refuses
// to build unless every route is prerenderable (or a fallback page is
// declared), so this is the single switch that makes the whole site
// SSG-friendly. Mirrors the Open Feelings web pattern.
export const prerender = true;
