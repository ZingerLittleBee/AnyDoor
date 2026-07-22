# AnyDoor Script Plugin tooling

The authoring toolchain for AnyDoor **Script Plugins** — TypeScript-authored,
esbuild-bundled pure-JavaScript packages the user sideloads from
**Settings -> Plugins**. See `docs/issues/018-script-plugin-runtime.md` for the
runtime and `docs/issues/024-plugin-author-tooling.md` for this workspace.

This is a standalone pnpm workspace. It does not participate in the SwiftPM build
(SwiftPM only reads `Sources/`, `Tests/`, and `Plugins/`), so `swift build` and
`swift test` never need Node or pnpm.

## Packages

| Package | What it is |
| --- | --- |
| [`@anydoor/api`](packages/api) | The typed authoring API: type definitions plus the thin runtime shim (`definePlugin`) and descriptor builders (`actions`). |
| [`@anydoor/create-plugin`](packages/create-plugin) | The scaffold. Generates a building TypeScript plugin: manifest, typed entry point, esbuild bundle. |

## Examples

Worked-example plugins live under [`examples/`](examples). They are **not** pnpm
workspace members (the workspace only globs `packages/*`): each carries its own
`pnpm-workspace.yaml` sentinel and wires `@anydoor/api` through a `file:`
dependency, so `pnpm install && pnpm build` runs standalone inside the example
directory. `pnpm verify` builds and asserts them alongside the scaffold template.

- [`examples/v2ex`](examples/v2ex) — a V2EX viewer: merged hot/latest topic list,
  per-topic markdown Detail with image previews, scroll-paginated comments, and
  opt-in translation, plus an optional stored access token
  (`fetch` + `store` + `toast` + `openURL` + `translate`).
- [`examples/hackernews`](examples/hackernews) — a Hacker News browser: five
  public story feeds, per-story Detail with the full comment thread (fetched in
  one Algolia request, paginated client-side), HTML-to-markdown conversion, and
  opt-in translation — no token anywhere
  (`fetch` + `store` + `toast` + `translate`).

## Requirements

- Node >= 18
- pnpm (the repo's JS/TS package manager)

## Quick start

```bash
cd tooling
pnpm install
pnpm build                      # build @anydoor/api

# Scaffold a new plugin next to the tooling tree
node packages/create-plugin/bin/create.mjs ../my-first-plugin
cd ../my-first-plugin
pnpm install
pnpm build                      # -> dist/manifest.json + dist/bundle.js
```

`dist/` is a valid Script Plugin package: a `manifest.json` (validated against
the host's `ScriptPluginManifest` shape) plus a single ES-module `bundle.js` that
loads on plain JavaScriptCore with no Node built-ins.

## The default development flow: the Dev Plugin loop

Once a plugin is scaffolded, the intended edit-to-palette loop is **Dev Plugin**
mode — the host loads a package directory in place (never a copy) and reloads it
whenever the files change:

1. In AnyDoor, open **Settings -> Plugins** and turn on **developer mode**
   (machine-local; off by default).
2. Register your project's `dist/` directory as a Dev Plugin.
3. Run the watch build in the project:

   ```bash
   pnpm dev        # esbuild --watch: rebuilds dist/ on every save
   ```

   The host's directory watcher picks up each rebuild and reloads the plugin's
   JavaScript context, so changed rows, Detail, and actions surface in the
   command palette within seconds — no reinstall, no relaunch.

Dev Plugin loading is gated behind the developer-mode switch and only ever
applies to a development directory; installed (sideloaded) plugins are always run
from their copied-in package.

## Capability typing

A plugin declares its capabilities once, in `src/manifest.ts`, through
`defineManifest`. `definePlugin` infers the declared capability tuple from that
manifest and hands each entry point an API narrowed to exactly those
capabilities. Using a capability the manifest does not declare is a compile-time
error — the manifest is the security boundary (ADR-0009), and the types enforce
it before the host ever does.

The seven capabilities: `fetch`, `store`, `toast`, `pasteboard` (exposed as
`copy`), `delay`, `openURL`, `translate`.

## Verification

```bash
pnpm verify
```

`scripts/verify.mjs` builds `@anydoor/api`, scaffolds the template into a temp
directory, installs and builds it, and asserts the output:

- `manifest.json` validates against the documented manifest shape,
- `bundle.js` is a single file with no `export`/`import` statements and no Node
  built-ins,
- the bundle self-registers a plugin whose `rows` / `detail` / `action` entry
  points are functions (run in a Node `vm` with only the host's `registerPlugin`
  bridge — no faked JavaScriptCore host).

The definitive end-to-end check — the generated bundle loading on real
JavaScriptCore — is a Swift test (`Tests/AnyDoorTests/ScriptPluginToolingTemplateTests.swift`)
that runs a committed prebuilt copy of the template output through the real
`ScriptPluginRuntime`. That fixture is regenerated with
`node scripts/refresh-fixture.mjs`.

## Versioning

`@anydoor/api` targets the host `apiVersion: 1`. Milestone A makes **no
compatibility promise**: the API may break freely alongside the host until the
store milestone.
