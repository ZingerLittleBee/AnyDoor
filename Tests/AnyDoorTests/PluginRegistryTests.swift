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
private final class LifecycleProbePlugin: NativePlugin {
    let id: NativePluginID
    let localizedName: String
    let localizedDescription = "Lifecycle ordering probe."
    let claimedCommands: Set<BuiltinItem>
    let providers: [any BuiltinProvider] = []
    private let onActivate: () -> Void
    private let onDeactivate: () -> Void
    private let onReadContributions: () -> Void

    init(
        id: String,
        claimedCommands: Set<BuiltinItem> = [],
        onActivate: @escaping () -> Void = {},
        onDeactivate: @escaping () -> Void = {},
        onReadContributions: @escaping () -> Void = {}
    ) {
        self.id = NativePluginID(rawValue: id)
        localizedName = id
        self.claimedCommands = claimedCommands
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onReadContributions = onReadContributions
    }

    var paletteOptionParents: Set<BuiltinItem> {
        onReadContributions()
        return []
    }

    func hasUsageTrace(in context: ModelContext) throws -> Bool { false }
    func activate() { onActivate() }

    func deactivate() async throws {
        onDeactivate()
    }
}

@MainActor
private final class SuspendingDeactivatePlugin: NativePlugin {
    let id: NativePluginID
    let localizedName: String
    let localizedDescription = "Deactivate waits for the test to resume it."
    let claimedCommands: Set<BuiltinItem> = []
    let providers: [any BuiltinProvider] = []
    private(set) var isDeactivating = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(id: String = "test.suspendingDeactivate") {
        self.id = NativePluginID(rawValue: id)
        self.localizedName = id
    }

    func hasUsageTrace(in context: ModelContext) throws -> Bool { false }

