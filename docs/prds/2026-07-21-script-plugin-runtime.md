# PRD: Script Plugin Runtime & Local Sideload (Milestone A)

- **Status:** planned
- **Date:** 2026-07-21
- **Tracker:** local (`docs/prds/`, issues under `docs/issues/`)
- **Glossary:** [Ubiquitous Language](../../CONTEXT.md#plugins)
- **Decisions:** ADR-0008 (JavaScriptCore execution), ADR-0009 (capability sandbox)
- **Predecessor:** [Native Plugin Architecture](2026-07-16-native-plugin-architecture.md) (V1)

## Problem Statement

Every AnyDoor feature is written by us, in Swift, inside the app. A user who
wants "latest posts from my forum as a searchable list" — a trivial
API-glue feature — has no path shorter than a feature request. V1 built the
plugin seam (registry, lifecycle, descriptor-based palette surfaces) but
every plugin still compiles into the binary. The missing piece is a way for
code written outside the app, by someone who is not us, to contribute
palette entries safely.

## Solution

Introduce **Script Plugins**: TypeScript-authored, esbuild-bundled
pure-JavaScript packages the user Sideloads from Settings → Plugins,
executed in-process on the system JavaScriptCore (ADR-0008) and able to act
only through six declared Capabilities (ADR-0009). A Script Plugin
contributes to the command palette only: searchable root rows, a
drill-in markdown Detail, and Row Actions. Script Plugins join the V1
`PluginRegistry` as a second plugin kind, sharing the Install/Uninstall
vocabulary and the "uninstalled = invisible everywhere, data retained"
invariants. This milestone deliberately excludes any store: the audience is
the developer and sideloading power users, so the capability API can be
polished against real plugins before any compatibility promise is made.

## User Stories

1. As a user, I want to install a Script Plugin by picking a local package from Settings → Plugins, so that adding a plugin needs no store and no relaunch.
2. As a user, I want Script Plugins listed in the same Plugins tab as Native Plugins (grouped by kind, with name, description, version, and install state), so that one place manages all plugins.
3. As a user, I want to uninstall a Script Plugin and have its palette entries disappear at once while its private storage is retained, so that uninstall means invisible, not data loss.
4. As a user, I want a reinstalled Script Plugin (same id) to find its previous private storage, so that reinstalling restores my data like it does for Native Plugins.
5. As a palette user, I want a Script Plugin's rows searchable at the root by title and subtitle, so that plugin content is reachable exactly like built-in content.
6. As a palette user, I want selecting a row to open its markdown Detail in place, and Esc/Backspace to walk back, so that drill-in matches the palette's existing navigation.
7. As a palette user, I want Row Actions (open URL, copy via the self-write funnel, invoke a plugin function) on a selected row, so that a list plugin can act, not just display.
8. As a palette user, I want a loading state while a plugin builds rows and an inline error row when it fails, so that a broken plugin degrades visibly instead of hanging the palette.
9. As a user, I want a plugin that hangs or loops to be cut off after a hard timeout without affecting the app or other plugins, so that one bad plugin cannot take AnyDoor down.
10. As a user, I want a plugin's own copy action to never appear in my clipboard history, so that plugin pasteboard writes behave like the app's own.
11. As a user, I want a plugin needing an input to use the palette's existing Argument input mode, so that parametrized commands feel native.
12. As a user, I want a Script Plugin to have exactly the capabilities its manifest declares and nothing else, so that what a plugin *can* do is inspectable before running it.
13. As a user on a plugin with a wrong `apiVersion`, I want a clear refusal message instead of a broken load, so that version mismatches are diagnosable.
14. As a backup user, I want Script Plugin install state and data excluded from config backup, so that a restore never claims to restore plugins whose packages only exist on another machine.
15. As a plugin author, I want to register a directory as a Dev Plugin (developer mode only) with automatic reload on file change, so that the edit-to-palette loop is seconds.
16. As a plugin author, I want typed APIs from an npm package and a scaffold that produces a building plugin, so that the first plugin costs minutes, not archaeology.
17. As a plugin author, I want to attach Safari Web Inspector to my plugin's context, so that I debug with breakpoints instead of print statements.
18. As a plugin author, I want per-plugin log files and visible error details in Dev Plugin mode, so that failures in the field and in development are both diagnosable.
19. As the developer, I want Script Plugins to join `PluginRegistry` as a second kind sharing lifecycle and surface publication, so that the V1 invariants (exclusive surfaces, uninstalled invisibility) hold without a parallel registry.
20. As the developer, I want Script Plugin identity (`ScriptPluginID`) distinct from `NativePluginID` and row sources namespaced through the existing `PluginRowSourceKey`, so that ids cannot collide across kinds or plugins.

## Implementation Decisions

- **Runtime.** One `JSContext` per installed plugin on a dedicated serial
  background queue; capability implementations run on the main actor and are
  bridged as promise-returning functions. A 30-second watchdog per
  invocation; timeout or unrecoverable exception destroys and lazily
  recreates the context. Contexts are inspectable. (ADR-0008)
- **Capabilities.** `fetch`, private key-value store, toast, pasteboard
  write via the host self-write funnel, one-shot delay, open URL. Injected
  only when declared in the manifest. No shell, no AppleScript, no
  filesystem, no pasteboard read. (ADR-0009)
- **Package format.** A directory: `manifest.json` (id, name, description,
  version, `apiVersion: 1`, entry point, declared capabilities, optional
  per-language name/description), `bundle.js` (single ES-module bundle),
  optional `icon.png`. Installing copies the package to
  `Application Support/dev.bybee.AnyDoor/ScriptPlugins/<id>/`; a Dev Plugin
  is loaded in place from its development directory and auto-reloads,
  available only behind a developer-mode switch — in-place loading must
  never apply to store-installed plugins later.
- **Identity.** `ScriptPluginID` is its own type. Store-era ids will be
  author-namespaced (`author.plugin`); the manifest spec documents this from
  day one. Row sources register through `PluginRowSourceKey` as in V1.
- **Palette surface.** Script Plugins contribute root row sources through
  the existing generic `pluginRow` channel; a new descriptor adds the
  markdown **Detail** presentation (system `AttributedString(markdown:)`,
  no third-party renderer until a real plugin justifies it) and **Row
  Actions**. No Form, no Grid, no webview. No menu-panel rows, no
  recordable hotkeys — the open command identity those require is deferred
  until a real plugin needs it.
- **Storage.** The private key-value store is host-owned, persisted per
  plugin id outside SwiftData, and survives uninstall/reinstall. It is
  machine-local and never enters `BackupSnapshot`; the installed Script
  Plugin set stays out of the settings-sync whitelist for this milestone.
- **Versioning.** `apiVersion` is required and gated at load. During
  milestone A the API may break without compatibility shims; the
  compatibility promise starts with the store milestone.
- **Localization.** Plugin strings are the author's problem; the manifest
  optionally carries per-language name/description. No host string-catalog
  integration.
- **Tooling.** A separate npm workspace ships `@anydoor/api` (type
  definitions + runtime shim) and a `create-anydoor-plugin` scaffold
  (TypeScript + esbuild template). The tooling is in scope for this
  milestone, not an add-on: without it the authoring experience is hostile
  enough to defeat the milestone's purpose.
- **Diagnostics.** Per-plugin log files under `Logs/ScriptPlugins/<id>.log`;
  action failures surface as failure toasts, row/detail failures as inline
  error states; Dev Plugin mode shows error details directly.

## Testing Decisions

- The engine is never mocked: tests run real `JSContext`s against small
  fixture plugins (inline JS sources), consistent with the repo's
  no-mocking philosophy. Network is the one true external boundary; the
  `fetch` capability is tested against a local test server or an injected
  transport at that boundary only.
- **Runtime protection:** a fixture that loops is killed by the watchdog,
  its context recreated, and a sibling plugin's invocations unaffected; a
  throwing fixture yields the inline error state, never a crash.
- **Capability gating:** a fixture that references an undeclared capability
  finds it absent; declared capabilities behave (pasteboard write suppresses
  history via the real funnel).
- **Manifest validation:** missing fields, unknown `apiVersion`, and
  duplicate ids are rejected with typed errors.
- **Registry integration** extends the V1 lifecycle tests: install
  publishes rows to a visible palette, uninstall removes them and retains
  the store, reinstall finds prior data.
- **Palette behavior** extends commit-intent and navigation tests: Detail
  push/pop under Esc/Backspace policy, Row Action commit semantics.
- Not tested: SwiftUI view layers (repo convention) and the Safari Web
  Inspector attachment (external tooling).

## Out of Scope

- **Store / distribution** — registry backend, download, signing, review,
  updates, ratings; a later milestone. The manifest capability declaration
  and author-namespaced ids exist now so the store needs no format break.
- **Menu-panel rows and recordable hotkeys** for Script Plugins — requires
  opening the closed command identity (ADR-0006's surroundings); deferred
  until a real plugin demonstrates the need.
- **Form and Grid descriptors; webview Detail** — the Argument input mode
  covers parametrized commands; rendering third-party HTML is a security
  decision that deserves its own milestone.
- **Shell, AppleScript, filesystem, pasteboard-read capabilities**
  (ADR-0009), and any background-refresh / `setInterval` scheduling.
- **Backup/sync of Script Plugin state** — machine-local this milestone.
- **API compatibility guarantees** — explicitly none until the store.
- **Localization through the host catalog** for plugin content.

## Further Notes

- Vocabulary is canonical in the glossary's Plugins section: Script Plugin,
  Capability, Sideload, Dev Plugin, and the generalized Install/Uninstall.
  UI copy stays 「安装」/「卸载」 for both plugin kinds; 「链接」 remains
  reserved for Quicklinks, which is why the in-place development load is
  named Dev Plugin, not "linked plugin".
- Rough sequencing for planning: runtime + capabilities first (testable
  headless), then manifest/loading + registry kind, then the palette Detail
  surface, then Settings UI + Dev Plugin mode, then the npm tooling.
  Issue slicing happens at planning time, not in this PRD.
- Estimated effort recorded at decision time: roughly 6–8 weeks solo,
  including the npm tooling.
