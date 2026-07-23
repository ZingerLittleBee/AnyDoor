# @anydoor/create-plugin

Scaffold a new [AnyDoor](https://github.com/ZingerLittleBee/AnyDoor) Script
Plugin: a ready-to-build TypeScript + esbuild project with the typed
[`@anydoor/api`](https://www.npmjs.com/package/@anydoor/api) wired in.

## Usage

```bash
pnpm create @anydoor/plugin my-plugin
# or: pnpm dlx @anydoor/create-plugin my-plugin

cd my-plugin
pnpm install
pnpm build   # → dist/manifest.json + dist/bundle.js
```

`dist/` is a complete Script Plugin package: install it from AnyDoor's
Settings → Plugins → Install Script Plugin…, or register the directory as a
Dev Plugin (developer mode) and run `pnpm dev` for hot reload on every build.

## Options

```
create-anydoor-plugin <target-dir> [options]

--id <id>          Plugin id (manifest id). Default: derived from the dir name.
--name <name>      Display name. Default: derived from the dir name.
--api-spec <spec>  Dependency spec for @anydoor/api. Default: a caret range on
                   the published package; pass a file: spec to build against a
                   local checkout.
--force            Allow scaffolding into a non-empty directory.
```

## What you get

- `src/manifest.ts` — manifest with declared capabilities (the sandbox
  boundary: the plugin can only use what it declares).
- `src/plugin.ts` — typed entry points (`rows` / `list` / `detail` / `action`)
  via `definePlugin`, with the capability API narrowed to the manifest.
- `build.mjs` — esbuild bundling to a single plain-JS ES module (no Node
  built-ins), plus `pnpm dev` watch mode.

See the [`@anydoor/api` documentation](https://www.npmjs.com/package/@anydoor/api)
for the full authoring surface, and worked examples under
[`tooling/examples`](https://github.com/ZingerLittleBee/AnyDoor/tree/main/tooling/examples).