    func deactivate() async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isDeactivating = true
        }
        isDeactivating = false
    }

    func resumeDeactivation() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
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
    private func makeImageConversionPlugin() throws -> (
        plugin: ImageConversionNativePlugin,
        container: ModelContainer
    ) {
        let container = try makePluginRegistryTestContainer(
            pluginModelTypes: ImageConversionNativePlugin.modelSchemaTypes
        )
        return (
            ImageConversionNativePlugin(host: CorePluginHost(modelContainer: container)),
            container
        )
    }

    @MainActor
    private func panelItems(in store: PanelStore) -> [BuiltinItem] {
        store.topLevelEntries.compactMap {
            if case .builtin(let item) = $0.source { return item }
            return nil
        }
    }

    // MARK: - Install state & claims

    @MainActor
    func testFreshRegistryStartsUninstalledAndHidesClaimedCommands() throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertEqual(registry.claimOwner(of: .imageConversion), plugin.id)
        XCTAssertNil(registry.claimOwner(of: .keepAwake), "unclaimed commands belong to the Core")
        XCTAssertFalse(registry.isAvailable(.imageConversion))
        XCTAssertTrue(registry.isAvailable(.keepAwake))
        XCTAssertFalse(registry.availableCommands.contains(.imageConversion))
    }

    @MainActor
    func testInstallActivatesPersistsAndRegistersSurfaces() throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let itemKey = BuiltinItem.imageConversion.rawValue
        let retainedPreference = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == itemKey })
        ).first)
        retainedPreference.keyCode = 34
        retainedPreference.modifierFlags = 1 << 20
        let replacementQuicklink = Quicklink(
            id: UUID(),
            name: "Replacement",
            link: "https://example.com",
            keyCode: 34,
            modifierFlags: 1 << 20
        )
        container.mainContext.insert(replacementQuicklink)
        try container.mainContext.save()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry

        registry.install(plugin.id)

        XCTAssertTrue(registry.isInstalled(plugin.id))
        XCTAssertTrue(registry.isAvailable(.imageConversion))
        XCTAssertTrue(panelItems(in: harness.panelStore).contains(.imageConversion))
        XCTAssertNil(retainedPreference.keyCode,
                     "the registry must resolve retained conflicts before publishing surfaces")
        XCTAssertNil(retainedPreference.modifierFlags)
        XCTAssertEqual(harness.snapshotRecorder.updateCount, 1)
        XCTAssertEqual(harness.paletteRefreshRecorder.refreshCount, 1)
        XCTAssertEqual(
            harness.snapshotRecorder.snapshots.map(\.action),
            [.openQuicklink(id: replacementQuicklink.id)]
        )

        // Idempotent: a second install changes nothing.
        registry.install(plugin.id)
        XCTAssertEqual(harness.snapshotRecorder.updateCount, 1)

        // Persisted: a fresh registry over the same defaults reads the state
        // back and activates the plugin on bootstrap.
        let relaunchedHarness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            relaunchedHarness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let relaunched = relaunchedHarness.registry
        XCTAssertTrue(relaunched.isInstalled(plugin.id))
        XCTAssertTrue(panelItems(in: relaunchedHarness.panelStore).contains(.imageConversion))
        XCTAssertEqual(relaunchedHarness.snapshotRecorder.updateCount, 0)
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
        let otherPlugin = ImageConversionNativePlugin(
            host: CorePluginHost(modelContainer: otherContainer)
        )

        plugin.activate()
        otherPlugin.activate()
        XCTAssertTrue(plugin.historyStore.record(
            sourceName: "source.png",
            sourceKind: .file,
            targetFormat: .jpeg,
            qualityPercent: 85,
            outputPath: "/tmp/source.jpg"
        ))
        XCTAssertTrue(otherPlugin.historyStore.record(
            sourceName: "other.png",
            sourceKind: .file,
            targetFormat: .jpeg,
            qualityPercent: 85,
            outputPath: "/tmp/other.jpg"
        ))

        XCTAssertEqual(try expectedContainer.mainContext.fetchCount(
            FetchDescriptor<ImageConversionRecord>()
        ), 1)
        XCTAssertEqual(try otherContainer.mainContext.fetchCount(
            FetchDescriptor<ImageConversionRecord>()
        ), 1)
        XCTAssertEqual(plugin.historyStore.recent().map(\.sourceName), ["source.png"])
        XCTAssertEqual(otherPlugin.historyStore.recent().map(\.sourceName), ["other.png"])
        try await plugin.deactivate()
        try await otherPlugin.deactivate()
    }

    @MainActor
    func testImageConversionConstructionDoesNotCreateWorkspaceWindow() throws {
        let container = try ModelContainer(
            for: Schema(ImageConversionNativePlugin.modelSchemaTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plugin = ImageConversionNativePlugin(
            host: CorePluginHost(modelContainer: container)
        )

        XCTAssertFalse(plugin.hasCreatedWindowController)
    }

    @MainActor
    func testUninstallRevertsSurfacesAndPersists() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)
        let updatesAfterInstall = harness.snapshotRecorder.updateCount

        try await registry.uninstall(plugin.id)

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertFalse(registry.isAvailable(.imageConversion))
        XCTAssertFalse(panelItems(in: harness.panelStore).contains(.imageConversion))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, updatesAfterInstall + 1)

        let relaunchedHarness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            relaunchedHarness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let relaunched = relaunchedHarness.registry
        XCTAssertFalse(relaunched.isInstalled(plugin.id))
    }

    @MainActor
    func testUninstallDrainsPendingWindowPresentationWithoutReopening() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)

        let controller = plugin.windowController
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
        let container = try makePluginRegistryTestContainer()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)
        let refreshesAfterInstall = harness.snapshotRecorder.updateCount

        do {
            try await registry.uninstall(plugin.id)
            XCTFail("uninstall must rethrow the deactivate error")
        } catch {}

        XCTAssertEqual(plugin.deactivateCalls, 1)
        XCTAssertTrue(registry.isInstalled(plugin.id), "a failed deactivate must abort the uninstall")
        XCTAssertTrue(registry.isAvailable(.imageConversion))
        XCTAssertTrue(panelItems(in: harness.panelStore).contains(.imageConversion))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, refreshesAfterInstall)

        // The persisted state still says installed.
        let relaunchedHarness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            relaunchedHarness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        XCTAssertTrue(relaunchedHarness.registry.isInstalled(plugin.id))
    }

    // MARK: - Backup import (reconcile adopts the imported install state)

    @MainActor
    func testReconcileAfterImportInstallsFromImportedState() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        XCTAssertFalse(registry.isInstalled(plugin.id))

        // The settings import wrote the installed set into defaults; reconcile
        // must run the real install lifecycle so surfaces appear sans relaunch.
        defaults.set([plugin.id.rawValue], forKey: PluginRegistry.installStateKey)
        try await registry.reconcileAfterImport()

        XCTAssertTrue(registry.isInstalled(plugin.id))
        XCTAssertTrue(panelItems(in: harness.panelStore).contains(.imageConversion))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, 1)
    }

    @MainActor
    func testReconcileAfterImportUninstallsRemovedPlugins() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let (plugin, container) = try makeImageConversionPlugin()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)
        let updatesAfterInstall = harness.snapshotRecorder.updateCount

        defaults.set([String](), forKey: PluginRegistry.installStateKey)
        try await registry.reconcileAfterImport()

        XCTAssertFalse(registry.isInstalled(plugin.id))
        XCTAssertFalse(panelItems(in: harness.panelStore).contains(.imageConversion))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, updatesAfterInstall + 1)
        XCTAssertEqual(defaults.stringArray(forKey: PluginRegistry.installStateKey), [])
    }

    @MainActor
    func testReconcileAfterImportFailedUninstallKeepsPluginAndRepersists() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = ThrowingDeactivatePlugin()
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)

        defaults.set([String](), forKey: PluginRegistry.installStateKey)
        do {
            try await registry.reconcileAfterImport()
            XCTFail("a failed imported uninstall must be surfaced")
        } catch let error as PluginImportReconciliationError {
            XCTAssertEqual(error.failures, [
                PluginImportFailure(
                    pluginID: plugin.id,
                    pluginName: plugin.localizedName,
                    errorDescription: ThrowingDeactivatePlugin.DeactivateError().localizedDescription
                ),
            ])
        }

        XCTAssertEqual(plugin.deactivateCalls, 1)
        XCTAssertTrue(registry.isInstalled(plugin.id),
                      "a failed deactivate keeps the plugin installed, import or not")
        XCTAssertEqual(defaults.stringArray(forKey: PluginRegistry.installStateKey),
                       [plugin.id.rawValue],
                       "the stored state is re-persisted to match reality")
    }

    @MainActor
    func testReconcileAfterImportReportsAnUninstallAlreadyInProgress() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let plugin = SuspendingDeactivatePlugin()
        defer { plugin.resumeDeactivation() }
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        registry.install(plugin.id)

        let uninstall = Task { @MainActor in
            try await registry.uninstall(plugin.id)
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while !plugin.isDeactivating, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(plugin.isDeactivating)

        // The imported target still wants the plugin installed. Reconciliation
        // must not report success while an earlier uninstall can still reverse it.
        defaults.set([plugin.id.rawValue], forKey: PluginRegistry.installStateKey)
        do {
            try await registry.reconcileAfterImport()
            XCTFail("an in-progress lifecycle transition must be reported")
        } catch let error as PluginImportReconciliationError {
            XCTAssertEqual(error.failures.map(\.pluginID), [plugin.id])
        }

        plugin.resumeDeactivation()
        try await uninstall.value
        XCTAssertFalse(registry.isInstalled(plugin.id))
    }

    @MainActor
    func testReconcileAfterImportReportsATransitionStartedDuringAnotherRemoval() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let first = SuspendingDeactivatePlugin(id: "test.firstSuspendingDeactivate")
        let second = SuspendingDeactivatePlugin(id: "test.secondSuspendingDeactivate")
        defer {
            first.resumeDeactivation()
            second.resumeDeactivation()
        }
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness,
            plugins: [first, second],
            modelContainer: container,
            defaults: defaults
        )
        let registry = harness.registry
        registry.install(first.id)
        registry.install(second.id)

        // Reconciliation starts by removing `first`, while the imported target
        // keeps `second` installed.
        defaults.set([second.id.rawValue], forKey: PluginRegistry.installStateKey)
        let reconciliation = Task { @MainActor in
            do {
                try await registry.reconcileAfterImport()
                return nil as PluginImportReconciliationError?
            } catch let error as PluginImportReconciliationError {
                return error
            } catch {
                XCTFail("unexpected reconciliation error: \(error)")
                return nil
            }
        }
        let firstDeadline = ContinuousClock.now + .seconds(1)
        while !first.isDeactivating, ContinuousClock.now < firstDeadline {
            await Task.yield()
        }
        XCTAssertTrue(first.isDeactivating)

        // A manual uninstall enters while reconciliation is suspended. The
        // imported target must not be reported as converged afterward.
        let secondUninstall = Task { @MainActor in
            try await registry.uninstall(second.id)
        }
        let secondDeadline = ContinuousClock.now + .seconds(1)
        while !second.isDeactivating, ContinuousClock.now < secondDeadline {
            await Task.yield()
        }
        XCTAssertTrue(second.isDeactivating)

        first.resumeDeactivation()
        let reconciliationError = await reconciliation.value
        let error = try XCTUnwrap(reconciliationError)
        XCTAssertEqual(error.failures.map(\.pluginID), [second.id])

        second.resumeDeactivation()
        try await secondUninstall.value
    }

    // MARK: - End-to-end surfaces through the real PanelStore

    @MainActor
    func testLifecycleTogglesPanelRowThroughRealSurfaces() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }

        let container = try makePluginRegistryTestContainer(
            pluginModelTypes: ImageConversionNativePlugin.modelSchemaTypes
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let plugin = ImageConversionNativePlugin(host: CorePluginHost(modelContainer: container))
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry
        let store = harness.panelStore

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
        XCTAssertEqual(
            harness.snapshotRecorder.snapshots.map(\.action),
            [.runBuiltin(itemKey: BuiltinItem.imageConversion.rawValue)]
        )
        let entry = try XCTUnwrap(store.topLevelEntries.first {
            $0.source == .builtin(.imageConversion)
        })
        XCTAssertEqual(entry.hotkey, HotkeyDescriptor(keyCode: 11, modifierFlags: 42),
                       "reinstall restores the previously recorded hotkey")

        try await registry.uninstall(plugin.id)
        XCTAssertFalse(panelItems().contains(.imageConversion))
        XCTAssertTrue(harness.snapshotRecorder.snapshots.isEmpty)

        // The preference row survives the uninstall (data retention).
        let survivors = try container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        )
        XCTAssertEqual(survivors.first?.keyCode, 11)
    }

    // MARK: - Lifecycle ordering

    @MainActor
    func testColdLaunchActivatesBeforeEnteringInstalledAndPublishesAfterward() throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        let id = NativePluginID(rawValue: "test.lifecycle")
        defaults.set([id.rawValue], forKey: PluginRegistry.installStateKey)

        var installedDuringActivate: Bool?
        var installedWhenReadingContributions: Bool?
        let plugin = LifecycleProbePlugin(
            id: id.rawValue,
            onActivate: { installedDuringActivate = harness.registry.isInstalled(id) },
            onReadContributions: {
                installedWhenReadingContributions = harness.registry.isInstalled(id)
            }
        )

        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )

        XCTAssertEqual(installedDuringActivate, false)
        XCTAssertEqual(installedWhenReadingContributions, true)
        XCTAssertTrue(harness.registry.isInstalled(id))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, 0,
                       "cold launch must not start hotkey publication before app startup completes")
    }

    @MainActor
    func testImportRemovesPluginsBeforeInstallingAdditions() async throws {
        let (defaults, teardown) = try makeIsolatedDefaults()
        defer { teardown() }
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        let oldID = NativePluginID(rawValue: "test.old")
        let newID = NativePluginID(rawValue: "test.new")
        var lifecycle: [String] = []
        let oldPlugin = LifecycleProbePlugin(
            id: oldID.rawValue,
            onActivate: { lifecycle.append("activate.old") },
            onDeactivate: { lifecycle.append("deactivate.old") }
        )
        let newPlugin = LifecycleProbePlugin(
            id: newID.rawValue,
            onActivate: { lifecycle.append("activate.new") },
            onDeactivate: { lifecycle.append("deactivate.new") }
        )
        defaults.set([oldID.rawValue], forKey: PluginRegistry.installStateKey)
        bootstrapPluginRegistryTestHarness(
            harness,
            plugins: [oldPlugin, newPlugin],
            modelContainer: container,
            defaults: defaults
        )
        lifecycle.removeAll()

        defaults.set([newID.rawValue], forKey: PluginRegistry.installStateKey)
        try await harness.registry.reconcileAfterImport()

        XCTAssertEqual(lifecycle, ["deactivate.old", "activate.new"])
        XCTAssertEqual(harness.registry.installedIDs, Set([newID]))
        XCTAssertEqual(harness.snapshotRecorder.updateCount, 2,
                       "each async lifecycle transition must publish immediately")
        XCTAssertEqual(harness.paletteRefreshRecorder.refreshCount, 2)
    }
}
