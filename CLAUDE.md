# AnyDoor

A macOS menu-bar toolbox. At its core it toggles (show/hide) a target application via a global hotkey, and builds a set of system-level quick actions on top of that: clipboard history, hosts management, external display brightness, Hyper Key, window layout, command palette, and more.

## Tech Stack

- Swift 6.2, strict concurrency mode (`.swiftLanguageMode(.v6)`)
- macOS 14+
- Liquid Glass on macOS 26+; earlier supported systems fall back to a plain material background.
- SwiftUI `Settings` scene + AppKit `MenuBarController` (the menu-bar item is managed directly by `NSStatusItem`, **not** `MenuBarExtra` — see below)
- SwiftData persistence
- CGEvent tap for global hotkey monitoring
- Privileged XPC helper (`AnyDoorHostsHelper`) writes `/etc/hosts`
- Sparkle for auto-updates; DDC.swift for external display brightness; AskForPermission for permission onboarding
- SPM build

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

## Project Structure

The codebase is large; the layout below is organized by subsystem (not a file-by-file listing). SPM targets: `AnyDoor` (main app), `HostsHelperShared` (shared library), `XPCAuditToken`, `AnyDoorHostsHelper` (privileged helper executable), `AnyDoorTests`.

```
Sources/AnyDoor/
├── AnyDoor.swift               # @main, Settings scene only (menu bar is managed by MenuBarController)
├── AppDelegate.swift           # ModelContainer, providers registry, service bootstrap, state-restoration opt-out
├── Models/                     # SwiftData: KeyBinding / BuiltinPreference / ClipboardHistoryItem /
│                               #   HostProfile / BackupSnapshot; value types: BuiltinItem / PanelEntry /
│                               #   HotkeyAction / HyperKey / PortRecord / MenuBarIcon
├── Services/
│   ├── Core         HotkeyService / PanelStore / AppSwitcher / MenuBarController /
│   │                SettingsOpener / RegularWindowCoordinator / LaunchAtLogin / LocalizationManager
│   ├── Runners      AppleScriptRunner / ShellRunner / CommandRunner / AutomationPermission
│   ├── Providers/   23+ ToggleProvider/ActionProvider, each its own actor (see Architecture Notes)
│   ├── Clipboard    ClipboardWatcher / ClipboardHistoryStore / ClipboardCapture / ClipboardPaste /
│   │                ClipboardSearch / ColorSampler / TextRecognizer / BarcodeRecognizer / RegionCapture
│   ├── Hosts/       HostsManager / HostsWriter / PrivilegedHelperWriter / HelperManager (XPC helper install)
│   ├── Brightness/  DisplayBrightnessService + DDCBackend (Arm64 / Intel) + OSDBridge
│   ├── Calculator/  Inline calculator for the command palette (tokenizer / evaluator / functions)
│   ├── Hyper Key    HyperKeyService / HyperKeyController / QuickPressEmitter
│   ├── Cmd Palette  CommandPaletteService / InstalledAppsScanner / PortInventory / PortScanner
│   ├── Win Layout   WindowLayoutService
│   ├── Sync/Backup  BackupService / BackupCodec / SyncBackend / SyncSettingsRegistry
│   └── Updates      UpdateService / SparkleUpdaterBridge / UpdaterAdapter
├── Utilities/                  # KeyCodeMap / AppIconCache / L10n / color & thumbnail helpers / SystemSound
└── Views/
    ├── Panel        MenuBarView / PanelRowView / HoverPopover / HotkeyRecorder / HotkeyLabel
    ├── Popovers     AppShortcuts / Brightness / WindowLayout / PortManager / HostsManager popovers
    ├── Clipboard    ClipboardWall* / ClipboardHistory* / ClipboardCardView
    ├── Cmd Palette  CommandPalettePicker / SpotlightAppPicker (+ WindowController)
    ├── Hosts/       HostsEditorView / PlainTextEditor / HelperApprovalBanner
    ├── Settings     SettingsView(TabView) / PanelSettingsView / GeneralSettingsView / SyncSettingsView
    └── Common       Toast* / UpdateBannerView / LiquidGlassCompatibility / ScreenshotPreviewWindow
```

## Architecture Notes

- **Shared ModelContainer**: created in `AppDelegate.init()` and handed to all SwiftUI views via `.modelContainer()`. Do not create multiple ModelContainer instances.
- **Pinned store path**: ModelContainer is explicitly configured with `url: ~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store` so `swift run` and the `.app` don't write to different locations due to Bundle ID differences. On launch `AppDelegate` performs a one-time migration from the legacy `default.store` and cleans it up (see `migrateLegacyStore`). **Keep this path when changing the ModelConfiguration**, otherwise user data appears "lost".
- **CGEvent callback concurrency safety**: the callback is a C-style free function, not on `@MainActor`. Data is passed safely via `HotkeySnapshot` (a Sendable value type carrying `HotkeyAction`) plus `nonisolated(unsafe)` storage.
- **CGEvent tap timeout & watchdog**: the system budgets the tap callback at ~1 second; exceeding it triggers `.tapDisabledByTimeout` and auto-disables the tap. Current defenses:
  - the callback only matches keys; real work is dispatched via `DispatchQueue.main.async`
  - on `tapDisabledBy*` the tap is re-enabled inline inside the callback
  - a 2-second watchdog checks `CGEvent.tapIsEnabled` and calls `restart()` (tears down and rebuilds the tap) if needed
  - **never do synchronous expensive work inside the callback** (I/O, SwiftData fetch, modal dialogs, etc.)
