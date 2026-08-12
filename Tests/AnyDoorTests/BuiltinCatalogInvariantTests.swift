import CoreGraphics
import Foundation
import SwiftData
import Testing
import PluginInterface
import ImageConversionPlugin
@testable import AnyDoor
@testable import ClipboardHistory
@testable import HostsPlugin

/// Pins the implicit contracts a new `BuiltinItem` case must satisfy. Each of
/// these used to be convention-only, with a silent failure mode:
/// - a toggle/action item without a registered provider renders a panel row
///   and binds a hotkey that do nothing (`PanelStore.toggle/run` guard-return);
/// - a duplicate `defaultOrder` makes first-launch seeding order ambiguous;
/// - a window-layout child missing from `PanelStore.windowLayoutChildKeys`
///   leaks into the top-level panel instead of the window-layout popover;
/// - a new hiddenHotkey case not mapped in `HotkeyCoordinator.compile` accepts
///   a recorded hotkey that never fires.
struct BuiltinCatalogInvariantTests {

    /// The real production plugins, built against an in-memory container so
    /// their providers participate in the catalog invariants exactly as they
    /// do in the app. The Hosts plugin takes an injected manager wired to
    /// the sanctioned writer double so the invariants never touch the system.
    @MainActor
    static func makeProductionPlugins() throws -> [any NativePlugin] {
        let container = try ModelContainer(
            for: Schema(
                ImageConversionNativePlugin.modelSchemaTypes
                    + HostsNativePlugin.modelSchemaTypes
            ),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let host = CorePluginHost(modelContainer: container)
        let live = { "127.0.0.1 localhost\n" }
        let hostsManager = HostsManager(
            writer: MockHostsWriter(),
            backup: HostsBackupStore(
                backupDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                readLiveHosts: live
            ),
            readLiveHosts: live
        )
        return [
            ImageConversionNativePlugin(host: host),
            HostsNativePlugin(host: host, manager: hostsManager),
        ]
    }

    /// The full production provider set: Core providers plus every plugin's.
    @MainActor
    private static func allProviders() throws -> [any BuiltinProvider] {
        try BuiltinProviderRegistry.makeAll(
            clipboardHistoryModule: makeClipboardHistoryModule(),
            onKeepAwakeChange: { _ in }
        )
            + makeProductionPlugins().flatMap(\.providers)
    }

    private static func makeClipboardHistoryModule() throws
        -> ClipboardHistoryModule
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try ClipboardHistoryModule(
            testingDatabaseURL:
                directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)
        )
    }

    @MainActor
    private static func providersByItem() throws -> [BuiltinItem: any BuiltinProvider] {
        var byItem: [BuiltinItem: any BuiltinProvider] = [:]
        for provider in try allProviders() {
            byItem[provider.itemKey] = provider
        }
        return byItem
    }

    @Test @MainActor func providerItemKeysAreUnique() throws {
        let keys = try Self.allProviders().map(\.itemKey)
        #expect(keys.count == Set(keys).count, "duplicate provider registrations for the same BuiltinItem")
    }

    @Test @MainActor func everyToggleItemHasAToggleProvider() throws {
        let byItem = try Self.providersByItem()
        for item in BuiltinItem.allCases where item.kind == .toggle {
            #expect(byItem[item] is any ToggleProvider,
                    "\(item) is toggle-kind but has no ToggleProvider registered")
        }
    }

    @Test @MainActor func everyActionItemHasAnActionProvider() throws {
        let byItem = try Self.providersByItem()
        for item in BuiltinItem.allCases where item.kind == .action {
            #expect(byItem[item] is any ActionProvider,
                    "\(item) is action-kind but has no ActionProvider registered")
        }
    }

    @Test @MainActor func nonActionableKindsHaveNoProvider() throws {
        // Submenus open popovers, brightnessControl has its own service, and
        // hiddenHotkey items dispatch directly — a provider registered for one
        // of these would be dead code the panel never invokes.
        let byItem = try Self.providersByItem()
        for item in BuiltinItem.allCases
        where item.kind == .submenu || item.kind == .brightnessControl || item.kind == .hiddenHotkey {
            #expect(byItem[item] == nil, "\(item) (\(item.kind)) should not have a provider")
        }
    }

    @Test @MainActor func everyCommandIsClaimedByExactlyOneOwner() throws {
        // A Claim is exclusive (ADR-0006): each catalog case is owned by at
        // most one Native Plugin; every unclaimed case belongs to the Core.
        let plugins = try Self.makeProductionPlugins()
        var owners: [BuiltinItem: NativePluginID] = [:]
        for plugin in plugins {
            for command in plugin.claimedCommands {
                #expect(owners[command] == nil,
                        "\(command) is claimed by both \(owners[command]?.rawValue ?? "?") and \(plugin.id.rawValue)")
                owners[command] = plugin.id
            }
        }

        // The registry derives availability from the same claims; pin the
        // wiring: an uninstalled plugin's claims are exactly the commands the
        // fresh registry reports unavailable.
        let suiteName = "BuiltinCatalogInvariantTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: plugins, modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        let unavailable = Set(BuiltinItem.allCases).subtracting(registry.availableCommands)
        #expect(unavailable == Set(owners.keys))
        for command in BuiltinItem.allCases {
            #expect(registry.claimOwner(of: command) == owners[command])
        }
    }

    @Test @MainActor func pluginsProvideOnlyForTheirClaimedActionableCommands() throws {
        // A plugin's providers must cover exactly its actionable claims —
        // a provider for an unclaimed command would smuggle a surface past
        // the install gate.
        for plugin in try Self.makeProductionPlugins() {
            let provided = Set(plugin.providers.map(\.itemKey))
            let actionableClaims = plugin.claimedCommands.filter {
                $0.kind == .toggle || $0.kind == .action
            }
            #expect(provided == actionableClaims,
                    "\(plugin.id.rawValue) providers \(provided) != actionable claims \(actionableClaims)")
        }
    }

    @Test func defaultOrderIsUniqueAcrossCatalog() {
        let orders = BuiltinItem.allCases.map(\.defaultOrder)
        #expect(orders.count == Set(orders).count,
                "duplicate defaultOrder values make first-launch seeding order ambiguous")
    }

    @Test @MainActor func windowLayoutChildKeysMatchWindowActionCases() {
        // Every window-prefixed case except the .windowLayout submenu parent is
        // a popover child; a new window action added to the enum but not to
        // this set would leak into the top-level panel.
        let expected = Set(BuiltinItem.allCases.filter {
            $0.rawValue.hasPrefix("window") && $0 != .windowLayout
        })
        #expect(PanelStore.windowLayoutChildKeys == expected)
        for item in PanelStore.windowLayoutChildKeys {
            #expect(item.kind == .action, "\(item) is a window-layout child but not action-kind")
        }
    }

    @Test @MainActor func everyHiddenHotkeyItemCompilesToASnapshot() {
        for item in BuiltinItem.allCases where item.kind == .hiddenHotkey {
            let pref = BuiltinPreference(itemKey: item.rawValue, keyCode: 1,
                                         modifierFlags: Int(CGEventFlags.maskCommand.rawValue))
            let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], quicklinks: [], paletteHotkey: nil)
            #expect(snapshots.count == 1,
                    "\(item) is hiddenHotkey-kind but HotkeyCoordinator.compile drops its binding")
        }
    }
}
