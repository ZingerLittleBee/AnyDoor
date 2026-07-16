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
        XCTAssertNotNil(registry.rowSource(withID: "fixture.rows"))

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
        XCTAssertNil(registry.rowSource(withID: "fixture.rows"))
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

    // MARK: - Registry pushes palette contributions through the surface hooks

    @MainActor
    func testInstallAndUninstallFirePaletteContributionHooks() async throws {
        let suiteName = "PluginPaletteContributionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plugin = FixturePlugin()
        let registry = PluginRegistry()
        var registered: [String] = []
        var unregistered: [String] = []
        var hooks = PluginRegistry.SurfaceHooks.noop
        hooks.registerPaletteContributions = { registered.append($0.id.rawValue) }
        hooks.unregisterPaletteContributions = { unregistered.append($0.id.rawValue) }
        registry.bootstrap(plugins: [plugin], defaults: defaults, hooks: hooks)

        registry.install(plugin.id)
        XCTAssertEqual(registered, ["test.fixture"])

        try await registry.uninstall(plugin.id)
        XCTAssertEqual(unregistered, ["test.fixture"])
    }

    // MARK: - Panel popover lookup gates on the installed set

    @MainActor
    func testPanelPopoverLookupOnlyAnswersWhileInstalled() throws {
        let suiteName = "PluginPaletteContributionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plugin = FixturePlugin()
        let registry = PluginRegistry()
        registry.bootstrap(plugins: [plugin], defaults: defaults, hooks: .noop)

        XCTAssertNil(registry.panelPopover(for: .hostsManager),
                     "an uninstalled plugin's popover must not surface")
        // Core-owned submenu commands have no plugin popover either.
        XCTAssertNil(registry.panelPopover(for: .bluetoothBattery))

        registry.install(plugin.id)
        XCTAssertNotNil(registry.panelPopover(for: .hostsManager))
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
