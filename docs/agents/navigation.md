# Code Navigation

Use this map to choose a small set of source files before searching a whole subsystem.
The source paths below reflect the actual checkout: most Core services and views are flat under
`Sources/AnyDoor/Services/` and `Sources/AnyDoor/Views/`, while extracted modules own separate targets.
The [documentation index](../README.md) identifies current contracts and historical material.

## Package boundaries

[Package.swift](../../Package.swift) is the authority for targets, dependencies, resources, and compiler
settings. This table supplies entry paths rather than duplicating dependency versions.

| Target | Entry path and role |
| --- | --- |
| `AnyDoor` | [AppDelegate.swift](../../Sources/AnyDoor/AppDelegate.swift), host composition and startup |
| `ClipboardHistory` | [ClipboardHistoryModule.swift](../../Sources/ClipboardHistory/ClipboardHistoryModule.swift), the encrypted history module's public boundary |
| `PluginInterface` | [NativePlugin.swift](../../Sources/PluginInterface/NativePlugin.swift), [PluginHostServices.swift](../../Sources/PluginInterface/PluginHostServices.swift), shared contracts |
| `PluginSupport` | [Sources/PluginSupport/](../../Sources/PluginSupport/), shared implementations and UI helpers |
| `ImageCodec` | [Sources/ImageCodec/](../../Sources/ImageCodec/), shared encoding utilities |
| `ImageConversionPlugin` | [Sources/ImageConversionPlugin/](../../Sources/ImageConversionPlugin/), feature implementation |
| `HostsPlugin` | [Sources/HostsPlugin/](../../Sources/HostsPlugin/), profiles, editor, and feature implementation |
| `ScriptPluginRuntime` | [ScriptPluginRuntime.swift](../../Sources/ScriptPluginRuntime/ScriptPluginRuntime.swift), headless JavaScriptCore execution |
| `JavaScriptCoreWatchdog` | [Sources/JavaScriptCoreWatchdog/](../../Sources/JavaScriptCoreWatchdog/), execution-time-limit C shim |
| `HostsHelperShared` | [Sources/HostsHelperShared/](../../Sources/HostsHelperShared/), XPC contract |
| `XPCAuditToken` | [Sources/XPCAuditToken/](../../Sources/XPCAuditToken/), peer audit-token shim |
| `AnyDoorHostsHelper` | [Sources/AnyDoorHostsHelper/](../../Sources/AnyDoorHostsHelper/), privileged helper executable |
| `AnyDoorTests` | [Tests/AnyDoorTests/](../../Tests/AnyDoorTests/), host, plugin, UI-policy, and integration tests |
| `ClipboardHistoryTests` | [Tests/ClipboardHistoryTests/](../../Tests/ClipboardHistoryTests/), history module behavior and release acceptance |
| `ClipboardHistoryTestSupport` | [ClipboardHistoryTestSupport.swift](../../Tests/ClipboardHistoryTestSupport/ClipboardHistoryTestSupport.swift), test-only shared fixture cleanup used by both test targets |
| `XCStringsCompilerPlugin` | [Plugins/XCStringsCompiler/](../../Plugins/XCStringsCompiler/), string-catalog build plugin |

The standalone [tooling workspace](../../tooling/README.md) owns Script Plugin authoring packages and
examples. It is outside SwiftPM; a Swift-only build does not validate its TypeScript contract fixtures.

## Clipboard history

The module and the host have different ownership. Start with the layer matching the symptom.

