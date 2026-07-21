import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// Registry lifecycle for the second plugin kind — Script Plugins — running the
/// real `ScriptPluginRuntime` over real JavaScriptCore against fixture packages
/// (PRD Testing Decisions: the engine is never mocked; the one injected boundary
/// is the fetch transport). Mirrors the Native pilot lifecycle tests: install
/// publishes the palette row source, uninstall removes the package copy and the
/// surface while retaining the private store, and reinstall finds prior data.
@MainActor
final class ScriptPluginRegistryTests: XCTestCase {

    private struct Fixture {
        let registry: ScriptPluginRegistry
        let runtime: ScriptPluginRuntime
        let palette: CommandPaletteExtensions
        let spy: ScriptCapabilitySpy
        let packagesDirectory: URL
        let storeDirectory: URL
        let defaults: UserDefaults
        var paletteRefreshCount: () -> Int
        let teardown: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "ScriptPluginRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()

        let spy = ScriptCapabilitySpy()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: spy,
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "{}")),
            storeDirectory: storeDirectory
        )
        let runtime = ScriptPluginRuntime(capabilityHost: host)
        let palette = CommandPaletteExtensions()
        var refreshCount = 0
        let registry = ScriptPluginRegistry(
            runtime: runtime,
            packagesDirectory: packagesDirectory,
            paletteExtensions: palette,
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: { refreshCount += 1 }
        )
        return Fixture(
            registry: registry,
            runtime: runtime,
            palette: palette,
            spy: spy,
            packagesDirectory: packagesDirectory,
            storeDirectory: storeDirectory,
            defaults: defaults,
            paletteRefreshCount: { refreshCount },
            teardown: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: packagesDirectory)
                try? FileManager.default.removeItem(at: storeDirectory)
            }
        )
    }

    private func rowSourceKey(for id: ScriptPluginID) -> PluginRowSourceKey {
        // Mirrors ScriptPluginRegistry's private namespacing: the "script:" owner
        // prefix keeps the key out of Native id space.
        PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:" + id.rawValue),
            localID: ScriptPluginRowSource.localID
        )
    }

    private func rowsFixture(id: String, capabilities: [String] = []) throws -> URL {
        try ScriptPluginFixture.writePackage(
            id: id,
            name: "Rows Fixture",
            description: "Emits palette rows.",
            capabilities: capabilities,
            bundle: """
            anydoor.registerPlugin({
              rows: function (query) {
                return [
                  { id: "a", title: "Alpha", subtitle: "first", commit: "stayOpen" },
                  { id: "b", title: "Beta", commit: "closeThenAct" }
                ];
              }
            });
            """
        )
    }

    // MARK: - Sideload publishes rows

    func testSideloadInstallsListsAndPublishesRows() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let source = try rowsFixture(id: "com.acme.rows")
        let id = try f.registry.sideload(fromDirectory: source)

        XCTAssertTrue(f.registry.isInstalled(id))
        XCTAssertEqual(f.registry.installedManifests.map(\.id), [id])
        XCTAssertEqual(f.registry.installedManifests.first?.name, "Rows Fixture")
        XCTAssertNotNil(f.palette.rowSource(for: rowSourceKey(for: id)),
                        "install registers the palette row source")
        XCTAssertGreaterThanOrEqual(f.paletteRefreshCount(), 1,
                                    "install recomposes a visible palette")

        // The package copy landed in storage.
        let copied = try FileManager.default.contentsOfDirectory(
            atPath: f.packagesDirectory.path)
        XCTAssertEqual(copied.count, 1)

        // The row source produces the plugin's rows through real JavaScriptCore.
        let source0 = try XCTUnwrap(f.registry.rowSource(for: id))
        await source0.refresh()
        XCTAssertEqual(source0.rows().map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(source0.rows().map(\.commit), [.stayOpen, .closeThenAct])
    }

    // MARK: - Invalid packages change nothing

    func testMissingManifestFieldRefusedChangesNothing() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let source = try ScriptPluginFixture.writeRawPackage(
            manifest: ["id": "com.acme.bad", "description": "no name", "version": "1", "apiVersion": 1],
            bundle: "anydoor.registerPlugin({});"
        )

        XCTAssertThrowsError(try f.registry.sideload(fromDirectory: source)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .missingField("name"))
        }
        assertNothingInstalled(f)
    }

    func testUnknownAPIVersionRefusedChangesNothing() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let source = try ScriptPluginFixture.writePackage(
            id: "com.acme.future", apiVersion: 2, bundle: "anydoor.registerPlugin({});"
        )

        XCTAssertThrowsError(try f.registry.sideload(fromDirectory: source)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .unknownAPIVersion(2))
        }
        assertNothingInstalled(f)
    }

    func testDuplicateIDRefusedChangesNothing() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let first = try rowsFixture(id: "com.acme.dupe")
        let id = try f.registry.sideload(fromDirectory: first)
        let refreshAfterFirst = f.paletteRefreshCount()

        let second = try rowsFixture(id: "com.acme.dupe")
        XCTAssertThrowsError(try f.registry.sideload(fromDirectory: second)) { error in
            XCTAssertEqual(error as? ScriptPluginError, .duplicateID(id))
        }

        // Still exactly one install, one package copy, no extra palette refresh.
        XCTAssertEqual(f.registry.installedManifests.map(\.id), [id])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: f.packagesDirectory.path).count, 1)
        XCTAssertEqual(f.paletteRefreshCount(), refreshAfterFirst)
    }

    private func assertNothingInstalled(_ f: Fixture) {
        XCTAssertTrue(f.registry.installedManifests.isEmpty)
        XCTAssertTrue(f.palette.rowSources.isEmpty)
        let copied = (try? FileManager.default.contentsOfDirectory(atPath: f.packagesDirectory.path)) ?? []
        XCTAssertTrue(copied.isEmpty, "a refused package must leave no copy on disk")
    }

    // MARK: - Uninstall removes everything, retains the store

    func testUninstallRemovesCopyAndSurfaceRetainsStoreForReinstall() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        // A store-capable fixture: rows() echoes a stored value; action() writes it.
        let bundle = """
        anydoor.registerPlugin({
          rows: async function (query) {
            var saved = await anydoor.store.get("greeting");
            return [{ id: "r1", title: "Hello " + (saved || "none"), commit: "closeThenAct" }];
          },
          action: async function (rowID, actionID) {
            await anydoor.store.set("greeting", "world");
            return "ok";
          }
        });
        """
        let source = try ScriptPluginFixture.writePackage(
            id: "com.acme.store", capabilities: ["store"], bundle: bundle
        )
        let id = try f.registry.sideload(fromDirectory: source)

        // Write into the private store through the row action.
        _ = try await f.runtime.performAction(pluginID: id, rowID: "r1", actionID: "default")

        let refreshBeforeUninstall = f.paletteRefreshCount()
        try await f.registry.uninstall(id)

        // Everything visible is gone.
        XCTAssertFalse(f.registry.isInstalled(id))
        XCTAssertTrue(f.registry.installedManifests.isEmpty)
        XCTAssertNil(f.palette.rowSource(for: rowSourceKey(for: id)))
        XCTAssertGreaterThan(f.paletteRefreshCount(), refreshBeforeUninstall,
                             "uninstall recomposes a visible palette")
        // The package copy is deleted…
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: f.packagesDirectory.path)) ?? []
        XCTAssertTrue(remaining.isEmpty)
        // …but the private key-value store file survives.
        let storeFiles = try FileManager.default.contentsOfDirectory(atPath: f.storeDirectory.path)
        XCTAssertFalse(storeFiles.isEmpty, "the private store must be retained across uninstall")

        // Reinstalling the same id finds the prior data.
        let reinstalled = try f.registry.sideload(fromDirectory: source)
        XCTAssertEqual(reinstalled, id)
        let reSource = try XCTUnwrap(f.registry.rowSource(for: id))
        await reSource.refresh()
        XCTAssertEqual(reSource.rows().map(\.title), ["Hello world"],
                       "reinstall restores the retained store value")
    }

    // MARK: - Uninstalled = no rows anywhere

    func testUninstalledPluginProducesNoRowSource() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let source = try rowsFixture(id: "com.acme.gone")
        let id = try f.registry.sideload(fromDirectory: source)
        XCTAssertNotNil(f.palette.rowSource(for: rowSourceKey(for: id)))

        try await f.registry.uninstall(id)

        XCTAssertNil(f.palette.rowSource(for: rowSourceKey(for: id)))
        XCTAssertTrue(f.palette.rowSources.isEmpty)
        XCTAssertNil(f.registry.rowSource(for: id))
    }

    // MARK: - Uninstall while a Detail is visible discards the drill-in

    func testUninstallWhileDetailVisibleDiscardsDrillInAndRemovesRows() async throws {
        let suiteName = "ScriptPluginRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: packagesDirectory)
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "{}")),
            storeDirectory: storeDirectory
        )
        let palette = CommandPaletteExtensions()
        // A real palette state, refreshed exactly as the window controller wires
        // it (`refreshPluginSurfaces`): pop out of any drill-in, then re-read the
        // live row-source registrations. This is the seam the uninstall drives.
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: palette.rowSources)
        let registry = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: packagesDirectory,
            paletteExtensions: palette,
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: {
                if !state.isAtRoot { state.popToRoot() }
                state.updateSections([], pluginRowSources: palette.rowSources)
            }
        )

        let source = try rowsFixture(id: "com.acme.detail")
        let id = try registry.sideload(fromDirectory: source)
        let liveSource = try XCTUnwrap(registry.rowSource(for: id))
        await liveSource.refresh()
        state.updateSections([], pluginRowSources: palette.rowSources)

        // The plugin's rows are searchable at the root…
        state.query = "Alpha"
        XCTAssertFalse(state.filteredSections.isEmpty)

        // …and the user has drilled into a Detail.
        state.enterDetail(title: "Alpha")
        XCTAssertTrue(state.isInDetail)

        try await registry.uninstall(id)

        // Uninstall recomposed the visible palette: the Detail is gone and the
        // plugin's rows have vanished entirely.
        XCTAssertTrue(state.isAtRoot)
        XCTAssertFalse(state.isInDetail)
        XCTAssertNil(registry.rowSource(for: id))
        XCTAssertTrue(palette.rowSources.isEmpty)
        state.query = "Alpha"
        XCTAssertTrue(state.filteredSections.isEmpty)
    }

    // MARK: - Uninstall while in a plugin's list discards the drill-in

    func testUninstallWhileListVisibleDiscardsDrillInAndRemovesRows() async throws {
        let suiteName = "ScriptPluginRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: packagesDirectory)
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "{}")),
            storeDirectory: storeDirectory
        )
        let palette = CommandPaletteExtensions()
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: palette.rowSources)
        let registry = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: packagesDirectory,
            paletteExtensions: palette,
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: {
                if !state.isAtRoot { state.popToRoot() }
                state.updateSections([], pluginRowSources: palette.rowSources)
            }
        )

        let source = try rowsFixture(id: "com.acme.list")
        let id = try registry.sideload(fromDirectory: source)
        let liveSource = try XCTUnwrap(registry.rowSource(for: id))
        await liveSource.refresh()
        state.updateSections([], pluginRowSources: palette.rowSources)

        // The user has drilled into a searchable second-level list.
        let key = rowSourceKey(for: id)
        state.enterList(sourceKey: key, listID: "hot", title: "Hot")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: state.listGeneration)
        XCTAssertTrue(state.isInList)

        try await registry.uninstall(id)

        // Uninstall recomposed the visible palette: the list drill-in is gone and
        // the plugin's rows have vanished entirely.
        XCTAssertTrue(state.isAtRoot)
        XCTAssertFalse(state.isInList)
        XCTAssertNil(registry.rowSource(for: id))
        XCTAssertTrue(palette.rowSources.isEmpty)
        state.query = "Alpha"
        XCTAssertTrue(state.filteredSections.isEmpty)
    }

    // MARK: - Bootstrap activates persisted-installed packages

    func testBootstrapActivatesPersistedInstalledPackage() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        // Install once, then simulate a relaunch with a fresh registry over the
        // same storage + defaults.
        let source = try rowsFixture(id: "com.acme.persist")
        let id = try f.registry.sideload(fromDirectory: source)

        let palette2 = CommandPaletteExtensions()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "{}")),
            storeDirectory: f.storeDirectory
        )
        let registry2 = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: f.packagesDirectory,
            paletteExtensions: palette2,
            defaults: f.defaults,
            languageCode: { "en" },
            refreshCommandPalette: {}
        )
        registry2.bootstrap()

        XCTAssertTrue(registry2.isInstalled(id))
        XCTAssertEqual(registry2.installedManifests.map(\.id), [id])
        XCTAssertNotNil(palette2.rowSource(for: rowSourceKey(for: id)),
                        "bootstrap re-registers the palette surface for an installed package")
    }
}
