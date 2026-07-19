import SwiftData
import XCTest
import PluginInterface
@testable import AnyDoor
@testable import ImageConversionPlugin

/// A real `NativePlugin` instance whose deactivate fails, for exercising the
/// registry's transactional-uninstall guarantee (the production pilots'
/// deactivates cannot be made to fail on demand).
@MainActor
private final class ThrowingDeactivatePlugin: NativePlugin {
    struct DeactivateError: Error {}

    let id = NativePluginID(rawValue: "test.throwingDeactivate")
    let localizedName = "Throwing"
    let localizedDescription = "Deactivate always fails."
    let claimedCommands: Set<BuiltinItem> = [.imageConversion]
    let providers: [any BuiltinProvider] = []
    private(set) var deactivateCalls = 0

    func hasUsageTrace(in context: ModelContext) throws -> Bool { false }

    func deactivate() async throws {
        deactivateCalls += 1
        throw DeactivateError()
    }
}

@MainActor
private final class FinderSelectionGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<[URL], Never>?

    func read() async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func resume(returning urls: [URL] = []) {
        let continuation = continuation
        self.continuation = nil
        isWaiting = false
        continuation?.resume(returning: urls)
    }
}

final class PluginRegistryTests: XCTestCase {

    @MainActor
    private func makeIsolatedDefaults() throws -> (UserDefaults, teardown: () -> Void) {
        let suiteName = "PluginRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @MainActor
    private func makeImageConversionPlugin() throws -> ImageConversionNativePlugin {
        let container = try ModelContainer(
            for: Schema(ImageConversionNativePlugin.modelSchemaTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ImageConversionNativePlugin(host: CorePluginHost(modelContainer: container))
    }

    // MARK: - Install state & claims

    @MainActor
    func testFreshRegistryStartsUninstalledAndHidesClaimedCommands() throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()

        let registry = PluginRegistry()
        registry.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertEqual(registry.claimOwner(of: .imageConversion), plugin.id)
        XCTAssertNil(registry.claimOwner(of: .keepAwake), "unclaimed commands belong to the Core")
        XCTAssertFalse(registry.isAvailable(.imageConversion))
        XCTAssertTrue(registry.isAvailable(.keepAwake))
        XCTAssertFalse(registry.availableCommands.contains(.imageConversion))
        XCTAssertTrue(registry.installedProviders.isEmpty)
    }

    @MainActor
    func testInstallActivatesPersistsAndRegistersSurfaces() throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()

        var registered: [BuiltinItem] = []
        var prepared: [(returning: Set<BuiltinItem>, active: Set<BuiltinItem>)] = []
        var refreshes = 0
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { registered.append(contentsOf: $0.map(\.itemKey)) },
                unregisterProviders: { _ in XCTFail("install must not unregister") },
                prepareInstall: { prepared.append((returning: $0, active: $1)) },
                refreshSurfaces: { refreshes += 1 }
            )
        )

        registry.install(plugin.id)

