import { defineManifest } from "@anydoor-dev/api";

// The V2EX plugin manifest. `defineManifest` captures the declared capability
// list so `definePlugin` (in plugin.ts) narrows the capability API to exactly
// what is declared here — asking for an undeclared capability is a compile
// error. build.mjs imports this module and writes the validated object to
// dist/manifest.json; it is the single source of truth for the manifest.
export default defineManifest({
  id: "v2ex",
  name: "V2EX",
  description: "Browse V2EX hot and latest topics as a searchable list.",
  version: "1.0.0",
  apiVersion: 1,
  // fetch     — the public v1 topic feeds and the token-gated v2 topic/replies.
  // store     — persist the optional personal access token across invocations.
  // toast     — confirm token saves and settings-page opens.
  // openURL   — open the V2EX token settings page from the token row.
  // translate — translate topic bodies and comments in Detail (opt-in row).
  capabilities: ["fetch", "store", "toast", "openURL", "translate"],
  localizedNames: {
    zh: "V2EX",
  },
  localizedDescriptions: {
    zh: "以可搜索列表浏览 V2EX 热门与最新主题。",
  },
});
