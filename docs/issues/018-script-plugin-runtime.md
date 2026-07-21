---
id: 018
title: "Script Plugins: JavaScriptCore runtime, capability sandbox, and local sideload"
status: ready-for-agent
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

PRD: `docs/prds/2026-07-21-script-plugin-runtime.md` (milestone A, all user
stories). Decisions: ADR-0008 (JavaScriptCore execution), ADR-0009
(capability sandbox). Vocabulary: glossary Plugins section (Script Plugin,
Capability, Sideload, Dev Plugin, generalized Install/Uninstall).

## Problem Statement

Every AnyDoor feature is written by us, in Swift, inside the app binary. A
user who wants a trivial API-glue feature — "latest posts from my forum as
a searchable list with a detail view" — has no path shorter than filing a
feature request and waiting for a release. V1 built the plugin seam
(registry, lifecycle, descriptor-based palette surfaces), but every plugin
still compiles into the app: there is no way for code authored outside the
repository to contribute anything.

## Solution

Script Plugins: TypeScript-authored, esbuild-bundled pure-JavaScript
packages the user Sideloads from Settings → Plugins. They execute
in-process on the system JavaScriptCore and can act only through the six
Capabilities their manifest declares — network fetch, a plugin-private
key-value store, toasts, pasteboard writes through the host's self-write
funnel, a one-shot delay, and opening a URL. A Script Plugin contributes to
the command palette only: searchable root rows, a drill-in markdown Detail,
and Row Actions. Script Plugins join the existing registry as a second
plugin kind, sharing the Install/Uninstall vocabulary and the
"uninstalled = invisible everywhere, data retained" invariants. Plugin
authors get a typed npm API, a scaffold, in-place Dev Plugin loading with
auto-reload, and Safari Web Inspector debugging. No store exists in this
milestone; the audience is the developer and sideloading power users, so
the capability API can be polished against real plugins before any
compatibility promise is made.

## User Stories

1. As a user, I want to install a Script Plugin by picking a local package from Settings → Plugins, so that adding a plugin needs no store and no relaunch.
2. As a user, I want Script Plugins listed in the same Plugins tab as Native Plugins, grouped by kind with name, description, version, and install state, so that one place manages all plugins.
3. As a user, I want installing an invalid package (missing manifest fields, unknown apiVersion, duplicate id) to fail with a clear message and change nothing, so that a bad package can never half-install.
4. As a user, I want to uninstall a Script Plugin and have its palette entries disappear at once while its private storage is retained, so that uninstall means invisible, not data loss.
5. As a user, I want a reinstalled Script Plugin with the same id to find its previous private storage, so that reinstalling restores my data like it does for Native Plugins.
6. As a palette user, I want a Script Plugin's rows searchable at the root by title and subtitle, so that plugin content is reachable exactly like built-in content.
7. As a palette user, I want selecting a row to open its markdown Detail in place, and Esc/Backspace to walk back per the palette's existing escape policy, so that drill-in matches existing navigation.
8. As a palette user, I want Row Actions on a selected row — open URL, copy, or invoke a plugin function — so that a list plugin can act, not just display.
9. As a palette user, I want a loading state while a plugin builds rows and an inline error row when it fails, so that a broken plugin degrades visibly instead of hanging the palette.
10. As a palette user, I want an uninstalled Script Plugin to produce no rows, no Detail, and no search results at all, so that invisibility is complete rather than "greyed out".
11. As a user, I want a plugin that hangs or loops cut off after a hard timeout without affecting the app or other plugins, so that one bad plugin cannot take AnyDoor down.
12. As a user, I want a plugin whose invocation was killed to work again on the next invocation, so that a single failure is not a death sentence for the plugin.
13. As a user, I want a plugin's copy action to never appear in my clipboard history, so that plugin pasteboard writes behave like the app's own.
14. As a user, I want a plugin needing an input to use the palette's existing Argument input mode, so that parametrized commands feel native.
15. As a user, I want a Script Plugin to have exactly the capabilities its manifest declares and nothing else, so that what a plugin can do is inspectable before running it.
16. As a user, I want plugin failures surfaced as a failure toast for actions and inline states for rows and Detail, so that I always know whether the plugin or the app failed.
17. As a backup user, I want Script Plugin install state and data excluded from config backup, so that a restore never claims to restore plugins whose packages only exist on another machine.
18. As a plugin author, I want to register a directory as a Dev Plugin, available only behind a developer-mode switch, with automatic reload on file change, so that the edit-to-palette loop is seconds.
19. As a plugin author, I want typed APIs from an npm package and a scaffold that produces a building plugin, so that the first plugin costs minutes.
20. As a plugin author, I want to attach Safari Web Inspector to my plugin's context, so that I debug with breakpoints instead of print statements.
21. As a plugin author, I want per-plugin log files and visible error details in Dev Plugin mode, so that failures are diagnosable in development and in the field.
22. As a plugin author, I want my plugin's name and description optionally localizable per language in the manifest, so that Chinese and English users both get sensible listings.
23. As the developer, I want Script Plugins to join the registry as a second kind sharing lifecycle and surface publication, so that the V1 invariants hold without a parallel registry.
24. As the developer, I want Script Plugin identity distinct from Native Plugin identity and row sources namespaced through the existing per-plugin row-source key, so that ids cannot collide across kinds or plugins.
25. As the developer, I want the runtime exercised in tests through real JavaScriptCore with fixture packages, so that no mock engine can drift from production behavior.

## Implementation Decisions

