import SwiftData
import XCTest
import PluginInterface
@testable import AnyDoor

/// A minimal Native Plugin exercising every generic palette/panel extension
/// point: an option parent with checkable options, a row source, and a panel
/// popover. Used to pin the registration-based plumbing without naming a
/// production plugin (ADR-0007: Core control flow reads registrations only).
@MainActor
private final class FixturePlugin: NativePlugin {
    final class FixtureRowSource: PluginRowSource {
        let id = "fixture.rows"
        let sectionTitleKey = "commandPalette.section.hosts"
        private(set) var performedIDs: [String] = []

        func rows() -> [PluginRowDescriptor] {
            [PluginRowDescriptor(id: "row-1", title: "Row", symbol: "circle", commit: .closeThenAct)]
        }

        func performRow(id: String) async {
            performedIDs.append(id)
        }
    }

    let id = NativePluginID(rawValue: "test.fixture")
    let localizedName = "Fixture"
    let localizedDescription = "Palette contribution fixture."
    let claimedCommands: Set<BuiltinItem> = [.hostsManager]
    let providers: [any BuiltinProvider] = []
    let paletteOptionParents: Set<BuiltinItem> = [.hostsManager]
    let rowSource = FixtureRowSource()
    var paletteRowSources: [any PluginRowSource] { [rowSource] }
    private(set) var performedOptions: [(parent: BuiltinItem, id: String)] = []

    func paletteOptions(for parent: BuiltinItem) async -> [PluginRowDescriptor] {
        guard parent == .hostsManager else { return [] }
        return [
            PluginRowDescriptor(
                id: "opt-active", title: "Active", subtitle: "sub", symbol: "circle",
                isChecked: true, commit: .closeThenAct
            ),
            PluginRowDescriptor(id: "opt-plain", title: "Plain", symbol: "pencil", commit: .closeThenAct),
        ]
    }

    func performPaletteOption(parent: BuiltinItem, id: String) async {
        performedOptions.append((parent, id))
    }

    func panelPopover(for command: BuiltinItem) -> PluginPanelPopover? {
        guard command == .hostsManager else { return nil }
        return PluginPanelPopover(
            needsKeyFocus: false,
            makeContent: { _ in AnyView(EmptyView()) },
            refresh: nil
        )
    }

    func hasUsageTrace(in context: ModelContext) throws -> Bool { false }
    func deactivate() async throws {}
}

import SwiftUI

final class PluginPaletteContributionTests: XCTestCase {

    // MARK: - Palette contributions register/unregister as one unit

    @MainActor
    func testRegisterContributionsExposesOptionParentAndRowSource() async {
        let registry = CommandPaletteExtensions()
        let plugin = FixturePlugin()

        registry.registerContributions(of: plugin)

        XCTAssertTrue(registry.isOptionParent(.hostsManager))
        XCTAssertTrue(registry.listsAtRoot(.hostsManager),
                      "a plugin submenu option parent lists as a root command row")
        XCTAssertNotNil(registry.rowSource(for: rowSourceKey(for: plugin)))

        let options = await registry.options(for: .hostsManager)
        XCTAssertEqual(options?.map(\.id), ["opt-active", "opt-plain"])
        XCTAssertEqual(options?.map(\.isChecked), [true, false])
        XCTAssertEqual(options?.first?.subtitle, "sub")

        // Committing an option routes back through the plugin's generic hook.
        await options?.first?.perform()
        XCTAssertEqual(plugin.performedOptions.map(\.id), ["opt-active"])
        XCTAssertEqual(plugin.performedOptions.map(\.parent), [.hostsManager])
    }

    @MainActor
    func testUnregisterContributionsRemovesEverySurface() async {
        let registry = CommandPaletteExtensions()
        let plugin = FixturePlugin()
        registry.registerContributions(of: plugin)

        registry.unregisterContributions(of: plugin)

        XCTAssertFalse(registry.isOptionParent(.hostsManager))
        XCTAssertFalse(registry.listsAtRoot(.hostsManager))
        XCTAssertNil(registry.rowSource(for: rowSourceKey(for: plugin)))
        let options = await registry.options(for: .hostsManager)
        XCTAssertNil(options)
    }

