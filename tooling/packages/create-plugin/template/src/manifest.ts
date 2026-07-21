import { defineManifest } from "@anydoor/api";

// The plugin manifest. `defineManifest` captures the declared capability list so
// `definePlugin` (in plugin.ts) narrows the capability API to exactly what is
// declared here — asking for an undeclared capability is a compile error.
//
// build.mjs imports this module and writes the validated object to
// dist/manifest.json; it is the single source of truth for the manifest.
export default defineManifest({
  id: "__PLUGIN_ID__",
  name: "__PLUGIN_NAME__",
  description: "Top stories from Hacker News as a searchable list.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: ["fetch", "openURL"],
  localizedNames: {
    zh: "Hacker News 热门",
  },
  localizedDescriptions: {
    zh: "以可搜索列表展示 Hacker News 热门文章。",
  },
});
