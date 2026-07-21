# __PLUGIN_NAME__

An AnyDoor Script Plugin. It fetches the Hacker News front page, lists the
stories as searchable command-palette rows, drills into a per-row markdown
Detail, and opens a story in the browser.

## Layout

```
src/manifest.ts   Plugin manifest (id, capabilities, localized names). Single
                  source of truth for the declared capabilities.
src/plugin.ts     Entry points: rows() / detail() / action().
build.mjs         Bundles src/plugin.ts -> dist/bundle.js and emits
                  dist/manifest.json.
dist/             Build output. This directory is the loadable plugin package.
```

## Build

```bash
pnpm install
pnpm build
```

`dist/` now holds `manifest.json` + `bundle.js` — a valid Script Plugin package.

## Develop (the Dev Plugin loop)

The fast edit-to-palette loop uses **Dev Plugin** mode, which loads a package
directory in place and reloads it on change:

1. In AnyDoor, open **Settings -> Plugins** and enable **developer mode**.
2. Register this project's `dist/` directory as a Dev Plugin.
3. Run the watch build:

   ```bash
   pnpm dev
   ```

   Every save rebuilds `dist/`, and AnyDoor reloads the plugin automatically —
   your changed rows/Detail appear in the palette within seconds.

To debug with breakpoints, attach Safari's Web Inspector to the plugin's
JavaScript context (Develop menu -> your machine -> the plugin context).

## Capabilities

Declared in `src/manifest.ts` as `capabilities`. This plugin uses `fetch` and
`openURL`. A capability you did not declare there is a compile-time error if you
try to use it in `plugin.ts` — the manifest is the security boundary.

## API version

Built against `apiVersion: 1`. During this milestone the API may change with the
host; there is no compatibility promise yet.
