# PRD: Native Plugin Architecture

- **Status:** ready-for-agent
- **Date:** 2026-07-16
- **Tracker:** local (`docs/prds/`, issues under `docs/issues/`)
- **Glossary:** [Ubiquitous Language](../../CONTEXT.md#plugins)
- **Decisions:** ADR-0005 (logical install), ADR-0006 (enum claim), ADR-0007 (row descriptors)

## Problem Statement

AnyDoor has grown from a hotkey toggle into a toolbox where every feature is
unconditionally present. A user who only wants clipboard history still carries
Hosts management, image conversion, and every other subsystem in their panel,
palette, and settings — and the codebase mirrors this: every feature can reach
into every other feature, so nothing can be reasoned about, removed, or (one
day) distributed as a unit. The user cannot say "I don't want this feature to
exist for me", and the developer cannot say "this feature is self-contained".

## Solution

Introduce **Native Plugins**: first-party feature modules the user installs or
uninstalls as one unit from a new Plugins tab in Settings. Installing is a
logical state change — code always ships with the app (ADR-0005) — but an
uninstalled plugin is invisible everywhere: it contributes no commands, no
panel rows, no palette entries, no settings, and requests no permissions.
Uninstalling cancels the plugin's in-flight work, releases shared host
resources, and keeps its user data so a reinstall restores everything; it is
transactional, with no half-uninstalled state, and it never mutates
user-visible system state or prompts for authorization (ADR-0005 addendum
2026-07-17). The pilot plugins are **Hosts**
(heavy side effects: privileged writes, a helper daemon, an editor window) and
**Image Conversion** (own window, own SwiftData model, no side effects) —
two deliberately different shapes so the plugin interface cannot overfit to
one. Everything not claimed by a plugin remains the **Core**, which never
names a plugin in its control flow. Existing users are migrated by usage
trace so nobody loses a feature they were using.

## User Stories

1. As a new user, I want the default install to surface only Core features, so that my panel and palette contain nothing I didn't ask for.
2. As a user, I want a Plugins tab in Settings listing every available Native Plugin with a localized name, description, and install state, so that optional features are discoverable in one place.
3. As a user, I want to install a plugin with one click and see its commands, panel rows, and settings appear immediately without relaunching, so that installation feels instant.
4. As a user, I want to uninstall a plugin and have every one of its surfaces disappear at once — panel, palette, settings, hotkeys — so that uninstalled truly means gone.
5. As a user uninstalling Hosts while profiles are active, I want the hosts file left completely untouched — no write, no administrator prompt — with active entries staying in effect until I reinstall, so that an uninstall never mutates system state behind my back. *(Reversed 2026-07-17 after owner testing; see the ADR-0005 addendum — previously the uninstall deactivated active profiles.)*
6. As a user whose Hosts uninstall fails to release the privileged helper, I want the plugin to remain fully installed with a clear error message, so that I am never left in a half-uninstalled state.
7. As a user uninstalling Image Conversion during an active Conversion Run, I want the run cancelled cleanly before the plugin goes away, so that no work continues invisibly.
8. As a user who uninstalls a plugin, I want its data (host profiles, Conversion Records, per-command preferences, recorded hotkeys) retained, so that reinstalling restores my exact previous setup.
9. As a user, I want an uninstall confirmation that states what happens and what remains (e.g. "active hosts entries stay in the hosts file and remain in effect; reinstall the plugin to manage them again"), so that nothing about the uninstall surprises me.
10. As an upgrading user with host profiles, I want the Hosts plugin auto-installed after the update, so that the upgrade changes nothing I can perceive.
11. As an upgrading user who enabled the privileged helper but later deleted all profiles, I want Hosts auto-installed anyway, so that the registered daemon always has a managing UI.
12. As an upgrading user with Conversion Records, I want Image Conversion auto-installed, so that my history and workflow survive.
13. As an upgrading user who never touched Hosts or Image Conversion, I want them uninstalled after the update, so that I get the cleaner default for free.
14. As a user, I want an uninstalled plugin to request no permissions and show no approval banners, so that optional features have zero ambient cost.
15. As a user with a hotkey bound to an uninstalled plugin's command, I want that hotkey to stop firing and become free for other bindings, so that dead commands don't squat on shortcuts.
16. As a user who reinstalls a plugin, I want its previously recorded hotkeys to work again (unless the shortcut was rebound meanwhile), so that data retention includes my muscle memory.
17. As a palette user, I want hosts profile rows, the Hosts drill-in menu, and the Image Conversion command to appear only while their plugin is installed, so that search results never offer a dead end.
18. As a palette user searching for an uninstalled plugin's command, I want no result at all, so that invisibility is complete rather than "greyed out".
19. As a menu-panel user, I want the Hosts popover row present only while Hosts is installed, so that the panel reflects my chosen feature set.
20. As a Hosts user, I want the editor window, helper approval flow, profile toggling, and palette drill-in to behave exactly as before once the plugin is installed, so that plugin-hood is invisible when installed.
21. As an Image Conversion user, I want the window, basket, history, and hotkey to behave exactly as before once installed, so that the migration is pure refactoring from my perspective.
22. As a user of forced Scheduled Shutdown, I want uninstalling Hosts to leave the privileged helper registered while shutdown still needs it, so that removing one feature never breaks another.
23. As a backup user, I want my installed-plugin set included in config backup and applied on import, so that a new machine reproduces my feature selection.
24. As a backup user, I want helper approval to remain per-machine after an import, so that security-sensitive state is never silently transplanted.
25. As a user importing a backup that installs Hosts, I want its surfaces to appear without a relaunch, so that import behaves like a hands-on install.
26. As a user, I want per-command visibility, ordering, and hotkey customization to keep working for installed plugins' commands, so that plugin commands stay first-class citizens of the panel.
27. As a Chinese or English user, I want plugin names, descriptions, and all plugin UI localized through the existing string catalog, so that plugins match the app's language behavior.
28. As a user relaunching after a silent Sparkle update, I want my installed set unchanged, so that updates never reset my feature selection.
29. As the developer, I want each plugin compiled as its own module that can touch the host only through the plugin interface, so that the boundary is compiler-enforced rather than convention.
30. As the developer, I want every built-in command claimed by exactly one owner — a plugin or the Core — with an invariant test, so that ownership can never silently drift.
31. As the developer, I want plugin-contributed palette rows to flow through one generic descriptor, so that Core control flow never names a plugin (ADR-0007).
32. As the developer, I want the plugin lifecycle (activate on install/launch, deactivate on uninstall, reconcile after backup import) defined once on the plugin interface, so that adding the next plugin is mechanical.

## Implementation Decisions

- **Shared plugin-interface module.** A new lean module holds the closed
  command catalog (`BuiltinItem`, per ADR-0006), the plugin protocols, the
  palette row descriptor, and the lifecycle contract. `PanelEntry`, its
  `Source` enum, and their payload types stay internal to Core (ADR-0007).
  Each pilot plugin is its own module depending only on the interface module;
  the host depends on the plugin modules solely to build the compile-time
  registry list.
- **Plugin protocol.** A Native Plugin declares: stable identity, localized
  name/description, claimed `BuiltinItem` cases, its providers, palette
  option-parent registrations and option builders, palette row sources
  (descriptor-based), panel popover and window contributions, a settings
  section, its SwiftData model types (collected at container creation — the
  schema stays static regardless of install state), a usage-trace predicate
  for migration, and lifecycle hooks: `activate`, `deactivate` (throwing;
  must cancel in-flight work and release shared host resources, without
  mutating user-visible system state or prompting for authorization), and
  reconcile-after-import.
- **PluginRegistry.** The single new seam. Owns the compile-time plugin list
  and the install-state store; exposes the installed set and claim lookups;
  enforces exclusive claims; performs transactional uninstall — `deactivate`
  must succeed before any surface is unregistered, and a thrown error
  leaves the plugin installed and reports the error.
- **Extension points, zero named branches.** Every host surface the pilots
  touch becomes generic: the provider registry, panel entry building, the
  palette option-parent table (today a hardcoded five), palette row sections,
  window/popover hosting, the settings sidebar's plugin area, hotkey snapshot
  compilation (which gains the installed set as an input and drops
  uninstalled plugins' bindings), and backup reconcile. The rule from
  ADR-0007: shared catalog types may enumerate plugin-claimed commands; Core
  control flow may never name a plugin.
- **`Source.pluginRow`.** Plugin palette rows (hosts profiles first) use one
  generic case carrying a descriptor that declares title, icon, and commit
  semantics; the hosts-specific source case and its named intent retire.
- **Install state storage.** Installed set lives in UserDefaults and joins
  the settings-sync whitelist, so backup import reproduces the feature
  selection; helper approval and other machine-local security state are
  excluded, consistent with existing backup policy.
- **Privileged helper stays Core infrastructure.** The helper daemon is
  shared: Hosts writes through it, and forced Scheduled Shutdown (a Core
  feature) shuts down through it. Hosts' `deactivate` never touches the
  hosts file (ADR-0005 addendum 2026-07-17) and unregisters the helper only
  when no other consumer needs it (forced shutdown not enabled). The
  migration trace "helper registered → install Hosts" stands, because the
  Hosts UI is the only enablement path and installing Hosts restores the
  daemon's managing UI.
- **Migration.** A one-time, versioned backfill in the launch sequence
  (following the existing seeder precedent): Hosts installs if host profile
  rows exist or the helper is registered; Image Conversion installs if
  Conversion Records exist; everything else — including fresh installs —
  starts uninstalled.
- **Uninstall confirmation.** Uninstalling from the Plugins tab shows a
  confirmation describing the uninstall's impact — for Hosts, that active
  entries stay in the hosts file and remain in effect until the plugin is
  reinstalled — plus the data-retention promise, before `deactivate` runs.

## Testing Decisions

- A good test exercises external behavior at a seam — what the user or a
  sibling subsystem observes — never the internals of a plugin or registry.
  No mocking of anything that can run for real; the two sanctioned test
  doubles remain the existing hosts-writer boundary double and in-memory
  ModelContainers.
- **PluginRegistry lifecycle** (the one new seam) is tested with the real
  pilot plugin instances: install surfaces appear, uninstall unregisters
  surfaces while leaving the hosts file untouched (writer never called,
  active profiles stay active), a failed helper release leaves the plugin
  installed (transactionality), and an in-flight conversion run is cancelled
  by deactivate.
- **Catalog claim invariant** extends the existing builtin-catalog invariant
  suite: every case claimed exactly once, claims match provider protocols.
- **Hotkey snapshot compilation** extends the existing pure-compile tests
  with the installed set: uninstalled plugins' bindings never compile.
- **Palette behavior** extends the existing commit-intent and options tests:
  `pluginRow` commit semantics, plugin-registered option parents, and
  invisibility of uninstalled plugins' entries.
- **Migration** follows the seeder-test pattern: in-memory container seeded
  with/without usage traces, asserting install state and idempotence across
  repeated launches.
- **Backup round-trip** extends the existing codec/service tests: installed
  set exports, imports, and triggers reconcile; machine-local helper state
  does not travel.
- Not tested: SwiftUI view layers (repo convention tests policies and
  models, not views) and real `SMAppService` registration (external system
  boundary behind the existing readiness injection point).

## Out of Scope

- **Script Plugins** (external, user-authored) — V2; they will join the same
  registry as a second plugin kind with their own `PanelEntry.Source` case.
- **Physical distribution** (downloadable plugin bundles, same-Team dylibs)
  — the hard module boundary exists to enable this later; no loader work now.
- **Third-party plugin authorship**, marketplaces, plugin updates, ratings.
- **Migrating further builtins** (Translation, Port Manager, …) — the
  architecture must make these mechanical, but V1 carves out only the two
  pilots.
- **Clipboard-history context-menu integration of Image Conversion** — stays
  hardwired in Core for V1; registered debt, revisited when the surface is
  next touched.
- **Onboarding/first-run plugin picker** — Settings is the only
  install/uninstall surface in V1.

## Further Notes

- The privileged-helper sharing constraint (user story 22) was discovered
  during spec review and slightly narrows ADR-0005's original "unregister the
  helper on uninstall" wording; the ADR is amended alongside this PRD.
- Implementation should land in refactor-sized slices that keep the app
  releasable: registry + interface module first, then each extension point,
  then Hosts extraction, then Image Conversion, then migration + Settings
  tab. Issue slicing happens at planning time, not in this PRD.
- Vocabulary is canonical in the glossary's Plugins section: Native Plugin,
  Core, Claim, Install, Uninstall. UI copy uses 「插件」/「安装」/「卸载」;
  「启用/禁用」remains reserved for per-command visibility.
