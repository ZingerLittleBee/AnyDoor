# @anydoor/api

Typed authoring API for AnyDoor **Script Plugins**. Type definitions plus a thin
runtime shim (`definePlugin`) and row descriptor builders (`actions`).

Targets the host `apiVersion: 1`. Milestone A makes no compatibility promise.

## Install

Scaffolded projects depend on this package automatically
(`@anydoor/create-plugin`). To add it by hand:

```bash
pnpm add @anydoor/api
```

## Usage

```ts
// src/manifest.ts
import { defineManifest } from "@anydoor/api";

export default defineManifest({
  id: "dev.anydoor.hn-top",
  name: "Hacker News Top",
  description: "Top stories from Hacker News.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: ["fetch", "openURL"],
});
```

```ts
// src/plugin.ts
import { definePlugin, actions } from "@anydoor/api";
import manifest from "./manifest.js";

definePlugin(manifest, {
  async rows(query, api) {
    const res = await api.fetch("https://hn.algolia.com/api/v1/search?tags=front_page");
    const hits = (JSON.parse(res.body).hits ?? []) as Array<{ objectID: string; title: string }>;
    return hits.map((hit) => ({
      id: hit.objectID,
      title: hit.title,
      action: actions.detail(),
    }));
  },
  detail(rowId) {
    return `# ${rowId}`;
  },
});
```

## Capability gating

`definePlugin` narrows the `api` handed to each entry point to the capabilities
the manifest declares. The manifest is the single source of truth:

```ts
capabilities: ["fetch"]         // in the manifest
// ...
async rows(query, api) {
  await api.fetch("...");       // ok
  await api.toast("info", "x"); // compile error: `toast` not declared
}
```

## Surface

- `defineManifest(manifest)` — identity helper that captures the declared
  capability tuple for type inference.
- `definePlugin(manifest, handlers)` — registers `rows` / `detail` / `action`
  with the host and injects the narrowed capability API.
- `actions` — builders for row commit actions: `detail()`, `openURL(url)`,
  `copy(text)`, `argument()`, `run(close?)`.
- Types: `Manifest`, `Capability`, `Row`, `RowAction`, `FetchOptions`,
  `FetchResponse`, `Store`, `ToastKind`, `DeclaredAPI`, `JSONValue`, and the
  per-capability function types.

### Capabilities

| Capability | Injected as | Signature |
| --- | --- | --- |
| `fetch` | `api.fetch` | `(url, options?) => Promise<FetchResponse>` |
| `store` | `api.store` | `{ get, set, delete, keys }` |
| `toast` | `api.toast` | `(kind, message) => Promise<void>` |
| `pasteboard` | `api.copy` | `(text) => Promise<void>` |
| `delay` | `api.delay` | `(ms) => Promise<void>` |
| `openURL` | `api.openURL` | `(url) => Promise<void>` |

`openURL` accepts only `http` and `https` URLs — the host rejects any other
scheme (e.g. `file:` or a custom app scheme) with a rejected promise, so a
plugin cannot use it to reach the filesystem or launch arbitrary apps. The same
restriction applies to a row's `openURL` commit action.

### Entry points

| Entry point | Signature | Purpose |
| --- | --- | --- |
| `rows` | `(query, api) => Row[] \| Promise<Row[]>` | Root palette rows for a query. |
| `detail` | `(rowId, api) => string \| Promise<string>` | Markdown Detail for a row. |
| `action` | `(rowId, actionId, argument, api) => unknown` | Run a row action. |