- **Modifier alignment**: both recording and detection use `CGEventFlags` bitmasks (`maskCommand | maskControl | maskAlternate | maskShift`); do not use `NSEvent.ModifierFlags`.
- **Suspend monitoring while recording**: when recording a hotkey, call `HotkeyService.suspend()` and `resume()` afterward to avoid the recording triggering an existing binding. The watchdog skips auto-restart while `isSuspended`.
- **Data-change notification**: after adding/removing bindings, explicitly call `modelContext.save()` and `AppDelegate.refreshBindings()` to refresh HotkeyService.
- **Toggle semantics**: `AppSwitcher.toggle` uses `app.isActive` (frontmost check) rather than `app.isHidden`. If the target is already frontmost it calls `hide()`, otherwise `activate()`; if not running, `openApplication`. Changing the condition changes the interaction semantics.
- **PanelStore is the single source of truth**: three data sources (the static `BuiltinItem` catalog + `BuiltinPreference` preferences + `KeyBinding` app shortcuts) are merged in `PanelStore`; views only read `topLevelEntries` and `appShortcutChildren`. **All writes must go through PanelStore's mutation methods** (`setBuiltinVisibility`, `setBuiltinHotkey`, `reorderTopLevel`, etc.), which automatically save SwiftData, rebuild view state, and call `rebuildHotkeySnapshots()` to push to HotkeyService.
- **HotkeyAction dispatch**: HotkeyService's callback uses an injected `dispatcher` closure, bound in `AppDelegate.applicationDidFinishLaunching` to `PanelStore.shared.dispatch`. Do not reference PanelStore directly inside HotkeyService — keep HotkeyService decoupled from business logic.
- **Provider isolation**: each ToggleProvider / ActionProvider is its own actor and `setState` runs serially on that actor; `PanelStore` is `@MainActor`, and cross-provider writes are scheduled on the MainActor via `Task { await … }`.
- **The menu bar is not MenuBarExtra**: the menu-bar item is owned by the AppKit `MenuBarController` (`NSStatusItem` + a floating `NSPanel`). SwiftUI `MenuBarExtra` with `isInserted: false` infinite-loops the scene graph on macOS 26, so `AnyDoor.swift` keeps only the `Settings` scene. When AppKit needs to open Settings it goes through `SettingsOpener` (an off-screen `NSHostingView` mounted at launch captures the `\.openSettings` closure).
- **Window state restoration must stay off**: this is a menu-bar utility — no window should appear on launch. `AppDelegate.application(_:shouldRestoreApplicationState:)` / `shouldSaveApplicationState` return `false` so macOS won't reopen the previous Settings window on login auto-launch; `RegularWindowRegistrar` additionally sets the Settings window `isRestorable = false` as a fallback for the per-window restoration path. **Any new window must be verified not to be restored.**
- **Dynamic activation policy**: normally `.accessory` (no Dock icon). `RegularWindowCoordinator` switches to `.regular` while a "real" window (Settings, the Hosts editor) is open — otherwise the window slips behind and can't be resurfaced — and reverts to `.accessory` once the last one closes.
- **Privileged hosts writes**: `/etc/hosts` is written by `AnyDoorHostsHelper` (a privileged XPC helper installed via `SMAppService`); the main app never touches the system file directly. `HostsManager` coordinates and `PrivilegedHelperWriter` talks over XPC (`MockHostsWriter` is for tests).
- **Brightness backend selected by architecture**: `DisplayBrightnessService` injects a `DDCBackend`; `#if arch(arm64)` uses `Arm64DDCBackend`, otherwise `IntelDDCBackend`. Brightness up/down are hidden hotkeys (`HotkeyAction.brightnessUp/Down`).
- **Hyper Key: two-phase + watchdog**: `HyperKeyController` persists the mapping and reconciles unconditionally at launch; `HyperKeyService` runs `bootstrapAfterTap` once the tap is ready, uses a mutationToken to prevent stale async work from overwriting newer state, and runs a 2-second watchdog following HotkeyService health. The mapping is cleared on system power-off (`willPowerOffNotification`) and on termination.
- **Localization**: UI strings go through `LocalizationManager.shared` (system / Simplified Chinese / English), injected via `.environment`. New user-facing strings use `L10n` / `LocalizedText`; do not hardcode them.

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
- `displayKey` is a `@Transient` computed property and is not persisted.
- The interface language is Chinese.

## Code Conventions

- **All content in CLAUDE.md (and other repo-committed documentation) must be written in English.**
- **All code comments must be written in English.**
- **All commit messages must be written in English.**
- **All PR titles and descriptions must be written in English.**
- UI-facing strings (labels, messages shown to the user) remain in Chinese.