- **Execution (ADR-0008).** One JavaScriptCore context per installed
  plugin on a dedicated serial background queue; capability implementations
  live on the main actor and are bridged as promise-returning functions. A
  hard 30-second watchdog per invocation; timeout or unrecoverable
  exception destroys the context, which is lazily recreated on the next
  invocation. Contexts are marked inspectable for Safari Web Inspector.
- **Capabilities (ADR-0009).** Exactly six: fetch, plugin-private
  key-value store, toast, pasteboard write via the host self-write funnel,
  one-shot delay, open URL. Injected only when declared in the manifest; an
  undeclared capability does not exist in the context. No shell,
  AppleScript, filesystem, or pasteboard read.
- **Package format.** A directory holding a manifest (id, name,
  description, version, required `apiVersion: 1`, entry point, declared
  capabilities, optional per-language name/description), a single
  ES-module bundle, and an optional icon. Installing copies the package
  into the app's Application Support area; a Dev Plugin loads in place from
  its development directory with auto-reload and exists only behind a
  developer-mode switch — in-place loading must never apply to
  store-installed plugins later.
- **Identity.** Script Plugin ids are their own type, never mixed with
  Native Plugin ids. Store-era ids will be author-namespaced
  (`author.plugin`); the manifest spec documents this now. Row sources
  register through the existing per-plugin row-source key.
- **Registry integration.** Script Plugins are a second plugin kind inside
  the existing plugin registry, sharing install/uninstall lifecycle,
  surface publication, exclusive-claim invariants, and live palette
  recomposition. Uninstall removes the installed package copy and all
  surfaces while retaining the private store; script deactivation tears
  down the context and has no external side effects, so the Native-style
  transactional failure path does not apply.
- **Palette surface.** Root rows flow through the existing generic plugin
  row channel. New descriptor work: a markdown Detail presentation
  (system markdown parsing, no third-party renderer) pushed as a new
  palette navigation level, and Row Actions mapped onto the existing
  commit-semantics classification. No Form, Grid, or webview; no
  menu-panel rows; no recordable hotkeys.
- **Storage.** The private key-value store is host-owned, persisted per
  plugin id outside SwiftData, survives uninstall/reinstall, is
  machine-local, and never enters the backup snapshot. The installed
  Script Plugin set stays out of the settings-sync whitelist.
- **Versioning.** `apiVersion` is required and gated at load with a typed
  refusal. The API may break freely during this milestone; compatibility
  promises start with the store milestone.
- **Diagnostics.** Per-plugin log files; action failures surface as
  failure toasts, row and Detail failures as inline error states; Dev
  Plugin mode shows error details directly.
- **Tooling.** A separate npm workspace ships the typed API package and a
  create-scaffold (TypeScript + esbuild template). In scope, not an
  add-on.

## Testing Decisions

A good test exercises external behavior at a seam — what the user or a
sibling subsystem observes — never engine internals. The engine is never
mocked.

- **Seams (one new, two reused).** The single new seam is the **plugin
  package boundary**: a real package directory (manifest + bundle) goes
  in, and tests observe palette descriptors and capability side effects
  coming out, with real JavaScriptCore underneath. Engine details
  (contexts, queues, watchdog) stay hidden below it. Reused seams: the V1
  **registry lifecycle seam** (install publishes surfaces, uninstall
  removes them, data retention across reinstall) and the palette's
  existing **pure policy seams** (commit-intent classification, escape
  policy, row-source registration).
- **Fixture plugins** are small inline-JS packages compiled into test
  resources; network is the one true external boundary and is exercised
  against a local test server or an injected transport at that boundary
  only, consistent with the repo's no-mocking philosophy.
- **Runtime protection:** a looping fixture is killed by the watchdog, its
  context recreated on the next invocation, and a sibling plugin's
  concurrent invocations complete unaffected; a throwing fixture yields
  the inline error state, never a crash.
- **Capability gating:** an undeclared capability is absent from the
  context; the pasteboard-write capability suppresses clipboard history
  through the real funnel.
- **Manifest validation:** missing fields, unknown apiVersion, and
  duplicate ids produce typed errors and no state change.
- **Registry integration** extends the V1 lifecycle tests (prior art: the
  registry tests run real pilot plugin instances): install publishes rows
  to an already-visible palette, uninstall removes them, reinstall finds
  prior private-store data.
- **Palette behavior** extends the existing commit-intent and
  escape-policy tests: Detail push/pop, Row Action commit semantics,
  invisibility when uninstalled.
- Not tested: SwiftUI view layers (repo convention), Safari Web Inspector
  attachment (external tooling), and the npm scaffold's generated project
  (validated by its own template CI later).

## Out of Scope

- Store, distribution, signing, review, updates, ratings — a later
  milestone; the manifest capability declaration and author-namespaced ids
  exist now so no format break is needed then.
- Menu-panel rows and recordable hotkeys for Script Plugins (requires
  opening the closed command identity around ADR-0006).
- Form and Grid descriptors; webview Detail.
- Shell, AppleScript, filesystem, and pasteboard-read capabilities; any
  background refresh or repeating timers.
- Backup/sync of Script Plugin state; API compatibility guarantees;
  host string-catalog localization of plugin content.

## Further Notes

- Sequencing inside this issue: runtime + capabilities first (headless,
  most testable), then manifest/loading + registry kind, then the palette
  Detail surface, then Settings UI + Dev Plugin mode, then npm tooling.
- UI copy uses 「安装」/「卸载」 for both plugin kinds; 「链接」 stays
  reserved for Quicklinks — hence the term Dev Plugin for in-place loading.
- Estimated effort recorded at decision time: roughly 6–8 weeks solo
  including tooling; this issue may be split at planning time along the
  sequencing above if slices need independent review.