| Change or symptom | Source route | Relevant tests and reference |
| --- | --- | --- |
| Capture, monitoring, search, retention, payloads, or encrypted storage | [ClipboardHistoryModule](../../Sources/ClipboardHistory/ClipboardHistoryModule.swift) → [module files](../../Sources/ClipboardHistory/) | [ClipboardHistoryTests](../../Tests/ClipboardHistoryTests/), [current PRD](../prds/2026-07-29-clipboard-history-v2.md) |
| Startup, Keychain recovery, migration admission, or Settings state | [AppPersistenceBootstrap](../../Sources/AnyDoor/Services/AppPersistenceBootstrap.swift) → [ClipboardHistoryLifecycle](../../Sources/AnyDoor/Services/ClipboardHistoryLifecycle.swift) | [bootstrap tests](../../Tests/AnyDoorTests/AppPersistenceBootstrapTests.swift), [lifecycle tests](../../Tests/AnyDoorTests/ClipboardHistoryLifecycleTests.swift), [persistence invariants](architecture.md#persistence-and-clipboard-history) |
| Store relocation or pre-v2 migration | [ClipboardHistoryStoreRelocation](../../Sources/ClipboardHistory/ClipboardHistoryStoreRelocation.swift), [legacy source](../../Sources/AnyDoor/Services/ClipboardHistoryLegacySource.swift), [legacy adapter](../../Sources/AnyDoor/Services/ClipboardHistoryLegacyAdapter.swift), [plain SQLite reader](../../Sources/ClipboardHistory/ClipboardHistoryLegacyStoreReader.swift) | [relocation tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryStoreRelocationTests.swift), [reader tests](../../Tests/AnyDoorTests/ClipboardHistoryLegacyStoreReaderTests.swift), [ADR-0011](../adr/0011-isolate-clipboard-history-storage.md) |
| Wall/popover loading, pagination, selection, or live refresh | [ClipboardHistoryPresentationModel](../../Sources/AnyDoor/Services/ClipboardHistoryPresentationModel.swift) → [Core views](../../Sources/AnyDoor/Views/) | [presentation tests](../../Tests/AnyDoorTests/ClipboardHistoryPresentationModelTests.swift), [native acceptance plan](../testing/clipboard-history-v2-manual-test-plan.md) |
| Copy/paste, explicit captures, or self-write suppression | [ClipboardHistoryPasteService](../../Sources/AnyDoor/Services/ClipboardHistoryPasteService.swift), [ClipboardSelfWrites](../../Sources/AnyDoor/Services/ClipboardSelfWrites.swift), [self-write funnel](../../Sources/ClipboardHistory/ClipboardHistoryPasteboardSelfWriteFunnel.swift) | [paste-service tests](../../Tests/AnyDoorTests/ClipboardHistoryPasteServiceTests.swift), [production-adapter tests](../../Tests/AnyDoorTests/ClipboardProductionAdapterTests.swift), [Keychain integration](../testing/clipboard-history-keychain-integration.md) |

`ClipboardHistoryItem` is a frozen legacy **test fixture**, not a live SwiftData model. Locate it in
[LegacyClipboardHistorySchemaFixture.swift](../../Tests/AnyDoorTests/LegacyClipboardHistorySchemaFixture.swift).
Read the current storage decision before using a path from a historical plan.

## Panel, hotkeys, and palette

| Task | Source route | Relevant tests |
| --- | --- | --- |
| Panel entries, binding writes, provider ownership, command failure notices | [PanelStore](../../Sources/AnyDoor/Services/PanelStore.swift), [BuiltinProviderRegistry](../../Sources/AnyDoor/Services/Providers/BuiltinProviderRegistry.swift), [CommandFailure](../../Sources/AnyDoor/Services/CommandFailure.swift) | [PanelStoreTests](../../Tests/AnyDoorTests/PanelStoreTests.swift), [BuiltinCatalogInvariantTests](../../Tests/AnyDoorTests/BuiltinCatalogInvariantTests.swift), [CommandFailureNoticeTests](../../Tests/AnyDoorTests/CommandFailureNoticeTests.swift) |
| Recorded hotkeys or dispatch | [HotkeyCoordinator](../../Sources/AnyDoor/Services/HotkeyCoordinator.swift) → [HotkeyService](../../Sources/AnyDoor/Services/HotkeyService.swift) | [HotkeyCoordinatorTests](../../Tests/AnyDoorTests/HotkeyCoordinatorTests.swift), [hotkey invariants](architecture.md#hotkeys-and-panel) |
| Hyper Key mappings or Quick Press | [HyperKeyService](../../Sources/AnyDoor/Services/HyperKeyService.swift), [HyperKeyController](../../Sources/AnyDoor/Services/HyperKeyController.swift) | [service tests](../../Tests/AnyDoorTests/HyperKeyServiceTests.swift), [controller tests](../../Tests/AnyDoorTests/HyperKeyControllerTests.swift) |
| Palette drill-in, resume, commit, or search-field placement | [CommandPaletteState](../../Sources/AnyDoor/Views/CommandPaletteState.swift), [window controller](../../Sources/AnyDoor/Views/CommandPaletteWindowController.swift), [commit classifier](../../Sources/AnyDoor/Services/CommandPaletteCommit.swift) | [commit-intent tests](../../Tests/AnyDoorTests/CommandPaletteCommitIntentTests.swift), [palette invariants](architecture.md#command-palette) |
| Palette options or generic extension registration | [CommandPaletteOptions](../../Sources/AnyDoor/Services/CommandPaletteOptions.swift), [CommandPaletteExtensions](../../Sources/AnyDoor/Services/CommandPaletteExtensions.swift) | [options tests](../../Tests/AnyDoorTests/CommandPaletteOptionsTests.swift), [Native Plugin playbook](native-plugins.md) |
| Quicklinks, keywords, templates, and hotkeys | [QuicklinkStore](../../Sources/AnyDoor/Services/Quicklinks/QuicklinkStore.swift), [QuicklinksSettingsView](../../Sources/AnyDoor/Views/QuicklinksSettingsView.swift) | [QuicklinkTests](../../Tests/AnyDoorTests/QuicklinkTests.swift), [Quicklinks PRD](../prds/2026-07-09-quicklinks.md) |

## Plugins

For Native Plugins, start with the [playbook](native-plugins.md), then trace
[NativePluginCatalog](../../Sources/AnyDoor/Services/Plugins/NativePluginCatalog.swift) →
[PluginRegistry](../../Sources/AnyDoor/Services/Plugins/PluginRegistry.swift) → the plugin's instance.
Host capabilities are implemented by [CorePluginHost](../../Sources/AnyDoor/Services/Plugins/CorePluginHost.swift);
shared helpers belong to `PluginSupport`. Tests include
[catalog tests](../../Tests/AnyDoorTests/NativePluginCatalogTests.swift) and
[registry tests](../../Tests/AnyDoorTests/PluginRegistryTests.swift).

For Script Plugins, trace [ScriptPluginRegistry](../../Sources/AnyDoor/Services/Plugins/ScriptPluginRegistry.swift)
→ [ScriptPluginRowSource](../../Sources/AnyDoor/Services/Plugins/ScriptPluginRowSource.swift) →
[ScriptPluginRuntime](../../Sources/ScriptPluginRuntime/ScriptPluginRuntime.swift).
Read [runtime and capability invariants](architecture.md#script-plugins) before changing queue
isolation, watchdogs, package validation, or declared capabilities. Use
[runtime tests](../../Tests/AnyDoorTests/ScriptPluginRuntimeTests.swift),
[registry tests](../../Tests/AnyDoorTests/ScriptPluginRegistryTests.swift), and the
[author toolchain](../../tooling/README.md). Changes to the Swift/TypeScript surface also reach
[contract fixture tests](../../Tests/AnyDoorTests/ScriptContractFixtureTests.swift) and
[tooling-template tests](../../Tests/AnyDoorTests/ScriptPluginToolingTemplateTests.swift).

## Other subsystems

| Task | Source route | Reference or verification |
| --- | --- | --- |
| Launch, Settings, menu bar, or window activation | [AnyDoor.swift](../../Sources/AnyDoor/AnyDoor.swift), [AppDelegate](../../Sources/AnyDoor/AppDelegate.swift), [MenuBarController](../../Sources/AnyDoor/Services/MenuBarController.swift), [SettingsWindowController](../../Sources/AnyDoor/Views/SettingsWindowController.swift) | [window invariants](architecture.md#windows-and-localization), [Settings tests](../../Tests/AnyDoorTests/SettingsWindowControllerTests.swift), [testing index](../testing/README.md) |
| Screenshot, scrolling capture, or annotation | [CaptureCoordinator](../../Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift), [ScrollCaptureCoordinator](../../Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift), [AnnotationRenderer](../../Sources/AnyDoor/Services/Annotation/AnnotationRenderer.swift) | [capture backend constraints](architecture.md#capture-and-recording), [capture Save As tests](../../Tests/AnyDoorTests/CaptureSaveAsTests.swift), [stitch tests](../../Tests/AnyDoorTests/ScrollCaptureEngineTests.swift), [pinned-image manual plan](../testing/pinned-image-manual-test-plan.md) |
| Screen recording | [RecordingCoordinator](../../Sources/AnyDoor/Services/Recording/RecordingCoordinator.swift), [ScreenRecordingEngine](../../Sources/AnyDoor/Services/Recording/ScreenRecordingEngine.swift) | [recording backend and audio scope](architecture.md#capture-and-recording), [testing index](../testing/README.md) |
| Translation providers, scheduling, or credentials | [TranslationCoordinator](../../Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift), [provider factory](../../Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift), [TranslationKeychainStore](../../Sources/AnyDoor/Services/Translation/TranslationKeychainStore.swift) | [coordinator tests](../../Tests/AnyDoorTests/TranslationCoordinatorTests.swift), [Keychain tests](../../Tests/AnyDoorTests/TranslationKeychainStoreTests.swift), [development](../development.md) |
| Manual backup or automatic Config Sync | [BackupService](../../Sources/AnyDoor/Services/BackupService.swift), [SyncSettingsRegistry](../../Sources/AnyDoor/Services/SyncSettingsRegistry.swift), [SyncCoordinator](../../Sources/AnyDoor/Services/Sync/SyncCoordinator.swift) | [Config Sync guide](../config-sync.md), [backup/sync invariants](architecture.md#backup-and-sync), [backup tests](../../Tests/AnyDoorTests/BackupServiceTests.swift), [sync tests](../../Tests/AnyDoorTests/SyncCoordinatorTests.swift) |
| Hosts privileged helper, brightness, or Clear Notifications | [HelperManager](../../Sources/AnyDoor/Services/Hosts/HelperManager.swift), [BrightnessController](../../Sources/AnyDoor/Services/Brightness/BrightnessController.swift), [SystemNotificationDismisser](../../Sources/AnyDoor/Services/SystemNotifications/SystemNotificationDismisser.swift) | [system-service invariants](architecture.md#system-services), [CI lanes](../../.github/workflows/ci.yml) |
| Localized UI copy | [LocalizationManager](../../Sources/AnyDoor/Services/LocalizationManager.swift), [catalog](../../Sources/AnyDoor/Resources/Localizable.xcstrings), [compiler plugin](../../Plugins/XCStringsCompiler/) | [LocalizationCoverageTests](../../Tests/AnyDoorTests/LocalizationCoverageTests.swift), [localization invariants](architecture.md#windows-and-localization) |
| Release, landing, or update feed | [Makefile](../../Makefile), [release driver](../../scripts/release-driver.sh), [landing source](../../landing/src/), [feed Worker](../../feed/src/index.js) | [deployment](../deployment.md), [Beta Updates](../beta-updates.md), [development](../development.md) |

## Tracing a behavior

Start from the view or public entry point, follow the owning service and its injected dependencies,
then inspect the tests next to that boundary. Distinguish the Core host from an extracted module before
adding a dependency or singleton. For a documentation mismatch, consult the current contract and source
before reading old task plans. Use `scripts/search.py PATTERN` for focused current-tree searches;
the [search scope](../README.md#search) explains which documents and sections require `--history`.
