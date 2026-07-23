# Native Plugin Playbook

Audience: an agent (or developer) adding or modifying a Native Plugin without
re-deriving the architecture. Everything here is verified against the source
on branch `feat/native-plugins` (2026-07-20). Rationale lives in the linked
docs; this file is the operational map.

Scope: **Native Plugins only.** Script Plugins are a separate kind (sideloaded
pure-JavaScript packages on JavaScriptCore) sharing only the kind-agnostic
`PluginLifecycleCore` — see ADR-0008/0009, tickets `docs/issues/018`–`024`, and
the Script Plugin notes in `AGENTS.md`; do not apply this playbook to them.

Background: [PRD](../prds/2026-07-16-native-plugin-architecture.md) ·
[ADR-0005 logical install (+ 2026-07-17 addendum)](../adr/0005-native-plugins-logical-install.md) ·
[ADR-0006 enum claim](../adr/0006-plugin-commands-claim-enum-cases.md) ·
[ADR-0007 row descriptors](../adr/0007-plugin-rows-are-descriptors.md) ·
[Glossary](../../CONTEXT.md#plugins) · implementation tickets
`docs/issues/013`–`017`.

## 1. Mental model

- **Logical install.** A Native Plugin's code always ships in the binary as
  its own SPM target. "Install" flips a state flag — the installed set is a
  sorted `[String]` of plugin ids in UserDefaults key `plugins.installed`
  (`PluginRegistry.installStateKey`). Never a download.
- **Claim.** `BuiltinItem` (in `Sources/PluginInterface/BuiltinItem.swift`)
  is the closed, code-defined command catalog. A plugin does not mint command
  identities; it *Claims* existing cases via `claimedCommands`. Every case is
  owned by exactly one Native Plugin or by the Core (ADR-0006), enforced by
  `BuiltinCatalogInvariantTests.everyCommandIsClaimedByExactlyOneOwner` and an
  `assertionFailure` in `PluginRegistry.bootstrap`. Adding a command to a
  plugin still means adding an enum case in the shared target — by design.
- **Uninstalled = invisible everywhere.** No panel row, no palette entry, no
  hotkey firing, no popover, no permission prompts, no approval banners. Not
  "greyed out" — gone (PRD US18). Every surface gates through
  `PluginRegistry` (section 5). The sole discovery surface is Settings →
  Plugins; first-run onboarding remains Core-only and never advertises an
  uninstalled plugin.
- **Data always retained.** A plugin's `@Model` types are registered in the
  ModelContainer schema regardless of install state (ADR-0005), and its
  `BuiltinPreference` rows (visibility/order/hotkey) survive uninstall.
  Reinstall restores the exact previous setup without relaunch (PRD US8/US16).
- **Core never names a plugin in control flow (ADR-0007).** Shared *catalog
  types* may enumerate plugin-claimed commands (`BuiltinItem` is shared), but
  Core services, intent classifiers, and window controllers must never branch
  on a specific plugin. Plugins reach the Core only through registrations and
  descriptors; the Core reaches plugins only through `PluginRegistry` lookups.
  The one sanctioned exception is in section 2.
- **Glossary (canonical, with the Chinese UI copy):** Native Plugin 原生插件 ·
  Core 内核 · Claim 认领 · Install 安装 · Uninstall 卸载. UI copy uses
  「插件 / 安装 / 卸载」; 「启用/禁用」 is reserved for per-command visibility
  and must not be used for install state (avoid 停用 too). See
  `CONTEXT.md#plugins`.

## 2. Module layout

SPM targets (see `Package.swift`), all `.swiftLanguageMode(.v6)`:

```
PluginInterface  ←─ HostsPlugin ────────┐
      ↑          ←─ ImageConversionPlugin (+ ImageCodec, libwebp)
      │                                 │
      └──────────── AnyDoor (host) ─────┘   AnyDoorTests depends on all four
ImageCodec       ←─ AnyDoor, ImageConversionPlugin
```

- **`PluginInterface`** (`Sources/PluginInterface/`) — the lean shared
  interface: `BuiltinItem` (closed catalog), `BuiltinProvider` /
  `ToggleProvider` / `ActionProvider` + `PermissionStatus`, `NativePlugin` +
  `NativePluginID`, `PluginHostServices` + `PluginToast`, the instance-scoped
  `PluginHostContext` + `PluginLocalizedText`, `PluginRowDescriptor` +
  `PluginRowSource` + `PluginRowSourceKey`,
  `PluginPanelPopover` + `PluginPanelPopoverContext`,
  `PluginClipboardAction` + `PluginClipboardPayload` +
  `PluginClipboardActionContext`,
  `PrivilegedHelperAccess` + `PrivilegedHelperReadiness` +
  `PrivilegedHelperCallError`, plus a few shared utilities/views
  (`MainThreadIsolation`, `CaptureFilename`, `FileThumbnailCache`,
  `FocusedControlKeyPolicy`, `PlainTextEditor`, `HoverReader`,
  `AdaptiveGlassEffectContainer`). It must never depend on Core palette/UI
  types such as `PanelEntry` — `Source` cases drag their payloads with them
  and would balloon the interface target (ADR-0007).
- **Plugin modules** (`Sources/HostsPlugin/`,
  `Sources/ImageConversionPlugin/`) — depend **only** on `PluginInterface`
  (Image Conversion also on `ImageCodec` + `libwebp`). This is the
  compiler-enforced boundary: a plugin module cannot import the host, so any
  host facility it needs must be a `PluginHostServices` capability.
- **`ImageCodec`** — pure codec utilities shared by Core and the Image
  Conversion plugin (`ImageConversionFormat`, `ImageEncoder`,
  `ImageEncodingQuality`), so Core's screenshot Save As never imports the
  plugin module.
- **`AnyDoor`** (host) — depends on the plugin modules to build the
  compile-time catalog. Exactly one Core file imports a plugin module:
  `Sources/AnyDoor/Services/Plugins/NativePluginCatalog.swift` — the
  composition root (sanctioned): schema participation and runtime factories.
  Do not add a second import; the former clipboard-history registered debt
  was paid down into the generic `PluginClipboardAction` surface (section 5).

## 3. The `NativePlugin` protocol, member by member

`Sources/PluginInterface/NativePlugin.swift`. The protocol is `@MainActor`,
`AnyObject`. Defaults live in the `extension NativePlugin`; only members
marked **required** have no default.

| Member | Required | Called when / by |
|---|---|---|
| `id: NativePluginID` | yes | Persisted in `plugins.installed` and backups. **Never change the raw value once shipped.** Pilots expose `static let pluginID` (`"hosts"`, `"imageConversion"`). |
| `localizedName` / `localizedDescription: String` | yes | `PluginsSettingsView` rows. Resolve via the module `L(_:)` front so a language switch applies. |
| `localizedUninstallImpact: String?` | default `nil` | Shown in the uninstall confirmation before the data-retention line. `nil` = uninstall only removes surfaces. |
| `claimedCommands: Set<BuiltinItem>` | yes | Read once at `PluginRegistry.bootstrap` to build the claim table. |
| `providers: [any BuiltinProvider]` | yes | Must cover **exactly** the plugin's actionable (`.toggle`/`.action`-kind) claims — no more, no less (`pluginsProvideOnlyForTheirClaimedActionableCommands`). Submenu-kind claims register no provider (Hosts: `providers = []`). |
| `paletteOptionParents: Set<BuiltinItem>` | default `[]` | Claimed commands that drill into a second-level palette list. Registered via `CommandPaletteExtensions.registerContributions(of:)`; plugin parents always `listsAtRoot`. |
| `paletteOptions(for:) async -> [PluginRowDescriptor]` | default `[]` | Builds the second-level rows on drill-in. Do the state fetch here (Hosts calls `manager.reload()` first). |
| `performPaletteOption(parent:id:) async` | default no-op | Runs a committed second-level option, routed back by descriptor id — Core never sees the action. |
| `paletteRowSources: [any PluginRowSource]` | default `[]` | Root-level palette row sources (section 5). |
| `panelPopover(for:) -> PluginPanelPopover?` | default `nil` | Menu-panel hover popover for a claimed submenu command. Resolved per-mount through `PluginRegistry.panelPopover(for:)`. |
| `clipboardActions(for:) -> [PluginClipboardAction]` | default `[]` | Context-menu actions for a clipboard-history entry, decided from the neutral `PluginClipboardPayload` alone. Runs at menu-build time — cheap, synchronous, disk-free. |
| `performClipboardAction(id:payload:context:) async` | default no-op | Runs a committed clipboard action, routed back by descriptor id. Payload loading and failure feedback live here; dismiss the history window through the context before presenting a window. |
| `nonisolated static modelSchemaTypes: [any PersistentModel.Type]` | default `[]` | SwiftData types the plugin owns. `nonisolated static` because `AppDelegate.init()` composes the schema **before any MainActor plugin instance exists**, and unconditionally — install state never changes the schema. This is the data-retention mechanism. |
| `hasUsageTrace(in: ModelContext) throws -> Bool` | **yes** | Evaluated once by `PluginUsageMigration` to auto-install for upgrading users. Hosts: `HostProfile` rows exist **or** `privilegedHelper.readiness() != .unavailable` (a registered daemon needs its managing UI). Image Conversion: `ImageConversionRecord` rows exist. A throw aborts the whole migration and it retries next launch. |
| `activate()` | default no-op | On `install(_:)` and on every launch while installed (from `bootstrap`), **before** surfaces register. Start install-scoped work here; install-time permission acts live here too (Hosts calls `privilegedHelper.ensureRegistered()` — an uninstalled plugin requests no permissions, PRD US14). Mutable stores should already belong to the plugin instance, not be configured through a module singleton. |
| `deactivate() async throws` | **yes, deliberately no default** | See the contract below. |
| `reconcileAfterImport()` | default no-op | After a config-backup import, for every plugin that ends up installed: re-read imported settings, refresh internal state (Hosts: `manager.reload()`). |

### The `deactivate` contract

Called by `PluginRegistry.uninstall` **before any state or surface change**.
It must:

1. **Quiesce, then cancel in-flight work.** Image Conversion closes its
   presentation gate first, so a provider action already waiting on Finder
   cannot reopen the window after uninstall (and cannot become current after a
   quick reinstall). Its view model then rejects new work, dismisses pending
   file/folder panels, cancels the Conversion Run, previews, preflight, Save
   Anyway, and maintenance tasks, and awaits every owned task
   (`ImageConversionWindowController.deactivateForUninstall()`).
2. **Release shared host resources through the capabilities.** Hosts calls
   `host.privilegedHelper.releaseIfUnneeded()` — the Core decides whether
   another consumer (forced Scheduled Shutdown) still needs the daemon
   (`PrivilegedHelperRelease` policy in `HelperManager.swift`, amended
   ADR-0005).
3. **NEVER mutate user-facing system state or prompt for authorization**
   (ADR-0005 addendum 2026-07-17). The Hosts precedent: `deactivate()` never
   starts an `/etc/hosts` write and never triggers an admin prompt. It closes
   the editor, cancels debounced applies, drains a writer that already crossed
   the external boundary, and only then releases the helper. Active profiles
   keep `isActive` and their managed block stays in the file — in effect but
   unmanaged until reinstall, which restores the exact previous setup.
4. **Throw to abort.** Uninstall is transactional: a thrown error leaves the
   plugin fully installed with every surface intact — there is no
   half-uninstalled state. A failed helper release is Hosts' only abort path.
5. Closing the plugin's windows is fine (both pilots do).

## 4. Host services

### `PluginHostServices` (the only door back into the app)

Implemented by `CorePluginHost`
(`Sources/AnyDoor/Services/Plugins/CorePluginHost.swift`); one instance built
in `AppDelegate` and handed to every plugin's `init`. Capabilities:

- `modelContainer: ModelContainer` — the shared container; wire plugin stores
  in `activate()`.
- `effectiveLocale: Locale` — routed through the `@Observable`
  `LocalizationManager`, so reading it in a SwiftUI `body` re-renders on a
  language switch (pinned by `PluginLocalizationTests`).
- `localizedString(_ key: String) -> String` — resolves against the shared
  catalog via `LocalizationManager.shared.bundle`; returns the key when
  missing.
- `showToast(_ PluginToast)` — `.success/.info/.failure(String)` →
  `ToastPresenter.shared`.
- `trackRegularWindow(_ NSWindow)` — `RegularWindowCoordinator` flips the
  accessory app to `.regular` while the window is open.
- `pasteboardSelfWrite(_ body:)` — the `ClipboardWatcher.selfWrite` funnel;
  any plugin pasteboard write must go through it so the 0.5 s history poll
  never captures it.
- `runAppleScript(_ source:) async throws -> String` — `AppleScriptRunner`
  with Automation-permission handling.
- `privilegedHelper: any PrivilegedHelperAccess` — the shared root daemon
  (Core infrastructure): `readiness()`, `ensureRegistered()`,
  `openApprovalSettings()`, `writeHostsFile(_:) async throws`,
  `releaseIfUnneeded() throws`.

Adding a member needs the same scrutiny as a new `NativePlugin` requirement.
Every test host double (`RecordingPluginHost`, `MigrationPluginHost`,
`StubLocalizationHost`) must grow the member too.

### `PluginHostContext` (instance-scoped capability access)

`Sources/PluginInterface/PluginHostContext.swift`. Every plugin `init`
constructs one `PluginHostContext` from its injected services and passes that
same immutable reference to its manager, writers, view models, window
controllers, and SwiftUI root environment. There is no module-level mutable
host slot and no last-bootstrap-wins behavior: two plugin instances or test
fixtures remain isolated even when alive together. The context provides the
narrow capability fronts (`showToast`, `trackRegularWindow`,
`pasteboardSelfWrite`, helper access, AppleScript, and localization). Pure
logic tests may inject `nil` into consumers that deliberately support a
raw-key/no-toast fallback; production plugin roots always provide a real
context. Mutable services follow the same ownership rule: Image Conversion,
for example, constructs one `ImageConversionHistoryStore` from its captured
container and injects that exact store into its window and view model. Never
add a process-wide `shared` store with a later `configure` step.

### Per-module L10n pattern

Each plugin module has a `HostBridge.swift` with:

1. `enum L10n { enum Key: String, CaseIterable, Sendable }` — typed view of
   the raw catalog keys the module uses (e.g. `"plugin.hosts.name"`).
2. `func L(_ host: PluginHostContext?, _ key: L10n.Key, _ args: CVarArg...) -> String`
   → thin front over the supplied instance context, with raw-key fallback.
3. `struct LocalizedText: View` wrapping the environment-scoped reactive
   `PluginLocalizedText(key:)` — a `Text` that re-renders on a host language
   switch (the body reads `services.effectiveLocale`, registering an
   Observation dependency).

The strings themselves live in the **host's** single shared catalog,
`Sources/AnyDoor/Resources/Localizable.xcstrings` (user story 27). Both
`en` and `zh-Hans` values are mandatory:
`LocalizationCoverageTests.test_everyL10nKeyHasZhHansAndEnTranslations`
walks `AnyDoor.L10n.Key` + `ImageConversionPlugin.L10n.Key` +
`HostsPlugin.L10n.Key` against the raw JSON and fails on any missing entry.
Plugin lifecycle strings follow the pattern `plugin.<id>.name` /
`.description` / `.uninstallImpact`; the Plugins tab's own strings are Core
keys (`plugins.install`, `plugins.uninstall`, `plugins.state.installed`,
`plugins.uninstall.confirmTitle`, `plugins.uninstall.dataRetained`,
`plugins.uninstall.failed` in `Sources/AnyDoor/Utilities/L10n.swift`).

## 5. Surfaces and how each gates on install state

`PluginRegistry.isAvailable(command)` = Core-owned commands always available;
plugin-claimed commands only while their owner is installed.
`PluginRegistry.availableCommands` = full catalog minus uninstalled plugins'
claims.

- **Panel row.** `PanelStore.rebuild()` skips any `BuiltinPreference` row
  whose item fails the injected `commandAvailability` closure (bound to
  `PluginRegistry.shared.isAvailable` in `AppDelegate`). The preference row
  itself is retained. Panel settings and the palette root both derive from
  PanelStore, so they inherit the gate. Providers land per-item via
  `PanelStore.registerProviders(_:)` / `unregisterProviders(for:)` (the
  latter also clears cached toggle/permission state).
- **Hotkeys.** `HotkeyCoordinator.refresh()` passes
  `availableCommands: PluginRegistry.shared.availableCommands` to the pure
  `compile(bindings:prefs:quicklinks:paletteHotkey:availableCommands:)`; a
  binding recorded for an unavailable command never compiles — it neither
  fires nor squats on the shortcut (PRD US15). Only `BuiltinPreference`
  hotkeys are gated; app shortcuts / quicklinks / the palette hotkey are
  Core-owned.
- **Palette.** `CommandPaletteExtensions`
  (`Sources/AnyDoor/Services/CommandPaletteExtensions.swift`) is the generic
  registry. `registerContributions(of: plugin)` maps each
  `paletteOptionParents` member to a `CommandPaletteOptionParent`
  (`listsAtRoot: { true }`, options built from `paletteOptions(for:)`
  descriptors, committing via `performPaletteOption`) and registers each
  `paletteRowSources` element. `unregisterContributions(of:)` reverts both.
  `PluginRegistry` owns registration and removal across launch, Install, and
  Uninstall; `NativePluginCatalog` supplies the plugin list and schema while
  `AppDelegate` supplies only the host and Core providers.
  Core combines each source's plugin-local `id` with its owner's stable plugin
  id into a `PluginRowSourceKey`. Registrations, entry identity, unregister,
  and commit routing all use this key, so two plugins may use the same local
  source id without replacing one another. Root plugin rows flow through
  `PanelEntry.Source.pluginRow(sourceKey:descriptor:)`;
  `CommandPaletteCommitIntent.classify` maps them exhaustively by declared
  `CommitSemantics` (`.stayOpen` → `.pluginRowStayOpen`, `.closeThenAct` →
  `.pluginRowCloseThenAct`) and the controller performs them via
  `CommandPaletteExtensions.rowSource(for:)?.performRow(id:)`. A
  `PluginRowSource` gets one `reload()` per palette open (in
  `collectSections`); `rows()` runs per query pass and must stay cheap and
  synchronous. Its `sectionTitleKey` is a raw catalog-key string rendered via
  `L(raw:)` / `LocalizedText(raw:)` — no Core `L10n.Key` case needed. A runtime
  install or uninstall also asks `CommandPaletteWindowController` to
  recompose an already-visible palette from the live registrations. Root
  queries stay intact; drill-in state is reset because it may retain option
  closures owned by the plugin that just disappeared.
- **Panel popover.** `MenuBarView`'s generic `case .submenu(let item)` branch
  (after all named Core submenu branches) resolves
  `PluginRegistry.shared.panelPopover(for: item)` — which returns `nil`
  unless the claim owner is installed, so an uninstalled plugin's popover can
  never mount. The host mounts `makeContent(context)` with a
  `PluginPanelPopoverContext` (`onHoverChange` / `dismissPopover` /
  `closePanel`) and, if `refresh` is set, re-runs it off the hover tick then
  remounts and re-anchors.
- **Settings → 插件.** `PluginsSettingsView` lists `registry.plugins`
  (installed or not — this is the one surface where uninstalled plugins are
  visible, as installable entries). Install applies immediately; Uninstall
  first shows a confirmation composed of `localizedUninstallImpact` (if any)
  plus the `plugins.uninstall.dataRetained` promise, then runs the
  transactional `registry.uninstall(id)`; a thrown deactivate surfaces a
  failure toast and the plugin stays installed. The row icon is the claimed
  command with the smallest `defaultOrder`.
- **Window presentation.** Each plugin instance owns its windows
  (`HostsEditorWindowController`, `ImageConversionWindowController`) and must
  call its `PluginHostContext.trackRegularWindow(window)` and set
  `isRestorable = false`.
  Windows are reached from the plugin's own surfaces (provider `run()`,
  popover edit button, palette option), all of which are install-gated
  upstream; `deactivate()` closes them. An async presentation path must also
  carry an activation generation across each await and drain before uninstall
  completes, because upstream gating cannot revoke an action that already
  started.
