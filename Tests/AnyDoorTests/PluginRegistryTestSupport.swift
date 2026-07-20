import Foundation
import PluginInterface
import SwiftData
@testable import AnyDoor

@MainActor
final class HotkeySnapshotRecorder {
    private(set) var snapshots: [HotkeySnapshot] = []
    private(set) var updateCount = 0

    func record(_ snapshots: [HotkeySnapshot]) {
        self.snapshots = snapshots
        updateCount += 1
    }
}

@MainActor
struct PluginRegistryTestHarness {
    let registry: PluginRegistry
    let panelStore: PanelStore
    let paletteExtensions: CommandPaletteExtensions
    let snapshotRecorder: HotkeySnapshotRecorder
}

@MainActor
func makePluginRegistryTestContainer(
    pluginModelTypes: [any PersistentModel.Type] = []
) throws -> ModelContainer {
    try ModelContainer(
        for: Schema(
            [KeyBinding.self, BuiltinPreference.self, Quicklink.self]
                + pluginModelTypes
        ),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
    )
}

@MainActor
func makePluginRegistryTestHarness() -> PluginRegistryTestHarness {
    let panelStore = PanelStore()
    let paletteExtensions = CommandPaletteExtensions()
    let snapshotRecorder = HotkeySnapshotRecorder()
    let hotkeyCoordinator = HotkeyCoordinator(
        quicklinkResolver: { _ in nil },
        quicklinkOpener: { _ in },
        quicklinkArgumentPresenter: { _, _, _, _ in },
        snapshotUpdater: { snapshotRecorder.record($0) }
    )
    let registry = PluginRegistry(
        panelStore: panelStore,
        paletteExtensions: paletteExtensions,
        hotkeyCoordinator: hotkeyCoordinator
    )
    return PluginRegistryTestHarness(
        registry: registry,
        panelStore: panelStore,
        paletteExtensions: paletteExtensions,
        snapshotRecorder: snapshotRecorder
    )
}

@MainActor
func bootstrapPluginRegistryTestHarness(
    _ harness: PluginRegistryTestHarness,
    plugins: [any NativePlugin],
    modelContainer: ModelContainer,
    defaults: UserDefaults,
    coreProviders: [any BuiltinProvider] = []
) {
    harness.registry.bootstrap(
        plugins: plugins,
        modelContainer: modelContainer,
        coreProviders: coreProviders,
        defaults: defaults
    )
}
