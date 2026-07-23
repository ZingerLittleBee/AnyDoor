import { defineManifest } from "@anydoor-dev/api";

// The Hacker News plugin manifest. `defineManifest` captures the declared
// capability list so `definePlugin` (in plugin.ts) narrows the capability API
// to exactly what is declared here — asking for an undeclared capability is a
// compile error. build.mjs imports this module and writes the validated object
// to dist/manifest.json; it is the single source of truth for the manifest.
export default defineManifest({
  id: "hackernews",
  name: "Hacker News",
  description: "Browse Hacker News stories and comments — no account needed.",
  version: "1.0.0",
  apiVersion: 1,
  // fetch     — the official Firebase story feeds and the Algolia item API
  //             (full comment tree in one request); both are public, no token.
  // store     — persist the Detail-translation toggle across invocations.
  // toast     — surface translation failures without breaking the Detail.
  // translate — translate story bodies and comments in Detail (opt-in row).
  capabilities: ["fetch", "store", "toast", "translate"],
  localizedNames: {
    zh: "Hacker News",
  },
  localizedDescriptions: {
    zh: "浏览 Hacker News 文章与评论，无需账号。",
  },
});