- **Clipboard-history context menu.** `ClipboardCardView` builds a neutral
  `PluginClipboardPayload` via `ClipboardPluginPayloadMapper` (Core describes
  the entry; it never encodes a plugin's policy) and lists
  `PluginRegistry.clipboardActions(for:)` — installed plugins only. Commit
  routes through `PluginRegistry.performClipboardAction(pluginID:actionID:
  payload:context:)`, which re-checks install state so a menu built just
  before an uninstall landed never reaches the plugin. The
  `PluginClipboardActionContext` hands the plugin a dismiss-then-run closure
  for the history window; an action that only reports a failure (e.g. via a
  toast) skips it and leaves the window open. Image Conversion's
  "Convert Image Format" is the first contribution
  (`ClipboardConversionPolicy` + `performClipboardAction` in the plugin).

## 6. Lifecycle flows

All of this is composed in `AppDelegate` (`Sources/AnyDoor/AppDelegate.swift`).

- **Launch.** `init()`: schema = 5 Core `@Model` types plus
  `NativePluginCatalog.modelSchemaTypes` (unconditional).
  `applicationDidFinishLaunching`: build one `CorePluginHost`, ask the same
  catalog to construct the plugin list, then —
  **order matters** — `PluginUsageMigration.runIfNeeded(plugins:in:)` first,
  `PluginRegistry.shared.bootstrap(plugins:modelContainer:coreProviders:)`
  second. Bootstrap reads the possibly-just-migrated install state, starts
  runtime state empty, calls `activate()` before marking each plugin
  Installed, then publishes all initial providers and palette contributions
  as one batch. It wires its paired `PanelStore` and `HotkeyCoordinator`
  instances through refresh and builtin-dispatch closures; hotkey
  snapshots are still published later in normal app startup so bootstrap
  cannot start the event tap early.
- **Install** (`PluginRegistry.install(id)`, idempotent): `activate()` →
  insert into `installedIDs` → persist → register providers and palette
  contributions → `PanelStore.rebuild()` → `HotkeyCoordinator.refresh()`.
  Everything appears without relaunch.
- **Uninstall** (`uninstall(id) async throws`, idempotent, re-entrancy
  guarded by `transitioningIDs`): `try await plugin.deactivate()` **first**;
  only on success remove from `installedIDs`, persist,
  unregister its providers and palette contributions, then rebuild the panel
  and refresh hotkeys plus any visible palette. A deactivate failure propagates
  to the UI and nothing changed; a concurrent transition for the same plugin
  throws `PluginTransitionInProgressError` instead of silently dropping intent.
- **Backup import.** `plugins.installed` is whitelisted in
  `SyncSettingsRegistry` (as `.stringArray`). `BackupService.restore(_:)`
  writes the snapshot and then awaits the live-runtime reconciliation, which
  includes `PluginRegistry.shared.reconcileAfterImport()`: read the imported
  set from defaults, remove plugins before adding replacements, and run the
  **real lifecycle** for every delta (`install` per added id — so `activate`
  runs and helper registration happens only as a consequence of install,
  never from the defaults write itself; transactional `uninstall` per removed
  id — a failed deactivate keeps the plugin and the state is re-persisted to
  match reality). Each transition publishes immediately because an async
  deactivate creates an observable boundary. The registry then forwards
  `reconcileAfterImport()` to the plugins that end up installed. It attempts
  every transition and checks `transitioningIDs` both before and after the
  awaited removals, then throws `PluginImportReconciliationError` containing
  every failed or overlapping transition. `BackupService` still completes the
  other live-runtime refreshes before rethrowing, and the Sync UI reports a
  partial failure rather than success. Helper *approval* is machine-local and
  never travels (PRD US24).
- **Usage-trace migration** (`PluginUsageMigration.runIfNeeded`): one-shot
  behind versioned flag `plugins.usageMigrated_v1`. If `plugins.installed`
  already exists before migration (only possible via a config-backup import),
  that explicit selection wins and the flag is set without inference.
  Otherwise every plugin's `hasUsageTrace(in:)` decides its initial state;
  fresh installs get `[]`. A throwing predicate aborts without setting the
  flag, so the next launch retries (a transient store error must not silently
  uninstall a feature). Once flagged, no relaunch — including Sparkle's
  silent-update relaunch — changes the set (PRD US28).

## 7. Checklist: adding plugin N+1

Ordered; the invariant tests are the safety net — a missed step fails a
named test, which is the point of them.

1. **Claim a command.** Add the `BuiltinItem` case(s) in
   `Sources/PluginInterface/BuiltinItem.swift`: `kind`, `symbol`, unique
   `defaultOrder`, `requiresAutomation` if needed. Add the panel title key in
   Core's `BuiltinItem+Core.swift` (`titleKey`) + catalog entries.
   *Missed → `BuiltinCatalogInvariantTests` (provider/order invariants),
   `BuiltinItemLocalizationTests` (title key resolves), non-exhaustive-switch
   compile errors in `kind`/`symbol`/`defaultOrder`.*
2. **New SPM target** in `Package.swift`: `Sources/<Name>Plugin/`, depends
   only on `PluginInterface` (+ pure shared targets like `ImageCodec` if
   justified), `.swiftLanguageMode(.v6)`. Add it to the `AnyDoor` and
   `AnyDoorTests` dependency lists.
3. **Plugin type**: `@MainActor public final class <Name>NativePlugin:
   NativePlugin` with `public static let pluginID = NativePluginID(rawValue:
   "<stable-id>")`, `init(host: any PluginHostServices)` constructing one
   `PluginHostContext` and passing it through every capability consumer.
   Construct mutable stores as instance properties from the captured host
   container and inject those same instances downward; never add a module
   singleton that a later bootstrap call reconfigures.
   Implement only the surfaces the feature has (defaults cover the rest);
   `deactivate` must be written consciously per the section-3 contract.
   Provide a test `init` seam if the plugin touches a system boundary
   (Hosts' injected `HostsManager` + `MockHostsWriter` precedent).
4. **Register once in `NativePluginCatalog`**: add one registration pairing
   `<Name>NativePlugin.pluginID`, `.modelSchemaTypes`, and its host-backed
   factory. Nothing else — AppDelegate schema construction, runtime creation,
   lifecycle, migration, backup, and all surfaces derive from the catalog.
   Extend `NativePluginCatalogTests` with the expected id and model names.
5. **Strings**: `HostBridge.swift` in the module (typed `L10n.Key` enum +
   `L(_:)` + `LocalizedText` fronts, copied from a pilot), entries in
   `Sources/AnyDoor/Resources/Localizable.xcstrings` with **both** `en` and
   `zh-Hans`, including `plugin.<id>.name` / `.description` /
   (`.uninstallImpact` when applicable).
   *Missed → extend `LocalizationCoverageTests` with the new module's
   `L10n.Key.allCases` (this extension is mandatory, the test can't see the
   new enum by itself) — then it enforces coverage forever.*
6. **Tests that MUST be extended** (grep for the pilot's name to find every
   seam):
   - `BuiltinCatalogInvariantTests.makeProductionPlugins()` — add the real
     instance (with sanctioned doubles for system boundaries) so the claim /
     provider invariants cover it.
   - A `<Name>PluginLifecycleTests` with the **real** plugin instance against
     a fresh `PluginRegistry` + isolated `UserDefaults` suite: install
     surfaces appear, uninstall reverts them without side effects, failed
     deactivate aborts transactionally, reinstall restores data
     (`HostsPluginLifecycleTests` is the template).
   - `PluginUsageMigrationTests` — a trace-present and trace-absent case for
     the new `hasUsageTrace` predicate (only if upgrading users exist for the
     feature; a brand-new feature has no trace and starts uninstalled).
   - Hotkey availability is already generic
     (`HotkeyCoordinatorTests.testUninstalledPluginCommandBindingNeverCompiles`);
     the install hook also clears a retained plugin hotkey when its descriptor
     was rebound to an active source while the plugin was absent.
   - Palette plumbing is pinned generically by
     `PluginPaletteContributionTests` (fixture plugin) and
     `CommandPaletteCommitIntentTests` (pluginRow semantics); add
     feature-specific option/row tests like `HostProfileRowSourceTests` when
     the plugin contributes them.
7. **Migration**: nothing to write — `PluginUsageMigration` iterates the
   plugin list. But note the flag is versioned: `plugins.usageMigrated_v1`
   has already run for existing users, so a *later* plugin extracted from an
   existing Core feature needs a **new** versioned migration pass (v2) if its
   users must be auto-installed; a genuinely new feature needs none.
8. **Docs**: `CHANGELOG.md` under `## [Unreleased]`; the SPM target list and
   Native Plugins note in `AGENTS.md`; glossary additions in `CONTEXT.md` if
   the feature brings new terms.

## 8. Testing rules

(PRD Testing Decisions; the suite enforces them by example.)

- **Sanctioned doubles only**: `MockHostsWriter` (the hosts-writer boundary),
  in-memory `ModelContainer`s (`ModelConfiguration(isStoredInMemoryOnly:
  true)`), and the helper **readiness injection point** — a scripted
  `PrivilegedHelperAccess` inside a `PluginHostServices` test double
  (`RecordingPluginHost.RecordingHelper` pattern); real `SMAppService`
  registration is never exercised. Everything else runs for real.
- **Registry lifecycle tests use real plugin instances** with an isolated
  harness: a fresh `PluginRegistry` wired to private `PanelStore`,
  `CommandPaletteExtensions`, and `HotkeyCoordinator` instances, an in-memory
  `ModelContainer`, a snapshot recorder instead of the real event tap, and an
  isolated `UserDefaults(suiteName:)` with teardown. Assert published state,
  not callback counts.
- **No view-layer tests.** Policies, models, stores, and descriptors only.
  The one end-to-end exception drives the real `PanelStore`
  (`PluginRegistryTests.testLifecycleTogglesPanelRowThroughRealSurfaces`),
  still headless. Do not read Swift source files and assert that view code
  contains particular strings; extract the decision into a pure policy when
  it deserves a regression test.
- Contract-level pins live in `NativePluginContractTests` (a `BarePlugin`
  proves optional members default to empty/no-op and don't trap) — extend it
  if you add a protocol member.
- Add an isolation assertion when introducing a new context consumer: two
  simultaneously alive fixtures must keep their host services independent.

## 9. Known debts / gotchas

- **One plugin import in Core** (section 2): `NativePluginCatalog`, the
  permanent, sanctioned composition root. The clipboard-history convert
  context menu — formerly the PRD's single carved-out concrete-module debt —
  now flows through the generic `PluginClipboardAction` surface; keep it that
  way.
- **`PluginRegistry.bootstrap` intersects the stored set with the known
  plugin list**, so an id from the future (or a typo) is silently dropped —
  another reason `pluginID` raw values are frozen forever.
- **The uninstall UI and the registry are both re-entrancy guarded**
  (`uninstallingIDs` in `PluginsSettingsView`, `transitioningIDs` in
  `PluginRegistry`) because `deactivate` is async. A concurrent uninstall
  reports a localized error, and backup reconciliation treats any overlapping
  transition as a partial failure; keep those semantics if you add another
  lifecycle entry point.
