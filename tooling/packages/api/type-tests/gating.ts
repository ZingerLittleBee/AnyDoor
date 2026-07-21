// Compile-time assertions that a capability absent from the manifest is a type
// error when accessed. `@ts-expect-error` flips the polarity: tsc fails if the
// marked line does NOT error, so these lines prove the gating is real. This file
// is type-checked (noEmit) and never bundled or run.

import { defineManifest, definePlugin } from "../src/index.js";

const fetchOnly = defineManifest({
  id: "dev.anydoor.gate.fetch",
  name: "Fetch only",
  description: "Declares only fetch.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: ["fetch"],
});

definePlugin(fetchOnly, {
  async rows(_query, api) {
    // Declared capability: allowed.
    await api.fetch("https://example.com");
    // @ts-expect-error toast is not declared in the manifest
    await api.toast("info", "nope");
    // @ts-expect-error store is not declared in the manifest
    api.store.keys();
    return [];
  },
});

const pasteboardOnly = defineManifest({
  id: "dev.anydoor.gate.pasteboard",
  name: "Pasteboard only",
  description: "Declares only pasteboard.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: ["pasteboard"],
});

definePlugin(pasteboardOnly, {
  async action(_rowId, _actionId, _argument, api) {
    // The pasteboard capability is surfaced as `copy`.
    await api.copy("text");
    // @ts-expect-error openURL is not declared in the manifest
    await api.openURL("https://example.com");
    return null;
  },
});

const noCaps = defineManifest({
  id: "dev.anydoor.gate.none",
  name: "No capabilities",
  description: "A pure display plugin.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: [],
});

definePlugin(noCaps, {
  rows(_query, api) {
    // @ts-expect-error no capability is declared, so fetch is absent
    api.fetch;
    return [];
  },
});