    @MainActor
    func testRowSourceRegistrationUsesTheSourcesSectionTitleKey() {
        let registry = CommandPaletteExtensions()
        let plugin = FixturePlugin()
        registry.registerContributions(of: plugin)

        XCTAssertEqual(registry.rowSources.first?.sectionTitleKey, "commandPalette.section.hosts")
    }

    @MainActor
    func testRowSourcesWithTheSameLocalIDRemainIsolatedByPlugin() {
        let registry = CommandPaletteExtensions()
        let first = FixturePlugin.FixtureRowSource()
        let second = FixturePlugin.FixtureRowSource()
        let firstKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "test.first"),
            localID: first.id
        )
        let secondKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "test.second"),
            localID: second.id
        )

        registry.registerRowSource(first, ownerID: firstKey.pluginID)
        registry.registerRowSource(second, ownerID: secondKey.pluginID)

        XCTAssertTrue(registry.rowSource(for: firstKey) === first)
        XCTAssertTrue(registry.rowSource(for: secondKey) === second)

        registry.unregisterRowSource(key: firstKey)

        XCTAssertNil(registry.rowSource(for: firstKey))
        XCTAssertTrue(registry.rowSource(for: secondKey) === second)
    }

    // MARK: - Registry owns palette contribution publication

    @MainActor
    func testInstallAndUninstallPublishPaletteContributions() async throws {
        let suiteName = "PluginPaletteContributionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plugin = FixturePlugin()
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry

        registry.install(plugin.id)
        XCTAssertTrue(harness.paletteExtensions.isOptionParent(.hostsManager))
        XCTAssertNotNil(harness.paletteExtensions.rowSource(for: rowSourceKey(for: plugin)))

        try await registry.uninstall(plugin.id)
        XCTAssertFalse(harness.paletteExtensions.isOptionParent(.hostsManager))
        XCTAssertNil(harness.paletteExtensions.rowSource(for: rowSourceKey(for: plugin)))
    }

    // MARK: - Panel popover lookup gates on the installed set

    @MainActor
    func testPanelPopoverLookupOnlyAnswersWhileInstalled() throws {
        let suiteName = "PluginPaletteContributionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plugin = FixturePlugin()
        let container = try makePluginRegistryTestContainer()
        let harness = makePluginRegistryTestHarness()
        bootstrapPluginRegistryTestHarness(
            harness, plugins: [plugin], modelContainer: container, defaults: defaults
        )
        let registry = harness.registry

        XCTAssertNil(registry.panelPopover(for: .hostsManager),
                     "an uninstalled plugin's popover must not surface")
        // Core-owned submenu commands have no plugin popover either.
        XCTAssertNil(registry.panelPopover(for: .bluetoothBattery))

        registry.install(plugin.id)
        XCTAssertNotNil(registry.panelPopover(for: .hostsManager))
    }

    @MainActor
    private func rowSourceKey(for plugin: FixturePlugin) -> PluginRowSourceKey {
        PluginRowSourceKey(pluginID: plugin.id, localID: plugin.rowSource.id)
    }
}

/// Pins the shared-daemon release policy (amended ADR-0005): Hosts' uninstall
/// releases the privileged helper only when no other Core consumer needs it —
/// forced Scheduled Shutdown shuts down through the same daemon.
final class PrivilegedHelperReleaseTests: XCTestCase {

    @MainActor
    func testReleaseSkipsUnregisterWhileForcedShutdownNeedsTheDaemon() throws {
        var unregistered = false
        let release = PrivilegedHelperRelease(
            otherConsumersActive: { true },
            unregister: { unregistered = true }
        )
        try release.releaseIfUnneeded()
        XCTAssertFalse(unregistered)
    }

    @MainActor
    func testReleaseUnregistersWhenNoOtherConsumerNeedsIt() throws {
        var unregistered = false
        let release = PrivilegedHelperRelease(
            otherConsumersActive: { false },
            unregister: { unregistered = true }
        )
        try release.releaseIfUnneeded()
        XCTAssertTrue(unregistered)
    }

    @MainActor
    func testReleasePropagatesAnUnregisterFailure() {
        struct Failure: Error {}
        let release = PrivilegedHelperRelease(
            otherConsumersActive: { false },
            unregister: { throw Failure() }
        )
        XCTAssertThrowsError(try release.releaseIfUnneeded())
    }
}