        XCTAssertTrue(registry.isInstalled(plugin.id))
        XCTAssertTrue(registry.isAvailable(.imageConversion))
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].returning, [.imageConversion])
        XCTAssertFalse(prepared[0].active.contains(.imageConversion))
        XCTAssertEqual(registered, [.imageConversion])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(registry.installedProviders.map(\.itemKey), [.imageConversion])

        // Idempotent: a second install changes nothing.
        registry.install(plugin.id)
        XCTAssertEqual(registered, [.imageConversion])
        XCTAssertEqual(refreshes, 1)

        // Persisted: a fresh registry over the same defaults reads the state
        // back and activates the plugin on bootstrap.
        let relaunched = PluginRegistry()
        relaunched.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)
        XCTAssertTrue(relaunched.isInstalled(plugin.id))
        XCTAssertEqual(relaunched.installedProviders.map(\.itemKey), [.imageConversion])
    }

    @MainActor
    func testImageConversionActivationUsesItsCapturedHost() async throws {
        func makeContainer() throws -> ModelContainer {
            try ModelContainer(
                for: Schema(ImageConversionNativePlugin.modelSchemaTypes),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        let expectedContainer = try makeContainer()
        let otherContainer = try makeContainer()
        let plugin = ImageConversionNativePlugin(
            host: CorePluginHost(modelContainer: expectedContainer)
        )
        _ = ImageConversionNativePlugin(host: CorePluginHost(modelContainer: otherContainer))

        plugin.activate()
        XCTAssertTrue(ImageConversionHistoryStore.shared.record(
            sourceName: "source.png",
            sourceKind: .file,
            targetFormat: .jpeg,
            qualityPercent: 85,
            outputPath: "/tmp/source.jpg"
        ))

        XCTAssertEqual(try expectedContainer.mainContext.fetchCount(
            FetchDescriptor<ImageConversionRecord>()
        ), 1)
        XCTAssertEqual(try otherContainer.mainContext.fetchCount(
            FetchDescriptor<ImageConversionRecord>()
        ), 0)
        try await plugin.deactivate()
    }

    @MainActor
    func testUninstallRevertsSurfacesAndPersists() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()

        var unregistered: [Set<BuiltinItem>] = []
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { _ in },
                unregisterProviders: { unregistered.append($0) },
                refreshSurfaces: {}
            )
        )
        registry.install(plugin.id)

        try await registry.uninstall(plugin.id)

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertFalse(registry.isAvailable(.imageConversion))
        XCTAssertEqual(unregistered, [[.imageConversion]])

        let relaunched = PluginRegistry()
        relaunched.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)
        XCTAssertFalse(relaunched.isInstalled(plugin.id))
    }

    @MainActor
    func testUninstallDrainsPendingWindowPresentationWithoutReopening() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()
        let registry = PluginRegistry()
        registry.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)
        registry.install(plugin.id)

        let controller = ImageConversionWindowController.shared
        controller.close()
        let previousReader = controller.finderSelectionReader
        defer { controller.finderSelectionReader = previousReader }
        let gate = FinderSelectionGate()
        controller.finderSelectionReader = { await gate.read() }

        let presentation = Task { @MainActor in
            await controller.toggle()
        }
        let presentationDeadline = ContinuousClock.now + .seconds(1)
        while !gate.isWaiting, ContinuousClock.now < presentationDeadline {
            await Task.yield()
        }
        XCTAssertTrue(gate.isWaiting)

        var uninstallFinished = false
        let uninstall = Task { @MainActor in
            try await registry.uninstall(plugin.id)
            uninstallFinished = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(uninstallFinished,
                       "uninstall must drain the Finder-backed presentation")

        gate.resume()
        try await uninstall.value
        await presentation.value

        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertFalse(registry.isInstalled(plugin.id))
    }

    @MainActor
    func testThrowingDeactivateLeavesThePluginInstalled() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = ThrowingDeactivatePlugin()

        var unregisters = 0
        var refreshes = 0
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { _ in },
                unregisterProviders: { _ in unregisters += 1 },
                refreshSurfaces: { refreshes += 1 }
            )
        )
        registry.install(plugin.id)
        let refreshesAfterInstall = refreshes

        do {
            try await registry.uninstall(plugin.id)
            XCTFail("uninstall must rethrow the deactivate error")
        } catch {}

        XCTAssertEqual(plugin.deactivateCalls, 1)
        XCTAssertTrue(registry.isInstalled(plugin.id), "a failed deactivate must abort the uninstall")
        XCTAssertTrue(registry.isAvailable(.imageConversion))
        XCTAssertEqual(unregisters, 0)
        XCTAssertEqual(refreshes, refreshesAfterInstall)

        // The persisted state still says installed.
        let relaunched = PluginRegistry()
        relaunched.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)
        XCTAssertTrue(relaunched.isInstalled(plugin.id))
    }

    // MARK: - Backup import (reconcile adopts the imported install state)

    @MainActor
    func testReconcileAfterImportInstallsFromImportedState() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()

        var registered: [BuiltinItem] = []
        var refreshes = 0
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { registered.append(contentsOf: $0.map(\.itemKey)) },
                unregisterProviders: { _ in XCTFail("an import that installs must not unregister") },
                refreshSurfaces: { refreshes += 1 }
            )
        )
        XCTAssertFalse(registry.isInstalled(plugin.id))

        // The settings import wrote the installed set into defaults; reconcile
        // must run the real install lifecycle so surfaces appear sans relaunch.
        defaults.set([plugin.id.rawValue], forKey: PluginRegistry.installStateKey)
        await registry.reconcileAfterImport()

        XCTAssertTrue(registry.isInstalled(plugin.id))
        XCTAssertEqual(registered, [.imageConversion])
        XCTAssertEqual(refreshes, 1)
    }

    @MainActor
    func testReconcileAfterImportUninstallsRemovedPlugins() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = try makeImageConversionPlugin()

        var unregistered: [Set<BuiltinItem>] = []
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { _ in },
                unregisterProviders: { unregistered.append($0) },
                refreshSurfaces: {}
            )
        )
        registry.install(plugin.id)

        defaults.set([String](), forKey: PluginRegistry.installStateKey)
        await registry.reconcileAfterImport()

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertEqual(unregistered, [[.imageConversion]])
        XCTAssertEqual(defaults.stringArray(forKey: PluginRegistry.installStateKey), [])
    }

    @MainActor
    func testReconcileAfterImportFailedUninstallKeepsPluginAndRepersists() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = ThrowingDeactivatePlugin()

        let registry = PluginRegistry()
        registry.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)
        registry.install(plugin.id)

        defaults.set([String](), forKey: PluginRegistry.installStateKey)
        await registry.reconcileAfterImport()

        XCTAssertEqual(plugin.deactivateCalls, 1)
        XCTAssertTrue(registry.isInstalled(plugin.id),
                      "a failed deactivate keeps the plugin installed, import or not")
        XCTAssertEqual(defaults.stringArray(forKey: PluginRegistry.installStateKey),
                       [plugin.id.rawValue],
                       "the stored state is re-persisted to match reality")
    }

    // MARK: - End-to-end surfaces through the real PanelStore

    @MainActor
    func testLifecycleTogglesPanelRowThroughRealSurfaces() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }

        let container = try ModelContainer(
            for: Schema(
                [KeyBinding.self, BuiltinPreference.self]
                    + ImageConversionNativePlugin.modelSchemaTypes
            ),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let plugin = ImageConversionNativePlugin(host: CorePluginHost(modelContainer: container))

        let registry = PluginRegistry()
        let store = PanelStore.shared
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { store.registerProviders($0) },
                unregisterProviders: { store.unregisterProviders(for: $0) },
                refreshSurfaces: { store.rebuild() }
            )
        )
        store.bootstrap(
            modelContainer: container,
            providers: registry.installedProviders,
            commandAvailability: { registry.isAvailable($0) }
        )

        func panelItems() -> [BuiltinItem] {
            store.topLevelEntries.compactMap {
                if case .builtin(let item) = $0.source { return item }
                return nil
            }
        }

        // Uninstalled: no panel row (and therefore no palette entry, which
        // lists from the same store).
        XCTAssertFalse(panelItems().contains(.imageConversion))

        // Record a hotkey on the (hidden) preference row so reinstall can
        // prove retention.
        let key = BuiltinItem.imageConversion.rawValue
        let pref = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first)
        pref.keyCode = 11
        pref.modifierFlags = 42
        try container.mainContext.save()

        registry.install(plugin.id)
        XCTAssertTrue(panelItems().contains(.imageConversion))
        let entry = try XCTUnwrap(store.topLevelEntries.first {
            $0.source == .builtin(.imageConversion)
        })
        XCTAssertEqual(entry.hotkey, HotkeyDescriptor(keyCode: 11, modifierFlags: 42),
                       "reinstall restores the previously recorded hotkey")

        try await registry.uninstall(plugin.id)
        XCTAssertFalse(panelItems().contains(.imageConversion))

        // The preference row survives the uninstall (data retention).
        let survivors = try container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        )
        XCTAssertEqual(survivors.first?.keyCode, 11)
    }
}
