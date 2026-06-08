# AnyDoor

A macOS menu-bar toolbox. At its core it toggles (show/hide) a target application via a global hotkey, and builds a set of system-level quick actions on top of that: clipboard history, hosts management, external display brightness, Hyper Key, window layout, command palette, and more.

## Tech Stack

- Swift 6.2, strict concurrency mode (`.swiftLanguageMode(.v6)`)
- macOS 14+
- Liquid Glass on macOS 26+; earlier supported systems fall back to a plain material background.
- SwiftUI `Settings` scene + AppKit `MenuBarController` (the menu-bar item is managed directly by `NSStatusItem`, **not** `MenuBarExtra` — see below)
- SwiftData persistence
- CGEvent tap for global hotkey monitoring
- Privileged XPC helper (`AnyDoorHostsHelper`) writes `/etc/hosts` (with an AppleScript fallback when the helper isn't enabled — see Architecture Notes)
- Sparkle for auto-updates; MonitorControl's MIT `IntelDDC` (vendored under `Services/Brightness/Vendor/`) for Intel external-display brightness; AskForPermission for permission onboarding. Bundled third-party license texts live in `THIRD-PARTY-LICENSES.md`.
- SPM build, with an in-repo build-tool plugin that compiles the `.xcstrings` string catalog

## Build and Run

```bash
# Build
swift build

# Run (dev mode; the process has no Bundle ID identity)
swift run AnyDoor

# Release build
swift build -c release

# Install as /Applications/AnyDoor.app (writes Info.plist, Bundle ID = dev.bybee.AnyDoor)
make install

# Uninstall
make uninstall

# Hot-reload development (requires watchexec)
make
```

Running requires the macOS Accessibility permission (System Settings → Privacy & Security → Accessibility).

The `.app` from `swift run` and the one from `make install` are **two distinct process identities** and must each be granted Accessibility separately. Use `make install` for production; use `swift run` for daily development. The SwiftData store path is pinned so both paths share the same data (see below).

Release tooling lives in the `Makefile`: `make sparkle-tools` (downloads the Sparkle CLI, pinned to 2.9.2), `make release <version>` / `make release-dryrun <version>` (drive `scripts/release.sh`, sourcing `.env`), and `make notary-profile` / `make notary-check` (notarization via `xcrun notarytool`, requires `APPLE_ID` / `APPLE_TEAM_ID` / `NOTARY_PROFILE` in `.env`). Release notes go under `## [Unreleased]` in `CHANGELOG.md` (do not hand-author a `## [x.y.z]` heading); `scripts/release.sh` rewrites that heading to `## [<version>] - <today>` on release. Its preflight (step 1) asserts: `[Unreleased]` is non-empty, `Info.plist` `SUPublicEDKey` is not a placeholder (run `scripts/sparkle-bin/generate_keys` first), a codesigning cert matching `SIGNING_IDENTITY` is in the login keychain, `sign_update` / `generate_appcast` are installed (`make sparkle-tools`), the `notarytool` keychain profile is configured, and `gh` is logged in.

## Project Structure

The codebase is large; the layout below is organized by subsystem (not a file-by-file listing). SPM targets: `AnyDoor` (main app), `HostsHelperShared` (shared XPC-contract library), `XPCAuditToken` (ObjC shim exposing the XPC peer audit token), `AnyDoorHostsHelper` (privileged helper executable), `AnyDoorTests`, and `XCStringsCompilerPlugin` (a `.buildTool()` plugin at `Plugins/XCStringsCompiler`, attached to `AnyDoor`, that compiles `.xcstrings` string catalogs via `xcrun xcstringstool` at build time — this is why localization works under plain `swift build` without Xcode).

```
Sources/AnyDoor/
├── AnyDoor.swift               # @main, Settings scene only (menu bar is managed by MenuBarController)
├── AppDelegate.swift           # ModelContainer, providers registry, service bootstrap, state-restoration opt-out
├── Models/                     # SwiftData @Model (exactly these 4 = the ModelContainer schema):
│                               #   KeyBinding / BuiltinPreference / ClipboardHistoryItem / HostProfile.
│                               #   Value types: BuiltinItem / PanelEntry (+ HotkeyDescriptor) /
│                               #   HotkeyAction (+ HotkeySnapshot) / HyperKey.swift (HyperKeyTrigger /
│                               #   HyperKeyQuickPress / HyperKeyVirtualKey) / PortRecord / MenuBarIcon /
│                               #   BackupSnapshot (Codable backup DTO, NOT a SwiftData @Model)
├── Services/
│   ├── Core         HotkeyService / PanelStore / AppSwitcher / MenuBarController /
│   │                SettingsOpener / RegularWindowCoordinator / LaunchAtLogin / LocalizationManager
│   ├── Seeding      BuiltinPreferenceSeeder / KeyBindingOrderBackfill (idempotent launch-time migrations)
│   ├── Runners      AppleScriptRunner / ShellRunner / CommandRunner / AutomationPermission
│   ├── Providers/   23 ToggleProvider/ActionProvider types (BuiltinProvider.swift holds the protocols);
│   │                most are their own actor (see Architecture Notes)
│   ├── Clipboard    ClipboardWatcher / ClipboardHistoryStore / ClipboardCapture / ClipboardPasteService /
│   │                ClipboardSearch / ClipboardPreferences / ColorSampler / TextRecognizer /
│   │                BarcodeRecognizer / RegionCapture
│   ├── Hosts/       HostsManager / HostsFile (parse+compose) / HostsWriter (protocol + AppleScriptWriter
│   │                fallback) / PrivilegedHelperWriter / HelperManager (XPC helper install) /
│   │                HostsBackupStore / MockHostsWriter
│   ├── Brightness/  DisplayBrightnessService + BrightnessController (actor, VCP 0x10 serializer) +
│   │                DDCBackend (Arm64 / Intel) + OSDBridge
│   ├── Calculator/  Inline calculator for the command palette (Calculator entry point → CalcResult /
│   │                CalcTokenizer / CalcEvaluator / CalcFunctions / CalcToken)
│   ├── Hyper Key    HyperKeyService / HyperKeyController / QuickPressEmitter
│   ├── Cmd Palette  CommandPaletteService / InstalledAppsScanner / PortInventory / PortScanner
│   ├── Win Layout   WindowLayoutService
│   ├── Sync/Backup  BackupService / BackupCodec / SyncBackend (protocol + LocalFileBackend) / SyncSettingsRegistry
│   └── Updates      UpdateService / UpdaterAdapter (protocol; NullUpdaterAdapter fallback) /
│                    SparkleUpdaterBridge (defines SparkleUpdaterAdapter)
├── Utilities/                  # KeyCodeMap / AppIconCache / L10n / color & thumbnail helpers / SystemSound
└── Views/
    ├── Panel        MenuBarView / PanelRowView / HoverPopover / HotkeyRecorder / HotkeyLabel
    ├── Popovers     AppShortcuts / Brightness / WindowLayout / PortManager / HostsManager popovers
    ├── Clipboard    ClipboardWall* / ClipboardHistory* / ClipboardCardView
    ├── Cmd Palette  CommandPalettePicker / SpotlightAppPicker (+ WindowController)
    ├── Hosts/       HostsEditorView / PlainTextEditor / HelperApprovalBanner
    ├── Settings     SettingsView (TabView: Panel + General only) / PanelSettingsView /
    │                GeneralSettingsView (embeds SyncSettingsView as a section)
    └── Common       Toast* / UpdateBannerView / LiquidGlassCompatibility / ScreenshotPreviewWindow
```

## Architecture Notes

- **Shared ModelContainer**: created in `AppDelegate.init()` and handed to all SwiftUI views via `.modelContainer()`. Do not create multiple ModelContainer instances.
- **Pinned store path**: ModelContainer is explicitly configured with `url: ~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store` so `swift run` and the `.app` don't write to different locations due to Bundle ID differences. The schema registers exactly four `@Model` types — `KeyBinding`, `BuiltinPreference`, `ClipboardHistoryItem`, `HostProfile`. On launch `AppDelegate` performs a one-time migration from the legacy `default.store` and cleans it up (see `migrateLegacyStore`). **Keep this path when changing the ModelConfiguration**, otherwise user data appears "lost".
- **Launch-time SwiftData seeding/migration**: besides `migrateLegacyStore`, `AppDelegate.applicationDidFinishLaunching` runs idempotent `BuiltinPreferenceSeeder` (one `BuiltinPreference` row per `BuiltinItem`, appends newly added builtins at max order+1, uses versioned backfill flags) and `KeyBindingOrderBackfill` (assigns stride-100 `displayOrder` to legacy zero-order rows). New `@Model` fields **must carry inline defaults** so SwiftData lightweight migration can backfill existing rows (see `KeyBinding.isEnabled/isVisible/displayOrder`).
- **CGEvent callback concurrency safety**: the callback is a C-style free function, not on `@MainActor`. Data is passed safely via `HotkeySnapshot` (a Sendable value type carrying `HotkeyAction`) plus `nonisolated(unsafe)` storage.
- **CGEvent tap timeout & watchdog**: the system budgets the tap callback at ~1 second; exceeding it triggers `.tapDisabledByTimeout` and auto-disables the tap. Current defenses:
  - the callback only matches keys; real work is dispatched via `DispatchQueue.main.async`
  - on `tapDisabledBy*` the tap is re-enabled inline inside the callback
  - a 2-second watchdog checks `CGEvent.tapIsEnabled` and calls `restart()` (tears down and rebuilds the tap) if needed
  - **never do synchronous expensive work inside the callback** (I/O, SwiftData fetch, modal dialogs, etc.)
- **HotkeyService health & keyboard lock**: `HotkeyService` exposes `tapHealth` (`healthy` / `suspendedByRecorder` / `transientlyDown` / `failed`) so the UI can surface accessibility-revoked or tap-create failures; a hard failure is only reported after ≥2 consecutive restart attempts fail. `setKeyboardLocked(_:)` powers a keyboard-lock feature — while locked the callback swallows all unmatched key events, but registered hotkeys still fire so the same shortcut can unlock.
- **Modifier alignment**: both recording and detection use `CGEventFlags` bitmasks (`maskCommand | maskControl | maskAlternate | maskShift`); do not use `NSEvent.ModifierFlags`.
- **Suppress dispatch while recording**: when recording a hotkey, the recorder calls `HotkeyService.beginRecording(observer:)` / `endRecording()`. The tap stays **active** (so the Caps-Lock/F19 Hyper trigger is still observed) but bound-hotkey dispatch and Quick Press are suppressed while `recordingObserver` is set, so recording can't fire an existing binding. `suspend()` / `resume()` (which fully disable the tap, and which the watchdog honors via `isSuspended`) exist but are **not** used by the recorder.
- **Data-change notification**: binding add/remove flows through `PanelStore.addAppShortcut` / `deleteAppShortcut`, which internally `save()` SwiftData, `rebuild()` view state, and `rebuildHotkeySnapshots()` to refresh HotkeyService — views do not call `modelContext.save()` directly. (`AppDelegate.refreshBindings()` still exists as a hot-reload helper but currently has no callers.)
- **Toggle semantics**: `AppSwitcher.toggle` uses `app.isActive` (frontmost check) rather than `app.isHidden`. If the target is already frontmost it calls `app.hide()`; otherwise (not frontmost, or not running) it routes through `NSWorkspace.openApplication(at:)` (`activate(at:)`) — deliberately **not** `NSRunningApplication.activate()`, which macOS 14+ silently ignores when an `.accessory` app tries to activate while another regular app holds focus. Changing the condition changes the interaction semantics.
- **PanelStore is the single source of truth**: three data sources (the static `BuiltinItem` catalog + `BuiltinPreference` preferences + `KeyBinding` app shortcuts) are merged in `PanelStore.rebuild()`; views read `topLevelEntries`, `appShortcutChildren`, and `windowLayoutChildren` (window-layout child rows are partitioned out separately). **All writes must go through PanelStore's mutation methods** (`setBuiltinVisibility`, `setBuiltinHotkey`, `updateAppShortcut`, `reorderTopLevel`, `reorderAppShortcuts`, `reorderWindowChildren`, `addAppShortcut`, `deleteAppShortcut`), which save SwiftData, `rebuild()` view state, and call `rebuildHotkeySnapshots()` to push to HotkeyService — except `reorderAppShortcuts`, which only changes display order and intentionally skips the snapshot rebuild. `rebuildHotkeySnapshots()` also draws from a **fourth** hotkey source: the Command Palette hotkey (`CommandPaletteService.shared.hotkey`). PanelStore additionally owns the provider registry and the activation paths (`dispatch`, `toggle`, `run`, `setKeepAwakeDuration`) with per-item in-flight guards.
- **HotkeyAction dispatch**: HotkeyService's callback uses an injected `dispatcher` closure, bound in `AppDelegate.applicationDidFinishLaunching` to `PanelStore.shared.dispatch`. Do not reference PanelStore directly inside HotkeyService — keep HotkeyService decoupled from business logic.
- **Provider isolation**: most ToggleProvider / ActionProvider implementations are their own `actor` and `setState` / `run` runs serially on that actor; the UI/window-coupled ones (`ClipboardWallProvider`, `WindowLayoutProvider`) are `@MainActor final class` instead. There are 23 concrete provider types (`BuiltinProvider.swift` holds only the `ToggleProvider` / `ActionProvider` protocols). `PanelStore` is `@MainActor`, and cross-provider writes are scheduled on the MainActor via `Task { await … }`.
- **The menu bar is not MenuBarExtra**: the menu-bar item is owned by the AppKit `MenuBarController` (`NSStatusItem` + a floating `NSPanel`). SwiftUI `MenuBarExtra` with `isInserted: false` infinite-loops the scene graph on macOS 26, so `AnyDoor.swift` keeps only the `Settings` scene. When AppKit needs to open Settings it goes through `SettingsOpener` (an off-screen `NSHostingView` mounted at launch captures the `\.openSettings` closure).
- **Window state restoration must stay off**: this is a menu-bar utility — no window should appear on launch. `AppDelegate.application(_:shouldRestoreApplicationState:)` / `shouldSaveApplicationState` return `false` so macOS won't reopen the previous Settings window on login auto-launch; `RegularWindowRegistrar` additionally sets the Settings window `isRestorable = false` as a fallback for the per-window restoration path. **Any new window must be verified not to be restored.**
- **Dynamic activation policy**: normally `.accessory` (no Dock icon). `RegularWindowCoordinator` switches to `.regular` while a "real" window (Settings, the Hosts editor) is open — otherwise the window slips behind and can't be resurfaced — and reverts to `.accessory` once the last one closes.
- **AppDelegate lifecycle extras**: `applicationShouldTerminate` clears the Hyper Key mapping (racing a 500 ms timeout) before quitting; `applicationShouldHandleReopen` re-opens Settings when AnyDoor is relaunched with no visible window, so a hidden menu-bar icon can be re-enabled.
- **Privileged hosts writes**: when the XPC helper is enabled, `/etc/hosts` is written by `AnyDoorHostsHelper` (a privileged LaunchDaemon installed via `SMAppService.daemon`); `HostsManager` coordinates and `PrivilegedHelperWriter` talks over XPC. When the helper is **not** enabled (ad-hoc/dev builds, or before approval), the main app falls back to `AppleScriptWriter`, which copies a temp file over `/etc/hosts` via an administrator-authorized `do shell script`. `HostsManager.makeWriter` re-resolves the writer on every write from `HelperManager.readiness()`, so helper approval takes effect without a relaunch (`MockHostsWriter` is for tests). The helper validates every caller's code signature via the peer **audit token** (the `XPCAuditToken` ObjC shim, which redeclares the private `NSXPCConnection.auditToken`) — requiring Team ID `9VM4RM39R3` + identifier `dev.bybee.AnyDoor` — to close the PID-recycle TOCTOU window. The XPC contract (`@objc PrivilegedHelperProtocol` + `PrivilegedHelperConstants`, including a 1 MiB payload cap and a fixed-verb `shutDown` method used by Scheduled Shutdown) lives in the shared `HostsHelperShared` target, imported by both the app and the helper.
- **Brightness backend selected by architecture**: `DisplayBrightnessService` drives a `BrightnessController` (an `actor` that serializes DDC VCP 0x10 I/O and retries a failed write once); the `DDCBackend` is injected into that controller in `AppDelegate`, where `#if arch(arm64)` chooses `Arm64DDCBackend` else `IntelDDCBackend`. Brightness up/down are hidden hotkeys (`HotkeyAction.brightnessUp/Down`).
- **Hyper Key: two-phase + watchdog**: the trigger is remapped to virtual key **F19** (keyCode 80) via `hidutil` `UserKeyMapping`; HotkeyService then re-emits the Hyper modifier flags (Ctrl+Opt+Cmd, plus Shift when `includeShift` is on). Phase 1 — at launch `AppDelegate` unconditionally calls `HyperKeyController.reconcile()`, which **clears** any leftover owned mapping (crash recovery; the controller records the hidutil entries it owns in the `hyperKey.ownedSignatures` UserDefaults key so it never nukes third-party mappings). Phase 2 — `HyperKeyService.bootstrapAfterTap` runs once the tap is ready, re-applies the active trigger, uses a `mutationToken` to stop stale async work from overwriting newer state, and runs a 2-second watchdog following `HotkeyService.tapHealth`. The trigger/quickPress/includeShift config lives in **UserDefaults** (not SwiftData). Tapping the trigger alone fires a **Quick Press** action (none / Escape / original key) via `QuickPressEmitter`, whose synthesized CGEvents carry `kAnyDoorSynthesizedEventTag` on `eventSourceUserData` so the tap passes through its own emissions (the Caps-Lock "original" case toggles via IOKit `IOHIDSetModifierLockState`). The mapping is cleared on system power-off (`willPowerOffNotification`) and on termination (gated on `hasPersistedSignatures`).
- **Config sync / backup**: backup (Settings → General) serializes app shortcuts (`KeyBinding`), builtin preferences (`BuiltinPreference`), and whitelisted general settings (`SyncSettingsRegistry`) into a schema-versioned Codable `BackupSnapshot`. Clipboard history and machine-specific keys are excluded, `appPath` is never serialized (re-resolved from bundle ID on import), import merges per key (imported wins, local-only rows kept), and `reconcileAfterImport` re-reads settings into CommandPaletteService / LocalizationManager / HyperKeyService / ScheduledShutdownService and rebuilds hotkey snapshots so changes apply without relaunch. Storage sits behind a `SyncBackend` protocol (current backend: `LocalFileBackend`).
- **Scheduled Shutdown**: `ScheduledShutdownService` (`@MainActor`, like HyperKey/CommandPalette) owns a one-shot schedule — it persists the absolute target `Date` (`scheduledShutdown.fireDate`), re-arms on launch (cancelling a deadline missed while quit), re-validates on `NSWorkspace.didWakeNotification`, and shows a cancelable floating-`NSPanel` warning (`ShutdownWarningWindowController`) before firing. A thin `ScheduledShutdownProvider` (`ToggleProvider`) plugs into the panel/hotkey path; `PanelStore` mirrors its Keep Awake plumbing (`scheduledShutdownState`, `setScheduledShutdownDuration`, `onScheduledShutdownStateChange`). Execution goes through `ShutdownExecuting`: graceful via `AppleScriptRunner` (System Events, Automation permission), forced via the privileged helper. Config (`forced`/`warningLeadSeconds`/`defaultMinutes`) is portable via `SyncSettingsRegistry`; the live `fireDate` is machine-local.
- **Localization**: UI strings go through `LocalizationManager.shared` (system / Simplified Chinese / English), injected via `.environment`. New user-facing strings use `L10n` / `LocalizedText`; do not hardcode them. The `.xcstrings` catalog is compiled at build time by the `XCStringsCompilerPlugin` build-tool plugin.

## Related Skills

The following skills are installed and should be used proactively for relevant tasks:

- **macos-design-guidelines** — Apple HIG for Mac. Use when building macOS UI, menu bars, toolbars, window management, keyboard shortcuts.
- **axiom-swiftdata** — SwiftData patterns: @Model, @Query, @Relationship, ModelContext patterns, Swift 6 concurrency.
- **axiom-swiftui-26-ref** — iOS/macOS 26 SwiftUI features, the Liquid Glass design system, the @Animatable macro, etc.
- **swiftui-liquid-glass** — Liquid Glass API implementation and review.
- **axiom-swift-concurrency** — Swift concurrency patterns: @MainActor, Sendable, nonisolated(unsafe), Task, Actor, etc.
- **swift-expert** — Swift language expertise covering language features and best practices.
- **macos-developer** — macOS app development: CGEvent, NSWorkspace, Accessibility permission, and other low-level APIs.

## Notes

- The app uses the `.accessory` activation policy and shows no Dock icon.
- The event tap uses `.cghidEventTap` to ensure highest priority.
- `displayKey` is a `@Transient` computed property on `KeyBinding` and is not persisted.
- The interface language is Chinese.

## Code Conventions

- **All content in CLAUDE.md (and other repo-committed documentation) must be written in English.**
- **All code comments must be written in English.**
- **All commit messages must be written in English.**
- **All PR titles and descriptions must be written in English.**
- UI-facing strings (labels, messages shown to the user) remain in Chinese.
