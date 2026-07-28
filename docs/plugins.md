# Plugins

AnyDoor has two kinds of plugins:

- **Native Plugins** — first-party feature modules that ship inside the app
  and are switched on and off from Settings. Today: Image Conversion and
  Hosts management.
- **Script Plugins** — third-party packages you install yourself, authored in
  TypeScript and executed in a capability sandbox. They extend the command
  palette.

Both kinds share the same rule: an uninstalled plugin is invisible everywhere
(no panel rows, no palette commands, no hotkeys, no settings), and its user
data is retained, so reinstalling restores it — without a relaunch.

## Native Plugins

Native Plugin code always ships with the app; "install" is a logical state,
never a download (ADR-0005). Managed from **Settings → Plugins**:

- **Install** makes the plugin exist: its panel rows, palette commands,
  hotkeys, and settings appear immediately.
- **Uninstall** removes every surface but keeps SwiftData rows, preferences,
  and recorded hotkeys. It never mutates user-visible system state — e.g.
  uninstalling Hosts leaves active `/etc/hosts` entries in effect until you
  reinstall — and it is transactional: if deactivation fails, the plugin
  stays installed rather than half-removed.
- A retained hotkey is given up only if you rebind it to something else while
  the plugin is uninstalled; the newer binding wins on reinstall.
- Upgrading users are migrated by usage: if you had used a feature before it
  became a plugin (Hosts profiles exist, conversion history exists), it
  arrives pre-installed. Fresh installs start with everything uninstalled.
- The installed set travels in config backup and sync, so importing a backup
  or pointing a second Mac at your sync folder reproduces your plugin setup
  through the real install/uninstall lifecycle.

## Script Plugins

A Script Plugin is a folder (or zip) containing a manifest and a single pure
JavaScript bundle. It runs on the system JavaScriptCore — AnyDoor bundles no
JS runtime — one isolated context per plugin, so a broken plugin never stalls
another (ADR-0008).

**Palette surface.** Script Plugins contribute rows to the command palette:
searchable root rows, drill-in second-level lists (searchable, paginated),
and markdown detail pages (paginated, with optional footer actions). They add
no panel rows and no recordable hotkeys.

**Capability sandbox (ADR-0009).** A plugin can only use what its manifest
declares; an undeclared capability simply does not exist in its context. The
full grantable set:

| Capability | What it allows |
| --- | --- |
| `fetch` | Network requests |
| `store` | A private key-value store (survives uninstall/reinstall) |
| `toast` | Showing a toast |
| `copy` | Writing to the clipboard (never lands in clipboard history) |
| `delay` | A one-shot timer |
| `openURL` | Opening http/https URLs only — enforced everywhere |
| `translate` | Translating through your configured services |

No shell, no AppleScript, no filesystem, no clipboard *read*. A synchronous
or async runaway script is killed by a 30-second dual watchdog; the plugin's
next invocation gets a fresh context. Failures are recorded per plugin at
`~/Library/Application Support/dev.bybee.AnyDoor/ScriptPlugins/logs/<id>.log`.

Script Plugins are machine-local by design: install state, private stores,
and developer mode never travel in backup or config sync.

## Installing a Script Plugin

Ready-to-install example plugins — a V2EX browser and a Hacker News browser —
are attached to every
[release](https://github.com/ZingerLittleBee/AnyDoor/releases) as
`plugin-*.zip`.

**From a zip:**

1. Download the plugin, e.g.
   [plugin-v2ex.zip](https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/plugin-v2ex.zip)
   or
   [plugin-hackernews.zip](https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/plugin-hackernews.zip).
2. Open **Settings → Plugins → Install Script Plugin…** and pick the zip — no
   unzipping needed (an unzipped package folder works too).
3. The plugin's rows appear in the command palette immediately, no relaunch.

**From an install link:** paste an
`anydoor://install-plugin?url=<https zip url>` link into your browser's
address bar and AnyDoor takes over — it downloads the package (capped at
20 MiB) and shows a confirmation with the plugin's name, id, version,
download origin, and declared capabilities before installing. Only https
package URLs are accepted. For example:

```
anydoor://install-plugin?url=https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/plugin-v2ex.zip
```

Uninstall any time from **Settings → Plugins**; a Script Plugin's private
data is kept, so reinstalling the same plugin finds it again.

## Writing your own

- Scaffold with `pnpm create @anydoor-dev/plugin my-plugin`. Entry points are
  typed by [`@anydoor-dev/api`](https://www.npmjs.com/package/@anydoor-dev/api),
  whose `definePlugin` narrows the API surface to exactly the capabilities
  your manifest declares — the sandbox boundary checked at compile time.
- Or start from the
  [anydoor-plugin-template](https://github.com/ZingerLittleBee/anydoor-plugin-template)
  repository, whose release workflow attaches the installable `plugin-*.zip`
  on every version tag.
- **Developer mode** (Settings → Plugins) registers a local directory as a
  Dev Plugin loaded in place: run your bundler in watch mode and every build
  reaches the palette within seconds — no reinstall, no relaunch. Dev Plugins
  surface full error messages and stacks where installed plugins show only a
  generic inline error.
- Plugin JS contexts are inspectable with Safari's Web Inspector.
- Worked examples live under [`tooling/examples`](../tooling/examples).

## Design records

- [ADR-0005 — Native Plugins ship in the binary; install is a logical state](adr/0005-native-plugins-logical-install.md)
- [ADR-0006 — Plugin commands claim enum cases](adr/0006-plugin-commands-claim-enum-cases.md)
- [ADR-0007 — Plugin rows are descriptors](adr/0007-plugin-rows-are-descriptors.md)
- [ADR-0008 — Script Plugins run on JavaScriptCore](adr/0008-script-plugins-run-on-javascriptcore.md)
- [ADR-0009 — Capabilities are the Script Plugin sandbox](adr/0009-capabilities-are-the-script-plugin-sandbox.md)
- Contributor playbook for adding or modifying a Native Plugin:
  [`docs/agents/native-plugins.md`](agents/native-plugins.md)
