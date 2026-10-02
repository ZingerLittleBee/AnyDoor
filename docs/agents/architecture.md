# Architecture Reference

Read the section matching the change before editing its ownership, lifecycle, or storage boundary.
Use [navigation](navigation.md) to locate the implementation and tests; use the
[documentation index](../README.md) to distinguish current contracts from historical plans.
Build and runtime validation live in [development](../development.md) and
[testing](../testing/README.md). Release and feed procedures live in
[deployment](../deployment.md) and [Beta Updates](../beta-updates.md).

This reference preserves the subsystem invariants formerly carried in `AGENTS.md`.
Package targets and dependency versions are defined by [Package.swift](../../Package.swift);
the descriptions here explain the behavior those declarations do not capture.

## Contents

- [Persistence and clipboard history](#persistence-and-clipboard-history)
- [Hotkeys and panel](#hotkeys-and-panel)
- [Native plugins](#native-plugins)
- [Script plugins](#script-plugins)
- [Command palette](#command-palette)
- [Windows and localization](#windows-and-localization)
- [System services](#system-services)
- [Backup and sync](#backup-and-sync)
- [Capture and recording](#capture-and-recording)

## Persistence and clipboard history

### Shared ModelContainer

Created in `AppDelegate.init()` and handed to all SwiftUI views via `.modelContainer()`. Do not
create multiple ModelContainer instances.

### Pinned store path

ModelContainer is explicitly configured with `url: ~/Library/Application
Support/dev.bybee.AnyDoor/AnyDoor.store` so `swift run` and the `.app` don't write to different
locations due to Bundle ID differences. The live schema registers exactly six `@Model` types — four
Core-owned (`KeyBinding`, `BuiltinPreference`, `TranslationRecord`, `Quicklink`) plus each plugin's
`modelSchemaTypes` (currently `ImageConversionRecord` and `HostProfile`); Clipboard History v2 owns
a separate encrypted SQLCipher store, and the pre-v2 `ClipboardHistoryItem` model no longer exists
in Sources at all. A plugin's schema is registered regardless of install state (ADR-0005), which is
what keeps user data across uninstall/reinstall. **Never open `~/Library/Application
Support/default.store`**: it is SwiftData's default store path for every non-sandboxed app, so it
holds other apps' data, and opening it with AnyDoor's schema migrates their tables away. The removed
`migrateLegacyStore` did exactly that on every launch while the file existed, to recover data that
only pre-1.0 development builds ever wrote there. Before opening the reduced live schema,
`ClipboardHistoryLegacySource` atomically snapshots the old SwiftData files; the read-only adapter
deletes that snapshot only after encrypted migration publication and verified plaintext-payload
cleanup. The migration replaces only an empty initial store, so until the lifecycle has confirmed
the cutover, `ClipboardProductionAdapter` writes the pasteboard but skips the history write for
explicit captures (`ClipboardHistoryLifecycle.admitsExplicitCaptures`); a capture that reached the
store first blocks the migration. A store 4.2.x already filled that way is refused with its entry
count (`legacyMigrationStoreNotEmpty`), the lifecycle reports `.migrationBlocked`, and Clipboard
Settings offers a confirmed discard: `migrateLegacy(_:discardingEntries:)` deletes the store only
once the staging store is verified and only while it holds exactly the confirmed count, keeping the
key and any displaced store (never route this through Reset, which would also drop the pre-v2
history). If snapshot preparation fails, `AppPersistenceBootstrap` keeps the production store
closed, runs the app on an isolated in-memory container without persistent one-shot migrations or
Config Sync, and lets Clipboard Settings retry; a successful retry relaunches before the production
container opens. That snapshot is read as **plain SQLite** (`ClipboardHistoryLegacyStoreReader`, in
the `ClipboardHistory` target) rather than through a `ModelContainer`: Core Data's row cache costs a
second full copy of the store no matter how the fetch is batched (measured 215MB vs 113MB for 800 x
128KB rows), and a cursor releases each row as it advances. The v1 schema is frozen, so the
`Z`-prefixed table and column names the reader hardcodes are a fixed contract — pinned by
`ClipboardHistoryLegacyStoreReaderTests` against stores built by real SwiftData via the
`ClipboardHistoryItem` fixture that now lives in
`Tests/AnyDoorTests/LegacyClipboardHistorySchemaFixture.swift`. Renaming that fixture or its
properties changes the table layout and breaks migration, so it is not free-form test code. The v2
store itself lives in `dev.bybee.AnyDoor/ClipboardHistoryV2/`
(`ClipboardHistoryModule.defaultStoreRoot`), **never** in the sibling `ClipboardHistory/`
(`legacyPayloadDirectory`): installable pre-v2 releases delete every file there that no legacy row
names, which is how 4.2.0–4.2.5 (which kept the store there) lost history. That folder holds only
pre-v2 payloads for the legacy migration, and `AppDelegate` must keep reading them from it (via
`ClipboardHistoryLifecycle.production`), or every legacy image migrates without its content.
`ClipboardHistoryStoreRelocation` moves a store found there by whole-directory rename before the
Keychain is read. When `ClipboardHistoryV2/` already holds a store, the one found in the legacy
folder is kept aside under `ClipboardHistoryV2.displaced/` instead (it holds what a 4.2.x release
captured, so it can be newer than the current store) and is adopted only into an empty current
store. A failed move reports `.storeRelocationFailed` (Retry only, never Reset) only while
`ClipboardHistoryV2/` holds no store; otherwise that store opens and the next open retries the move
(ADR-0011 amendment). `Tests/ClipboardHistoryTests/PreV2ClipboardHistorySweepFixture.swift` freezes
the pre-v2 sweeps as a contract. **Keep the AnyDoor.store path when changing ModelConfiguration**,
otherwise unrelated user data appears "lost".

### Launch-time SwiftData seeding/migration

`AppDelegate.applicationDidFinishLaunching` runs idempotent `BuiltinPreferenceSeeder` (one
`BuiltinPreference` row per `BuiltinItem`, appends newly added builtins at max order+1, uses
versioned backfill flags; the one-shot `captureModeBarMerged_v1` merges the retired `captureModeBar`
row's hotkey and visibility into `screenshot` and deletes it, setting the flag only after the save
succeeds), `KeyBindingOrderBackfill` (assigns stride-100 `displayOrder` to legacy zero-order rows),
and `PluginUsageMigration` (one-shot versioned flag `plugins.usageMigrated_v1`: seeds
`plugins.installed` from each plugin's `hasUsageTrace(in:)` — Hosts on profile rows **or** a
registered helper daemon, Image Conversion on Conversion Records; fresh installs get an empty set, a
pre-existing install state from a backup import wins, and it must run **before**
`PluginRegistry.bootstrap`, which activates the migrated-installed plugins). New live `@Model`
fields **must carry inline defaults** so SwiftData lightweight migration can backfill existing rows
(see `KeyBinding.isEnabled/isVisible/displayOrder`). **Inline defaults only backfill scalar types**
(Bool/Int/String/Date): a new array/Codable field becomes a transformable column that migration
leaves NULL, and faulting a legacy row then throws `NSInvalidUnarchiveOperationException` at launch.
Store such data as an optional scalar or a dedicated store instead.

### Internal pasteboard writes go through the v2 self-write funnel

Any AnyDoor-originated write to the general pasteboard (copy result, paste-from-history, screenshot
auto-copy, clear clipboard, …) must use the injected `ClipboardHistoryPasteboardSelfWriteFunnel` —
never a raw `clearContents()`/`setString` followed by a manual counter update. The funnel publishes
one scoped suppression token around the write so the event-assisted monitor cannot capture the app's
own write as a bogus history entry, including a throwing partial write.
`SelectedTextReader.readViaClipboard` uses the same scoped token across its synthesized-⌘C awaits
and final restoration. A Clipboard History entry reaches the pasteboard only through
`ClipboardHistoryPasteService.copyEntry` (an uncached materialization written through the funnel,
reported as a `ClipboardHistoryCopyOutcome`), which the menu-bar popover and the wall share. The
wall commits through `ClipboardHistoryPasteService.commit`. The latest commit wins: a superseded one
writes nothing and shows nothing, and one whose surface closed meanwhile writes only while the
pasteboard is unchanged since it started, and never pastes. Once the wall has closed, it pastes
through `ClipboardHistoryPasteService.pasteAfterClosing` unless Copy only is on. Each caller keeps
its own failure presentation, and the wall sends a materialization failure through
`presentActionFailure()` so legacy owned files still get the restore flow.

## Hotkeys and panel

### CGEvent callback concurrency safety

The callback is a C-style free function, not on `@MainActor`. Data is passed safely via
`HotkeySnapshot` (a Sendable value type carrying `HotkeyAction`) plus `nonisolated(unsafe)` storage.

### CGEvent tap timeout & watchdog

The system budgets the tap callback at ~1 second; exceeding it triggers `.tapDisabledByTimeout` and
auto-disables the tap. Current defenses:

- the callback only matches keys; real work is dispatched via `DispatchQueue.main.async`
- on `tapDisabledBy*` the tap is re-enabled inline inside the callback
- a 2-second watchdog checks `CGEvent.tapIsEnabled` and calls `restart()` (tears down and rebuilds
  the tap) if needed
- **never do synchronous expensive work inside the callback** (I/O, SwiftData fetch, modal dialogs,
  etc.)

### HotkeyService health & keyboard lock

`HotkeyService` exposes `tapHealth` (`healthy` / `suspendedByRecorder` / `transientlyDown` /
`failed`) so the UI can surface accessibility-revoked or tap-create failures; a hard failure is only
reported after ≥2 consecutive restart attempts fail. `setKeyboardLocked(_:)` powers a keyboard-lock
feature — while locked the callback swallows every key / keyUp / flagsChanged event, plus
keyboard-originated `NX_SYSDEFINED` aux control buttons (media / function keys: brightness, volume,
mute, play/pause, Mission Control; subtype 8), **before** any matching branch runs, so no other
hotkey, Hyper combo or Quick Press fires (Quick Press would otherwise synthesize real key events
into a supposedly disabled keyboard). The one exception lives **inside** the lock branch: if the
keyboard-lock builtin has a hotkey bound, that exact combo (including a Hyper-combo binding, via a
lock-scoped Hyper-held flag distinct from `hyperHeld`) is dispatched through the normal toggle path
and still swallowed so it does not reach the frontmost app. The tap mask includes bit 14
(`NSEvent.EventType.systemDefined` / `NX_SYSDEFINED`). Only keyboard-originated subtype 8 is
swallowed; mouse-originated `NX_SYSDEFINED` events (subtype 7) must pass through so the lock can
still be released from the panel row. Releasing the lock is mouse-only via the panel row unless that
escape hatch is bound. The lock lives only in the running process, so quitting AnyDoor also drops
it. Any new matching branch must stay below that early return (the escape check is part of the lock
branch itself). Construct `NSEvent(cgEvent:)` only on the locked + type-14 path; do not do that on
the ordinary key hot path.

### Modifier alignment

Both recording and detection use `CGEventFlags` bitmasks (`maskCommand | maskControl | maskAlternate
| maskShift`); do not use `NSEvent.ModifierFlags`.

### Suppress dispatch while recording

When recording a hotkey, the recorder calls `HotkeyService.beginRecording(observer:)` /
`endRecording()`. The tap stays **active** (so the Caps-Lock/F19 Hyper trigger is still observed)
but bound-hotkey dispatch and Quick Press are suppressed while `recordingObserver` is set, so
recording can't fire an existing binding. `suspend()` / `resume()` (which fully disable the tap, and
which the watchdog honors via `isSuspended`) exist but are **not** used by the recorder.

### Data-change notification

Binding add/remove flows through `PanelStore.addAppShortcut` / `deleteAppShortcut`, which internally
`save()` SwiftData, `rebuild()` view state, and invoke the hotkey-refresh closure wired by
`PluginRegistry.bootstrap` — views do not call `modelContext.save()` directly.

### Toggle semantics

`AppSwitcher.toggle` uses `app.isActive` (frontmost check) rather than `app.isHidden`. If the target
is already frontmost it calls `app.hide()`; otherwise (not frontmost, or not running) it routes
through `NSWorkspace.openApplication(at:)` (`activate(at:)`) — deliberately **not**
`NSRunningApplication.activate()`, which macOS 14+ silently ignores when an `.accessory` app tries
to activate while another regular app holds focus. Changing the condition changes the interaction
semantics.

### PanelStore is the single source of truth

Three data sources (the static `BuiltinItem` catalog + `BuiltinPreference` preferences +
`KeyBinding` app shortcuts) are merged in `PanelStore.rebuild()`; views read `topLevelEntries`,
`appShortcutChildren`, and `windowLayoutChildren` (window-layout child rows are partitioned out
separately). **All writes must go through PanelStore's mutation methods** (`setBuiltinVisibility`,
`setBuiltinHotkey`, `updateAppShortcut`, `reorderTopLevel`, `reorderAppShortcuts`,
`reorderWindowChildren`, `addAppShortcut`, `deleteAppShortcut`), which save SwiftData, `rebuild()`
view state, and invoke the injected hotkey refresh — except `reorderAppShortcuts`, which only
changes display order and intentionally skips the snapshot refresh. PanelStore additionally owns the
provider registry and the activation paths (`toggle`, `run`, `setKeepAwakeDuration`) with per-item
in-flight guards. An error a provider throws out of them has not been reported yet (the contract on
the protocols in `BuiltinProvider.swift`): PanelStore logs it with the item key and the error's case
and code public (`CommandFailure.logSummary`; the full error stays private) and shows one failure
notice naming the command (`CommandFailure.toast`). A provider that reports its own outcome returns
normally instead, and `refreshAll` never shows a notice. After a failed toggle PanelStore re-reads
the row's permission, so an open panel asks for a permission the failure revealed as missing.

### HotkeyAction dispatch & snapshot compilation

`HotkeyCoordinator` (`@MainActor`) owns the hotkey side of the panel subsystem. `refresh()` fetches
enabled `KeyBinding` rows + `BuiltinPreference` hotkeys + `Quicklink` rows with recorded hotkeys and
merges the Command Palette hotkey through an injected resolver (production reads
`CommandPaletteService.shared.hotkey`; isolated registry tests inject `nil`), compiling them via the
pure static `compile(bindings:prefs:quicklinks:paletteHotkey:availableCommands:)` (unit-testable
without singletons; `availableCommands` is `PluginRegistry.availableCommands`, so bindings recorded
for an uninstalled plugin's command never compile) and pushing the result to
`HotkeyService.updateSnapshots`. Before a plugin is installed, the registry calls
`resolveRetainedPluginHotkeyConflicts`: if the plugin's retained shortcut was rebound to an active
app, builtin, Quicklink, or Command Palette hotkey while absent, the returning preference is cleared
so the newer binding remains authoritative. `PluginRegistry.bootstrap` wires the paired instances in
both directions: PanelStore mutations invoke an injected refresh closure, while builtin dispatch
invokes injected `toggle` / `run` closures. Other hotkey sources still call
`HotkeyCoordinator.shared.refresh()` after changing (`QuicklinkStore` mutations,
`CommandPaletteService.setHotkey`/`reloadFromDefaults`, and the live-runtime phase inside
`BackupService.restore`). `dispatch(_:)` routes matched `HotkeyAction`s:
`toggleBuiltin`/`runBuiltin` use the injected PanelStore handlers; `launchApp`, `brightnessUp/Down`,
and `showCommandPalette` route directly to AppSwitcher / DisplayBrightnessService /
CommandPaletteWindowController; `openQuicklink` opens a plain Link via `QuicklinkOpener` or, for a
Search Template, summons the palette pre-entered into that entry's argument-input mode.
HotkeyService's callback uses an injected `dispatcher` closure, bound in
`AppDelegate.applicationDidFinishLaunching` to `HotkeyCoordinator.shared.dispatch`. Do not reference
PanelStore or HotkeyCoordinator directly inside HotkeyService — keep HotkeyService decoupled from
business logic.

### Provider isolation

Most ToggleProvider / ActionProvider implementations are their own `actor` and `setState` / `run`
runs serially on that actor; the UI/window-coupled ones (`ClipboardWallProvider`,
`WindowLayoutProvider`, `ImageConversionProvider`, `TranslateProvider`,
`TranslateSelectionProvider`, `ScreenshotTranslateProvider`) and `ClipboardMonitoringProvider`
(which drives the main-actor `ClipboardHistoryLifecycle`) are `@MainActor final class` instead.
`BuiltinProvider.swift` holds only the `ToggleProvider` / `ActionProvider` protocols. The Core
production set is built by
`BuiltinProviderRegistry.makeAll(clipboardProduction:clipboardHistoryLifecycle:onKeepAwakeChange:)`;
plugin-claimed commands contribute providers via `NativePlugin.providers`, and
`PluginRegistry.bootstrap` composes the installed plugin providers with that Core set.
`BuiltinCatalogInvariantTests` pins the catalog contracts a new `BuiltinItem` case must satisfy:
every toggle/action item has a provider of the right protocol (Core + plugin sets combined),
non-actionable kinds have none, every command is Claimed by exactly one owner — a plugin or the Core
(ADR-0006) — with plugin providers covering exactly their actionable claims, `defaultOrder` is
unique, `PanelStore.windowLayoutChildKeys` covers exactly the window-prefixed action cases, every
hiddenHotkey item compiles to a `HotkeySnapshot`, and no case reuses the retired `captureModeBar`
raw value. `PanelStore` is `@MainActor`, and cross-provider writes are scheduled on the MainActor
via `Task { await … }`.

### Hyper Key: two-phase + watchdog

The trigger is remapped to virtual key **F19** (keyCode 80) via `hidutil` `UserKeyMapping`;
HotkeyService then re-emits the Hyper modifier flags (Ctrl+Opt+Cmd, plus Shift when `includeShift`
is on). Phase 1 — at launch `AppDelegate` unconditionally calls `HyperKeyController.reconcile()`,
which **clears** any leftover owned mapping (crash recovery; the controller records the hidutil
entries it owns in the `hyperKey.ownedSignatures` UserDefaults key so it never nukes third-party
mappings). Phase 2 — `HyperKeyService.bootstrapAfterTap` runs once the tap is ready, re-applies the
active trigger, uses a `mutationToken` to stop stale async work from overwriting newer state, and
runs a 2-second watchdog following `HotkeyService.tapHealth`. The trigger/quickPress/includeShift
config lives in **UserDefaults** (not SwiftData). Tapping the trigger alone fires a **Quick Press**
action (none / Escape / original key) via `QuickPressEmitter`, whose synthesized CGEvents carry
`kAnyDoorSynthesizedEventTag` on `eventSourceUserData` so the tap passes through its own emissions
(the Caps-Lock "original" case toggles via IOKit `IOHIDSetModifierLockState`). The mapping is
cleared on system power-off (`willPowerOffNotification`) and on termination (gated on
`hasPersistedSignatures`).

## Native plugins

### Native Plugins (ADR-0005/0006/0007)

First-party feature modules the user installs/uninstalls from Settings → Plugins; code always ships
(install is a logical state in UserDefaults key `plugins.installed`). `NativePluginCatalog` is the
one compile-time inventory: each registration pairs a stable id, unconditional SwiftData schema
types, and its runtime factory, so AppDelegate cannot register one launch phase while forgetting the
other. `PluginRegistry` (`@MainActor @Observable`, `Services/Plugins/`) is the single runtime seam:
it receives catalog-built instances and owns exclusive claim lookups
(`claimOwner`/`isAvailable`/`availableCommands`), lifecycle, and surface composition. Bootstrap
starts runtime install state empty, activates each persisted plugin before marking it Installed, and
then publishes the initial provider/palette state in one batch; it wires `PanelStore` and
`HotkeyCoordinator`, but the first hotkey snapshot is deliberately published later in normal app
startup so bootstrap cannot start the event tap early. Runtime `install` resolves retained-hotkey
conflicts, activates, persists, registers providers/palette contributions, then rebuilds the panel
and refreshes hotkeys. `uninstall` runs the plugin's throwing `deactivate()` (release shared
resources, cancel in-flight work) **before** any state or surface change, so a thrown error leaves
the plugin fully installed. Uninstalled = invisible everywhere: `PanelStore.rebuild` drops
unavailable commands (panel, palette, and Panel settings all derive from it), hotkey compilation
drops their bindings, and clipboard-history context-menu actions come from
`PluginRegistry.clipboardActions(for:)` over installed plugins only (the former registered-debt
convert-image hardwiring is paid down: `NativePluginCatalog` is now Core's sole concrete plugin
import — the card builds a neutral `PluginClipboardPayload` via `ClipboardPluginPayloadMapper`,
plugins answer with `PluginClipboardAction` descriptors, and commit routes back through
`PluginRegistry.performClipboardAction`, which re-checks install state). Plugin user data (SwiftData
rows, preference rows, hotkeys) is retained; reinstall restores it without relaunch, except a
retained hotkey is cleared when its descriptor was rebound while the plugin was absent.
`plugins.installed` is whitelisted in `SyncSettingsRegistry`, and
`PluginRegistry.reconcileAfterImport()` (async throws, awaited inside the single
`BackupService.restore` workflow) adopts an imported set through the real lifecycle — removals run
before additions, every successful transition publishes immediately across the async boundary, and a
failed deactivate keeps the plugin installed and re-persists reality — then forwards the import to
the plugins that end up installed. Upgrading users are migrated by `PluginUsageMigration` (see the
launch-time seeding note). Palette contributions (option parents, options, row sources) register
directly through `CommandPaletteExtensions.registerContributions(of:)` inside the registry, and a
plugin can contribute a panel-row popover via `NativePlugin.panelPopover(for:)` (a
`PluginPanelPopover` descriptor; `MenuBarView`'s generic submenu branch resolves it through
`PluginRegistry.panelPopover(for:)`, so it disappears when uninstalled). Pilots:
`ImageConversionNativePlugin` and `HostsNativePlugin`; each constructs one immutable
`PluginHostContext` from its injected `PluginHostServices` and passes that instance to its manager,
writers, providers, view models, window controllers, and SwiftUI root environment. No module-level
host slot exists, so plugin instances and test fixtures cannot overwrite one another. Each module
keeps a typed `L10n` key enum plus thin `L(host:_:)` / `LocalizedText` fronts resolving against the
shared catalog. Image Conversion closes an activation-generation presentation gate before
deactivation, rejects new view-model work, and cancels plus awaits every owned task; a window action
already waiting on Finder therefore cannot reopen after uninstall or become current after a quick
reinstall. The Hosts plugin's `deactivate()` first closes its editor, cancels pending debounced
applies, drains any writer that already crossed the external boundary, then releases the privileged
helper if no other consumer needs it (`PrivilegedHelperRelease` — forced Scheduled Shutdown shares
the daemon, amended ADR-0005). It never starts an `/etc/hosts` write or prompts for admin
authorization during uninstall; active profiles and their managed block remain in effect until
reinstall. A failed helper release resumes the manager and leaves the plugin fully installed. Adding
or modifying a plugin: follow the [Native Plugin playbook](native-plugins.md).

### Native Plugin isolation and recovery invariants

Mutable stores are owned by the plugin instance and injected downward; never add a module-level
`shared` store with a later `configure` step. Image Conversion owns one history store bound to its
captured container. Palette row-source routing uses `PluginRowSourceKey(pluginID:localID:)`, so
plugin-local ids cannot collide across owners. `PluginRegistry.reconcileAfterImport()` attempts
every delta, re-persists the installed state that actually converged, forwards reconciliation to
installed plugins, and then throws an aggregate `PluginImportReconciliationError` for failed
removals; `BackupService` finishes every other runtime refresh before surfacing that partial
failure. Fresh-install onboarding is Core-only; Settings → Plugins is the sole place an uninstalled
plugin is advertised.

### Native Plugin transition convergence

`PluginRegistry` is `@MainActor`, but `deactivate()` suspends and therefore permits actor
re-entrancy. A concurrent uninstall request throws `PluginTransitionInProgressError`, and backup
reconciliation checks `transitioningIDs` before and after its awaited removals so it cannot report
success while another transition can still reverse the imported target.

## Script plugins

### Script Plugins are the second lifecycle kind (ADR-0008/0009)

Sideloaded, TypeScript-authored/esbuild-bundled pure-JS packages the user installs from Settings →
Plugins. Both `PluginRegistry` (Native) and `ScriptPluginRegistry` (Script) are distinct instances
driving the same kind-agnostic `PluginLifecycleCore` (`Services/Plugins/PluginLifecycleCore.swift`)
through the `AnyPluginLifecycleHost` delegate — the core speaks only opaque id strings + generic
verbs (install-state set + persistence, activate-before-installed ordering, transactional uninstall,
backup reconcile, live palette recomposition) and never names a kind-specific concept, so the second
kind shares the machinery instead of forking a parallel registry. Where a Native "install" flips a
flag on always-shipped code, a Script Plugin is sideloaded from disk:
`ScriptPluginRegistry.sideload` validates the manifest and refuses a duplicate id **before** any
copy (a bad or duplicate package changes nothing on disk, in the registry, or in Settings), copies
the package into `~/Library/Application Support/dev.bybee.AnyDoor/ScriptPlugins/packages/`, then
installs through the core; uninstall tears down the JS context, removes the package copy and its
palette row source, and **retains** the plugin's private key-value store so reinstalling the same id
restores its data. Uninstalled = invisible everywhere (no rows, no Detail, no search results), same
invariant as Native. Script deactivation only destroys a JS context (no external side effect), so
unlike Native it never throws to abort. Install state (`plugins.script.installed`), the private
store, developer mode (`plugins.script.developerMode`), and dev directories
(`plugins.script.devDirectories`) are all **machine-local and out of backup/sync entirely** — none
is in `SyncSettingsRegistry`, so `reconcileLifecycleImport` is a no-op for this kind (Script
packages exist only on the local machine). A package may also arrive as a **zip**
(`sideload(fromZip:)` extracts via `ScriptPluginArchive` — `ditto` through `ProcessRunner`, off the
main actor with a 30 s timeout, unwraps a single wrapper folder, ignores `__MACOSX`/hidden files —
into a temp dir and reuses the directory path) or via the
**`anydoor://install-plugin?url=` link** (`ScriptPluginURLInstaller`, wired from
`AppDelegate.application(_:open:)`; scheme registered in `Info.plist` `CFBundleURLTypes`, so only
the `.app` identity receives it): the pure `PluginInstallURLParse.classify` accepts only an https
package URL, the download is capped at 20 MiB, the package is extracted and validated (duplicate id
refused) **before** a confirmation dialog shows name/id/version/origin host/declared capabilities,
and approval routes through the same `sideload` path — every refusal changes nothing but its own
temp files.

### Script Plugin runtime execution model (ADR-0008)

`ScriptPluginRuntime` (`Sources/ScriptPluginRuntime/`, `@MainActor`) owns one `ScriptPluginContext`
per loaded plugin — a single `JSContext` confined to its own serial `DispatchQueue`, created
**lazily** on first invocation and recreated lazily after a kill, so one runaway plugin never stalls
another. Capability calls trampoline to the main actor and settle back on the plugin queue;
`JSValue`s never leave the queue (decoded to the Sendable `ScriptValue` before any `await` resumes),
which is what makes the context's narrow `@unchecked Sendable` sound. Every invocation runs under a
hard 30-second **dual watchdog**: a synchronous runaway (`while(true){}`) is cut by JavaScriptCore's
execution-time-limit SPI (armed via the `JavaScriptCoreWatchdog` C shim — the queue is blocked so no
host timer can fire), and a never-settling async promise by a host wall-clock `DispatchWorkItem` on
the same queue (the queue is idle so it fires); either kill destroys the context and returns
`.timedOut`, and the next invocation recreates it. A synchronous throw or a rejected promise yields
a typed `ScriptPluginError` and an inline error row/Detail, never a host crash. Contexts are marked
`isInspectable` for the Safari Web Inspector. The engine is **never mocked**: the test seam is the
**package boundary** (a real manifest+bundle in; palette descriptors + capability side effects out)
with real JavaScriptCore underneath; network is the sole mocked external boundary, behind the
injected `ScriptFetchTransport`.

### Script Plugin capability sandbox (ADR-0009)

A plugin can only do what the host injects into its `JSContext`, so the manifest's
declared-capability list *is* the security model. The granted set is **seven** — `fetch`, a
plugin-private key-value `store`, `toast`, pasteboard write (`copy`), one-shot `delay`, `openURL`,
and `translate` (milestone A granted the first six; `translate` joined as an ADR-0009 amendment) —
each injected **only when the manifest declares it** (`ScriptPluginContext.injectCapabilities`); an
undeclared capability does not exist in the context. No shell, AppleScript, filesystem, or
pasteboard *read*. `translate` (`PluginTranslator`, Core) translates through the user's configured
translation services into the Settings target language — a plugin cannot choose the direction; it
uses the first enabled non-manual service with no fallback, caps input at 10k characters
runtime-side, and writes no `TranslationRecord` history. Pasteboard writes route through the
injected `ClipboardHistoryPasteboardSelfWriteFunnel`, so a plugin's copy never lands in clipboard
history; the `store` is a `FileScriptKeyValueStore` (one JSON file per id, outside SwiftData,
surviving uninstall/reinstall). `openURL` is confined to an http/https allowlist
(`ScriptOpenURLPolicy`, case-insensitive, scheme-less rejected) enforced at **all three** plugin-URL
boundaries: the JS `anydoor.openURL` capability, a Row Action `.openURL` commit
(`CommandPaletteCommitIntent.classify`), and a tapped markdown Detail link — a `file://` or
custom-scheme URL is rejected everywhere, never opened.

### Script Plugin palette surface

Script Plugins contribute to the **command palette only** — no panel rows, no recordable hotkeys
(that would require opening the closed `BuiltinItem` command identity, ADR-0006). Root rows flow
through the existing generic `PluginRowSource`/`PluginRowDescriptor` channel:
`ScriptPluginRowSource` bridges the async JS entry points (`rows`/`list`/`detail`/`action`) onto the
synchronous contract — `reload()` kicks one async `buildRows` per palette open and caches, `rows()`
returns the cache, a completed row `action` re-runs `buildRows` and nudges the visible palette (so a
stayOpen toggle's `badge`/state re-renders immediately), and `.loading`/`.failed` render a
placeholder or inline-error row instead of hanging. A failed Detail or pushed list additionally
offers a retry affordance (a button, with Return mapped to it) that re-requests the content in place
through `CommandPaletteState.retryDetail()`/`retryList()` — a claim that only a failed level grants,
landing under the unchanged navigation generation. New drill-in semantics extend
`CommandPaletteCommitIntent.classify` (still exhaustive over `PanelEntry.Source`, so a new semantic
must declare its intent or fail to compile): `.pushDetail` pushes a system-markdown Detail (rendered
by `MarkdownBlocks` in `Utilities/`, no third-party renderer; blockquotes draw with a leading bar,
and Markdown images render as inline previews confined to the http/https allowlist like every
other plugin-URL boundary) and `.pushList` pushes a searchable second-level list, each a new palette
navigation level. A Detail paginates: `detail()` may return `{ markdown, more }` with an opaque
cursor, and when the user scrolls to the bottom sentinel the host calls `detail(rowId, cursor)` and
appends the chunk (`CommandPaletteState.beginDetailMore`/`appendDetailChunk` gate one fetch at a
time; a failed or empty chunk ends pagination cleanly). A pushed list paginates the same way:
`list(listId, query, cursor)` may return `{ rows, more }`, and the host shows a bottom sentinel
below the last row (hidden while a second-level query is active — filtering is local to the loaded
rows) and appends the next page with already-present row ids dropped
(`beginListMore`/`appendListRows`, one fetch at a time; a failed page keeps what is shown and stops
paginating). A Detail may declare footer `actions` (`PluginRowDetailAction`): the host renders a
bottom button bar, and a press calls the plugin's `detailAction(rowId, actionId)` whose result
replaces the document wholesale (content, cursor, and next actions) through the same loading state
and generation guard; appended pagination chunks' actions are ignored. A slow Detail/list result is
keyed to the exact drill-in that requested it by a **generation token**, so A→back→B can never
cross-populate — appended Detail chunks ride the same token. **Invariant:** each drill-in level
shifts the SwiftUI slot of the overlaid AppKit search field, so any new navigation level **must bump
`CommandPaletteState.navigationRevision`** — the controller re-anchors the field
(`relayoutSearchFieldSoon`) and shows/hides it off that revision; without the bump the field lands
one transition behind.

### Script Plugin Dev Plugin mode (ticket 023)

An author registers a development **directory** as a Dev Plugin, loaded **in place** and never
copied. This in-place path is reachable only for registered dev directories — a sideloaded
(installed) plugin always runs from its copied-in package — so a store-era plugin can never be made
to run from an arbitrary directory. Gated behind the machine-local developer-mode switch (off by
default): turning it off tears down the dev contexts and row sources but keeps the persisted
dev-directory list, so re-enabling restores them. A `DirectoryWatcher` (FSEvents) reloads the
plugin's context on every rebuild, so `pnpm dev`'s esbuild `--watch` output surfaces in the palette
within seconds with no reinstall/relaunch; a reload whose manifest no longer validates (or whose id
changed) is a logged load refusal surfaced through the row source's failed state. Dev Plugins
surface full error detail (message + stack) where an installed plugin shows only a generic inline
string. Every Script Plugin failure — load refusals, watchdog kills, capability errors — is recorded
per-plugin by `FileScriptPluginLog` at `ScriptPlugins/logs/<id>.log`, so a field failure is
diagnosable from a file, not just a toast.

### Script Plugin author tooling (`tooling/`)

A standalone pnpm workspace outside the SwiftPM build, so `swift build`/`swift test` never need
Node. `@anydoor-dev/api` is the typed authoring package — its `definePlugin` narrows each entry
point's API to exactly the capabilities the manifest declares, a compile-time echo of the ADR-0009
boundary before the host ever enforces it; `create-plugin` is the TypeScript+esbuild scaffold;
`examples/v2ex` and `examples/hackernews` are worked examples. `pnpm verify` builds the api,
scaffolds and builds the template, and asserts the bundle is single-file pure-JS with no Node
built-ins. The definitive end-to-end check — a generated bundle loading on real JavaScriptCore — is
a Swift test (`ScriptPluginToolingTemplateTests`) running a committed prebuilt fixture through
`ScriptPluginRuntime`; regenerate that fixture with `node tooling/scripts/refresh-fixture.mjs`. The
Swift↔TS behaviour contract (row action union, manifest shape, capability list) is pinned by a
second committed fixture: `tooling/packages/api/type-tests/contract-fixtures.ts` (type-checked
against the authoring types, one fixture per `RowAction` variant enforced by a mapped type) is
emitted to `Tests/AnyDoorTests/Fixtures/ScriptContract/contract.json` by `node
tooling/scripts/refresh-contract-fixtures.mjs`, decoded host-side by `ScriptContractFixtureTests`
(which also pins that every authorable `CommitSemantics` case is exercised), and `pnpm verify` fails
when the committed JSON is stale — so a contract change that lands on only one side fails a machine,
not a plugin author.

## Command palette

### Command palette root search

Root entries rank through `CommandPaletteQueryMatch.rank` (`CommandPaletteState.rootRank`): the
active-language title ranks exact, prefix, or other, and every alias hit ranks `.other`, so an alias
never outranks a title prefix. Within a tier, `rankedByGlobalTiers` keeps section order, and every
builtin section precedes Applications. Installed-app aliases and Quicklink Keywords
(`PanelEntry.searchAliases`) match anywhere in the alias, which lets a Chinese-UI user find 微信 by
typing "chat". Builtin entries carry Core-side bilingual aliases instead: `BuiltinItem.paletteAliases`
(in `BuiltinItem+Core.swift`, not `PluginInterface`), which `PanelStore.rebuild()` copies into
`PanelEntry.wordStartAliases`. They are match data rather than catalog strings, so either language's
terms work in either UI; they are never shown; and they match only at the start of the alias or of one
of its whitespace-separated words. Substring matching there would let "ding" or "co" put Record
Screen ("screen recording") above an app that a Chinese-UI user opens by its English name.

### Command palette second-level menu

Option-bearing commands drill into a second level instead of acting with a default.
`CommandPaletteExtensions` (`@MainActor`, `Services/CommandPaletteExtensions.swift`) is the
palette's generic extension-point registry (ADR-0007): which builtins are option parents is declared
by **registration** — `CommandPaletteExtensions.core()` (defined next to the builders in
`CommandPaletteOptions.swift`) registers the Core's parents (`keepAwake` / `scheduledShutdown` /
`brightness` / `portManager` / `pickColor` / `captureTimer`), each pairing a root-listing policy
(`listsAtRoot`, e.g. Brightness gates on an external DDC display) with an options builder; installed
Native Plugins register/unregister through the same API via `registerContributions(of:)`, owned by
`PluginRegistry` lifecycle publication (the Hosts plugin's `hostsManager` parent works this way, its
options built by the pure `HostsPaletteOptions` and performed by
`NativePlugin.performPaletteOption`). The pure per-item builders stay on `CommandPaletteOptions` and
take fetched state (`isOn` / `isArmed` / `displays` / `profiles` / port `records`) so they unit-test
without singletons; the commit-intent classifier takes the registry as an injectable parameter.
`CommandPaletteState` holds a `.root` ⇄ `.options` stack; option rows reuse `PanelEntry` via
`Source.paletteOption(id:)` (only a `String`, the action looked up by id on the MainActor), and the
second-level search matches title **and** subtitle (so a port number filters the port list).
`CommandPaletteWindowController` lists Brightness (only with an external DDC display), Port Manager,
and Hosts (while its plugin is installed), drills in on commit (entering even an empty options array
so it shows the empty state rather than closing), runs an option then closes. `Esc` runs
`CommandPaletteState.handleEscape()` (a testable policy returning `.clearedQuery` / `.poppedToRoot`
/ `.dismiss`): a non-empty query clears first at either level, then an empty query pops to root from
the second level or dismisses at the root (empty-query `Backspace` also pops). Navigation frames
carry the search text typed at their level, so popping restores it (a root search survives a
drill-in round trip; selection restarts at the top since the row set may have shifted); `popToRoot`
still clears everything. Port Manager drilling refreshes `PortInventory` and kills the selected
port's process. A second, faster path coexists: typing a port number at the root surfaces a "Ports"
section (`CommandPaletteState.portSection` over `PortInventory.records`, rows carrying
`PanelEntry.Source.portRecord`) whose rows kill on commit — so ports are reachable both by drilling
into Port Manager and by direct numeric search. Both kill paths are guarded by a Raycast-style
in-palette confirmation card: commit routes through `CommandPaletteState.requestConfirmation` (a
`pendingConfirmation` slot holding a `CommandPaletteConfirmation` descriptor + a `@MainActor`
perform closure) instead of killing; `CommandPaletteOption.confirmation` marks options that need it
(set by `portOptions` via `portKillConfirmation(for:)`), and the controller builds the same
descriptor for `.portRecord` rows. While `isConfirming`, the key monitor maps
Return→`confirmPending()`, Esc→`cancelConfirmation()`, and swallows other keys;
`CommandPalettePicker` overlays the card. Row commit semantics are declared in
`CommandPaletteCommitIntent.classify(_:)` (`Services/CommandPaletteCommit.swift`), exhaustive over
`PanelEntry.Source`: stay-open intents (drill-in / confirmation / dev-tool scope) vs close-then-act
intents (launch / toggle / run / copy). `CommandPaletteWindowController.commit` is a flat switch
over the intent — when adding a Source case, declare its intent in the classifier (the compiler
forces this) rather than adding control flow to the controller. Plugin-style root rows (hosts
profiles today, searchable by name) flow through the generic
`Source.pluginRow(sourceKey:descriptor:)` case carrying a `PluginRowDescriptor` from
`PluginInterface` (title / subtitle / symbol / footer action label / trailing status `badge` chip /
commit semantics); the classifier maps a plugin row exhaustively by its declared semantics
(`stayOpen` / `closeThenAct`) and the controller performs it via `PluginRowSource.performRow(id:)`
looked up in the registry — palette control flow never names the feature behind a row. Row sources
declare their own `sectionTitleKey` (a raw catalog-key string rendered via
`L(raw:)`/`LocalizedText(raw:)`, so a plugin section needs no Core `L10n.Key` case), get one
`reload()` per palette open (`collectSections`), and rebuild `rows()` per query pass;
`HostProfileRowSource` (in `HostsPlugin`) is the first source, registered by the plugin's install
lifecycle.

### Plugin row-source identity

The current root-row API is `Source.pluginRow(sourceKey:descriptor:)`, and commit lookup is
`CommandPaletteExtensions.rowSource(for:)`. `PluginRowSource.id` is only local to its plugin; Core
must combine it with the owner id into `PluginRowSourceKey` at registration. Do not reintroduce a
process-global string `sourceID`.

### Live Command Palette plugin refresh

Every runtime plugin install/uninstall recomposes an already-visible Command Palette from the live
command and row-source registrations. Preserve the root query, but discard drill-in state because it
may retain option closures owned by the plugin that just disappeared. Do not limit lifecycle
publication to PanelStore and hotkeys.

### Command Palette plugin-surface resume

Closing the palette while the user sits on a plugin surface (a pushed list or markdown Detail)
retains the `CommandPaletteState`, and the next plain root open resumes that navigation instead of
resetting — hiding the palette mid-read must not lose a v2ex post. Only these two levels qualify
(value-only payloads); options/argument levels still reset, and a hotkey-summoned argument-input
open never resumes. Before reuse the controller validates every row source the retained stack
references against the live registrations (`canResume` — a plugin uninstalled while hidden discards
the navigation), refreshes root sections/row sources in place, and `prepareForResume()` drops any
pending confirmation, bumps `navigationRevision` (so pre-close in-flight results are
generation-rejected), clears `isFetchingMore`, and reports a mid-load level for the controller to
re-fetch (`resolveDetail`/`resolveList`). A resume landing directly in a Detail must hide the
overlaid AppKit search field explicitly — `onDetailActiveChange` only fires on a change.

## Windows and localization

### The menu bar is not MenuBarExtra

The menu-bar item is owned by the AppKit `MenuBarController` (`NSStatusItem` + a floating
`NSPanel`). SwiftUI `MenuBarExtra` with `isInserted: false` infinite-loops the scene graph on macOS
26. `AnyDoor.swift` keeps a stub `Settings { EmptyView() }` scene because a SwiftUI `App` requires
one scene; the Settings… ⌘, command and hidden-icon reopen recovery both route through
`SettingsOpener`. The real Settings window is a manually managed fixed-size NSWindow owned by
`SettingsWindowController` (`.fullSizeContentView`, transparent titlebar, default traffic lights, no
collapsible sidebar).

### Window launch and restoration must stay off

An empty Settings scene is still a real window to SwiftUI. On macOS 15+, `AnyDoorApp` applies
`.defaultLaunchBehavior(.suppressed)` and `.restorationBehavior(.disabled)` to prevent the blank
"AnyDoor Settings" window from being presented by `SwiftUI.AppWindowsController.showInitialWindows`.
`AnyDoorMain` selects a separate legacy SwiftUI App on macOS 14 because these modifiers require
macOS 15 and SceneBuilder does not support an availability-check else clause. Keep the AppDelegate
save/restore vetoes and each manual window's `isRestorable = false`, but do not treat those as a
substitute for scene-level launch control. Verify launch, close/relaunch, intentional Settings
opening, and hidden-icon recovery against the installed app; pure reopen-policy tests do not
exercise SwiftUI's initial presentation.

### Dynamic activation policy

Normally `.accessory` (no Dock icon). `RegularWindowCoordinator` switches to `.regular` while a
"real" window (Settings, the Hosts editor) is open — otherwise the window slips behind and can't be
resurfaced — and reverts to `.accessory` once the last one closes.

### AppDelegate lifecycle extras

`applicationShouldTerminate` clears the Hyper Key mapping (racing a 500 ms timeout) before quitting;
`applicationShouldHandleReopen` re-opens Settings when AnyDoor is relaunched with no visible window,
so a hidden menu-bar icon can be re-enabled.

### Localization

UI strings go through `LocalizationManager.shared` (system / Simplified Chinese / English), injected
via `.environment`. New user-facing strings use `L10n` / `LocalizedText`; do not hardcode them. The
`.xcstrings` catalog is compiled at build time by the `XCStringsCompilerPlugin` build-tool plugin.

### Overlay scrollers everywhere

Scrollbars must use the floating, auto-hiding **overlay** style (reserving no layout width,
Raycast-like), never the system's persistent legacy scrollbar that appears when "Show scroll bars"
is set to "Always". The **primary** mechanism is app-wide: `AppDelegate.init` sets
`UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")`. Writing it to the app's
own defaults domain (higher priority than `NSGlobalDomain`, where the system value lives) overrides
the system setting for this process, so every `NSScrollView` — SwiftUI `ScrollView` / `Form` /
`List`, popovers, the menu panel — is *born* with overlay scrollers. This matters specifically
because any **after-the-fact** restyling of a `Form`'s scroll view flashes the legacy thick
scrollbar for one frame on a Settings tab switch (the `Form` inserts its scroll view a layout pass
later than a `.background` helper can reach it, so the fix-up is necessarily deferred a runloop —
past the first paint); making the scroll view overlay from birth is the only flash-free fix. Two
**reinforcement** mechanisms re-assert the style on specific scroll views: (1) `.overlayScrollers()`
(`Views/Common/OverlayScrollers.swift`) — apply to the scroll **content** (e.g. a `LazyVStack`),
where it resolves `enclosingScrollView` synchronously, or to a `Form`/`List` container, where it
lands as a `.background` *beside* the scroll view and climbs the **superview chain** (not the whole
window — the Settings `TabView` can keep hidden tabs' scroll views around, so a window-wide scan
would restyle the wrong tab) to find it. (2) for `NSTextView`-backed editors, set `scrollerStyle =
.overlay` + `autohidesScrollers = true` + `verticalScroller?.scrollerStyle = .overlay` directly in
`makeNSView` — done in `EnterToTranslateEditor` (translation input) and `PlainTextEditor` (in
`PluginSupport`; used by the Hosts editor **and** the translation prompt-template field). SwiftUI
`TextEditor` can't set the scroller style reliably (its `.background` injection point doesn't
resolve to its own scroll view), so use `PlainTextEditor` instead of `TextEditor` when a multiline
editor needs the overlay style.

## System services

### Privileged hosts writes

When the XPC helper is enabled, `/etc/hosts` is written by `AnyDoorHostsHelper` (a privileged
LaunchDaemon installed via `SMAppService.daemon`); `HostsManager` (in the `HostsPlugin` target)
coordinates, and the plugin reaches the helper only through the `PrivilegedHelperAccess` host
capability (`PluginHostServices.privilegedHelper`, implemented by `CorePluginHost` over
`HelperManager` + the `PrivilegedHelperCall.writeHosts` XPC call). When the helper is **not**
enabled (ad-hoc/dev builds, or before approval), the plugin falls back to `AppleScriptWriter`, which
copies a temp file over `/etc/hosts` via an administrator-authorized `do shell script`.
`HostsManager.makeWriter` re-resolves the writer on every write from the capability's `readiness()`
(`PrivilegedHostsWriter` when `.enabled`, else `AppleScriptWriter`), so helper approval takes effect
without a relaunch (`MockHostsWriter`, defined in the `AnyDoorTests` target, is the sanctioned test
double). Uninstalling the Hosts plugin unregisters the helper daemon only when forced Scheduled
Shutdown doesn't need it (`PrivilegedHelperRelease` in `HelperManager.swift`). The helper validates
every caller's code signature via the peer **audit token** (the `XPCAuditToken` ObjC shim, which
redeclares the private `NSXPCConnection.auditToken`) — requiring Team ID `9VM4RM39R3` + identifier
`dev.bybee.AnyDoor` — to close the PID-recycle TOCTOU window. The XPC contract (`@objc
PrivilegedHelperProtocol` + `PrivilegedHelperConstants`, including a 1 MiB payload cap and a
fixed-verb `shutDown` method used by Scheduled Shutdown) lives in the shared `HostsHelperShared`
target, imported by both the app and the helper.

### Brightness backend selected by architecture

`DisplayBrightnessService` drives a `BrightnessController` (an `actor` that serializes DDC VCP 0x10
I/O and retries a failed write once); the `DDCBackend` is injected into that controller in
`AppDelegate`, where `#if arch(arm64)` chooses `Arm64DDCBackend` else `IntelDDCBackend`. Brightness
up/down are hidden hotkeys (`HotkeyAction.brightnessUp/Down`).

### Clear Notifications dismisses through Notification Center's own actions

`ClearNotificationsProvider` runs `SystemNotificationDismisser`, whose
`AccessibilitySystemNotificationSurface` performs the AX custom actions Notification Center itself
offers on its banners, alerts, and stacks, matched by the labels in its localized string table for
the language it runs in (`AXPreferredLanguage`, else the global `AppleLanguages`). Nothing in it
picks an action by position, goes through System Events, opens the panel, or reads notification
text, and a run reports success only from a complete read of the tree.

### Scheduled Shutdown

`ScheduledShutdownService` (`@MainActor`, like HyperKey/CommandPalette) owns a one-shot schedule —
it persists the absolute target `Date` (`scheduledShutdown.fireDate`), re-arms on launch (cancelling
a deadline missed while quit), re-validates on `NSWorkspace.didWakeNotification`, and shows a
cancelable floating-`NSPanel` warning (`ShutdownWarningWindowController`) before firing. A deadline
that lapsed while the app was not running (Quit, crash, silent Sparkle update relaunch, restart) is
cleared silently by `bootstrapOnLaunch`: it never fires retroactively and shows no toast. The
service also owns the on/off policy: `setArmed(_:)` arms the configured `defaultMinutes` countdown
or cancels. The panel row and its global hotkey reach it through `PanelStore.toggle`, which
special-cases the item and calls `setArmed` on the service directly, so the read and the write share
one MainActor turn; the thin `ScheduledShutdownProvider` (`ToggleProvider`) exists to satisfy the
catalog invariant, and no production path calls its `readState` or `setState`.
`PanelStore` mirrors its Keep Awake plumbing (`scheduledShutdownState`,
`setScheduledShutdownDuration` for the duration presets, `onScheduledShutdownStateChange`). The
service's `onChange`, which `PanelStore.bootstrap` subscribes before `bootstrapOnLaunch` runs and
which the service calls synchronously on every transition, is the only path that carries the
service's transitions into the cache; `refreshAll` also re-reads the state when the panel or palette
opens.
Execution goes through `ShutdownExecuting`: graceful via `AppleScriptRunner` (System Events,
Automation permission), forced via the privileged helper. Config
(`forced`/`warningLeadSeconds`/`defaultMinutes`) is portable via `SyncSettingsRegistry`; the live
`fireDate` is machine-local.

## Backup and sync

### Config sync / backup

Backup (Settings → Sync) serializes app shortcuts (`KeyBinding`), builtin preferences
(`BuiltinPreference`), quicklinks (`Quicklink`, full rows incl. keyword/hotkey/open-with; schema
v2), and whitelisted general settings (`SyncSettingsRegistry`, including the installed Native Plugin
set `plugins.installed`) into a schema-versioned Codable `BackupSnapshot`. Clipboard history,
machine-specific keys (helper approval among them — approval never travels in a backup; an import
triggers helper daemon *registration* only as a consequence of installing the Hosts plugin, like a
hands-on install, never independently), and the favicon cache are excluded, `appPath` is never
serialized (re-resolved from bundle ID on import), import merges per key (imported wins, local-only
rows kept; quicklinks merge by `id`, and a keyword collision clears the differently-id'd local row's
keyword so uniqueness holds; an older backup's retired `captureModeBar` entry merges into
`screenshot` under the launch migration's rules, after `screenshot`'s own entry, and export never
writes that key), and `BackupService.reconcileLiveRuntime()` re-reads settings into
CommandPaletteService / LocalizationManager / HyperKeyService / ScheduledShutdownService /
CaptureSettings / TranslationSettings, adopts the imported installed-plugin set through
`PluginRegistry.reconcileAfterImport()` (real install/uninstall lifecycle, so plugin surfaces appear
or disappear), re-applies the imported clipboard custom tags and monitoring settings to the history
module, rebuilds QuicklinkStore and PanelStore, and refreshes hotkey snapshots so changes apply
without relaunch. Backup has no storage protocol: `SyncSettingsView` writes the `BackupCodec` JSON
atomically to the NSSavePanel URL and reads the NSOpenPanel URL directly (a missing file reads as
empty data, so `BackupCodec.decode` reports the failure). Automatic multi-device Config Sync
(`Services/Sync/`, ADR-0010) is a separate subsystem that shares the backup DTOs (via
`SyncSnapshotMapping`), `SyncSettingsRegistry`, and `BackupService.reconcileLiveRuntime()` but not
backup semantics; its storage seam is the `SyncTransport` protocol (`SyncFolderTransport`,
`SyncWebDAVTransport`).

### Backup reconciliation errors are not swallowed

Plugin import reconciliation is best-effort across every requested transition, but any failed
removal is returned as a structured aggregate after all other live settings, stores, panel rows, and
hotkeys have refreshed. The persisted installed set is rewritten to match runtime reality, and the
Sync UI reports a partial failure instead of a successful import.

## Capture and recording

Still capture runs through [CaptureCoordinator](../../Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift)
and [LegacyScreenCapture](../../Sources/AnyDoor/Services/Capture/LegacyScreenCapture.swift).
The latter resolves the synchronous CoreGraphics screenshot symbols with `dlsym`. Its source comment
documents the macOS 26 Swift executor corruption observed after a successful ScreenCaptureKit capture;
changing the calling thread or actor did not avoid it. Preserve this backend and its explicit Screen
Recording permission flow when changing capture orchestration.

[ScreenRecordingEngine](../../Sources/AnyDoor/Services/Recording/ScreenRecordingEngine.swift) uses
`AVCaptureScreenInput` and `AVCaptureMovieFileOutput`, for the same crash reason. ScreenCaptureKit is
banned project-wide. Recording supports microphone input; it does not capture system audio. Adding
system audio requires a separately designed pipeline and permission model.

Scrolling capture is interactive: [ScrollCaptureCoordinator](../../Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift)
selects or reuses a viewport, then [ScrollCaptureSession](../../Sources/AnyDoor/Services/Capture/ScrollCaptureSession.swift)
captures on the user's actual scroll events below its preview/outline windows.
[ScrollStitchAccumulator](../../Sources/AnyDoor/Services/Capture/ScrollStitchAccumulator.swift) owns
live two-direction stitching and runaway caps. Done delivers through `CaptureCoordinator`;
Cancel and Escape discard the session. Annotation rendering belongs to
[AnnotationRenderer](../../Sources/AnyDoor/Services/Annotation/AnnotationRenderer.swift), whose flipped
AppKit graphics context composes elements, crop, blur, and pixelation.

## Dependency and release policy

Update dependencies manually, including Sparkle, libwebp, and AskForPermission. Keep Sparkle's package
version synchronized with `SPARKLE_VERSION` in the [Makefile](../../Makefile). Dependabot is used for
vulnerability alerts only: keep repository alerts enabled and automatic security updates disabled;
version-update configuration is intentionally absent. Third-party license texts live in
[THIRD-PARTY-LICENSES.md](../../THIRD-PARTY-LICENSES.md).

Release commands do not run the test suite. Follow the shared check lane in
[development](../development.md) before the [deployment runbook](../deployment.md), and preserve
Stable/Beta branch, identity, dry-run, signing, notarization, and feed-publication checks in
[Beta Updates](../beta-updates.md). The hardened-runtime app must carry
`com.apple.security.automation.apple-events`; Finder and System Events features depend on it.
