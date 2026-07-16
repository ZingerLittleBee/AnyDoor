import CoreGraphics
import SwiftData
import Testing
import PluginInterface
import ImageConversionPlugin
@testable import AnyDoor

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
    /// do in the app.
    @MainActor
    static func makeProductionPlugins() throws -> [any NativePlugin] {
        let container = try ModelContainer(
            for: Schema(ImageConversionNativePlugin.modelSchemaTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return [ImageConversionNativePlugin(host: CorePluginHost(modelContainer: container))]
    }

    /// The full production provider set: Core providers plus every plugin's.
    @MainActor
    private static func allProviders() throws -> [any BuiltinProvider] {
        try BuiltinProviderRegistry.makeAll(onKeepAwakeChange: { _ in })
            + makeProductionPlugins().flatMap(\.providers)
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
