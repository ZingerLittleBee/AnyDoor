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
- `definePlugin(manifest, handlers)` — registers `rows` / `list` / `detail` /
  `action` with the host and injects the narrowed capability API.
- `actions` — builders for row commit actions: `detail()`, `list(listId)`,
  `openURL(url)`, `copy(text)`, `argument()`, `run(close?)`.
- Types: `Manifest`, `Capability`, `Row`, `RowAction`, `DetailResult`,
  `FetchOptions`, `FetchResponse`, `Store`, `ToastKind`, `DeclaredAPI`,
  `JSONValue`, and the per-capability function types.

### Capabilities

| Capability | Injected as | Signature |
| --- | --- | --- |
| `fetch` | `api.fetch` | `(url, options?) => Promise<FetchResponse>` |
| `store` | `api.store` | `{ get, set, delete, keys }` |
| `toast` | `api.toast` | `(kind, message) => Promise<void>` |
| `pasteboard` | `api.copy` | `(text) => Promise<void>` |
| `delay` | `api.delay` | `(ms) => Promise<void>` |
| `openURL` | `api.openURL` | `(url) => Promise<void>` |
| `translate` | `api.translate` | `(text) => Promise<string>` |

`openURL` accepts only `http` and `https` URLs — the host rejects any other
scheme (e.g. `file:` or a custom app scheme) with a rejected promise, so a
plugin cannot use it to reach the filesystem or launch arbitrary apps. The same
restriction applies to a row's `openURL` commit action.

`translate` translates text into the user's configured target language through
the translation service the user set up in AnyDoor's Settings. The plugin
cannot choose the direction or the service; the source language is
auto-detected. The promise rejects when no usable translation service is
configured, when the provider fails, or when the text exceeds 10,000
characters (free providers have hard length limits and LLM providers bill by
volume — which is also why this is a declared capability: it can spend the
user's paid API quota).

### Entry points

| Entry point | Signature | Purpose |
| --- | --- | --- |
| `rows` | `(query, api) => Row[] \| Promise<Row[]>` | Root palette rows for a query. |
| `list` | `(listId, query, api) => Row[] \| Promise<Row[]>` | Second-level rows for a committed `list` action. |
| `detail` | `(rowId, api, cursor?) => DetailResult \| Promise<DetailResult>` | Markdown Detail for a row, optionally chunked (see below). |
| `detailAction` | `(rowId, actionId, api) => DetailResult \| Promise<DetailResult>` | Rebuild the Detail for a pressed footer action (see below). |
| `action` | `(rowId, actionId, argument, api) => unknown` | Run a row action. |

## Detail markdown

The host renders a Detail with the system markdown parser (no third-party
renderer). Block structure it lays out:

- headings (`#`…`######`), paragraphs, ordered/unordered lists, fenced code
  blocks, thematic breaks (`---`)
- **blockquotes** (`> …`) — drawn with a leading bar in secondary text, visually
  distinct from body paragraphs. Use them for quoted or secondary content such
  as comments; a multi-paragraph quote stays one visual unit, separate quotes
  stay separate.
- **image previews** — `![alt](url)` renders inline (async loaded, capped
  height, tappable-link fallback on failure). Only `http`/`https` image URLs
  load; any other scheme is dropped, never fetched. Bare image URLs in plain
  text are *not* auto-detected — if your data source is plain text, rewrite
  them into `![](url)` yourself (see `examples/v2ex`'s `withImagePreviews`).
- inline bold / italic / inline code / links survive inside every block. Tapped
  links are scheme-guarded like `openURL`.

## Detail pagination (load more on scroll)

`detail` may return a chunk instead of a plain string:

```ts
async detail(rowId, api, cursor) {
  const page = cursor === undefined ? 1 : Number(cursor);
  const items = await fetchPage(rowId, page, api);
  return {
    markdown: page === 1 ? renderDocument(items) : renderItems(items),
    more: items.length === PAGE_SIZE ? String(page + 1) : undefined,
  };
},
```

- A returned `more` cursor makes the host show a loading sentinel at the bottom
  of the Detail; when the user scrolls to it, the host calls
  `detail(rowId, api, cursor)` with that cursor and appends the returned
  chunk's markdown below the rendered document.
- The cursor is **opaque to the host** — encode whatever pagination state you
  need (a page number, an API-issued token). It round-trips verbatim.
- Omitting `more` (or returning a plain string) marks the document complete.
- An empty chunk ends pagination cleanly; a thrown error keeps what is already
  rendered and stops paginating. The host never issues more than one chunk
  fetch at a time.

## Detail actions (footer buttons)

A `DetailResult` may declare footer `actions` — buttons the host renders in a
bar at the bottom of the Detail:

```ts
async detail(rowId, api) {
  return {
    markdown: renderOriginal(rowId),
    actions: [{ id: "translate", label: "翻译" }],
  };
},
async detailAction(rowId, actionId, api) {
  // Rebuild the whole document for the pressed action; the result replaces
  // the rendered Detail (its own markdown, `more` cursor, and next actions).
  return {
    markdown: await renderTranslated(rowId, api),
    actions: [{ id: "original", label: "显示原文" }],
  };
},
```

- Pressing a button drops the Detail to its loading state and calls
  `detailAction(rowId, actionId, api)`; the result replaces the document
  wholesale. Declare the *next* mode's actions on each result to build a
  toggle (翻译 ⇄ 显示原文).
- Actions are read from full documents only — an appended pagination chunk's
  `actions` are ignored. Encode any mode into your `more` cursor so
  scroll-loaded pages stay consistent with the rebuilt document.
- Declaring `actions` without implementing `detailAction` surfaces an inline
  error when pressed.
