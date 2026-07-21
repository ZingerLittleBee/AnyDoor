import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// Dev Plugin registration (ticket 023): behind the developer-mode switch a
/// local directory is loaded in place (never copied), the development directory
/// is never modified by the host, and removing the registration removes the
/// surfaces while leaving the directory intact. Auto-reload has its own suite.
@MainActor
final class ScriptDevPluginRegistrationTests: XCTestCase {

    private struct Fixture {
        let registry: ScriptPluginRegistry
        let palette: CommandPaletteExtensions
        let packagesDirectory: URL
        let defaults: UserDefaults
        let teardown: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "ScriptDevPluginRegistrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: storeDirectory
        )
        let palette = CommandPaletteExtensions()
        let registry = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: packagesDirectory,
            paletteExtensions: palette,
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: {}
        )
        return Fixture(
            registry: registry,
            palette: palette,
            packagesDirectory: packagesDirectory,
            defaults: defaults,
            teardown: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: packagesDirectory)
                try? FileManager.default.removeItem(at: storeDirectory)
            }
        )
    }

    private func rowSourceKey(for id: ScriptPluginID) -> PluginRowSourceKey {
        PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:" + id.rawValue),
            localID: ScriptPluginRowSource.localID
        )
    }

    private func rowsFixture(id: String) throws -> URL {
        try ScriptPluginFixture.writePackage(
            id: id,
            name: "Dev Fixture",
            bundle: #"anydoor.registerPlugin({ rows: function () { return [{ id: "a", title: "Alpha" }]; } });"#
        )
    }

    /// A stable snapshot of every file's bytes under a directory, for asserting
    /// the host never modifies the development directory.
    private func snapshot(of directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) {
                result[url.lastPathComponent] = data
            }
        }
        return result
    }

    // MARK: - Developer-mode gating

    func testRegisterRefusedWhenDeveloperModeOff() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        XCTAssertFalse(f.registry.isDeveloperModeEnabled)

        let dir = try rowsFixture(id: "com.acme.dev")
        XCTAssertThrowsError(try f.registry.registerDevPlugin(fromDirectory: dir)) { error in
            XCTAssertEqual(error as? ScriptDevPluginError, .developerModeDisabled)
        }
        XCTAssertTrue(f.registry.devPluginManifests.isEmpty)
    }

    // MARK: - In-place load, no copy

    func testRegisterLoadsInPlaceWithoutCopying() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)

        let dir = try rowsFixture(id: "com.acme.dev")
        let before = snapshot(of: dir)
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)

        XCTAssertTrue(f.registry.isDevPlugin(id))
        XCTAssertEqual(f.registry.devPluginManifests.map(\.id), [id])
        XCTAssertEqual(f.registry.devPluginDirectory(for: id)?.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertNotNil(f.palette.rowSource(for: rowSourceKey(for: id)),
                        "registration publishes the palette row source")

        // Nothing was copied into app storage.
        let copied = (try? FileManager.default.contentsOfDirectory(atPath: f.packagesDirectory.path)) ?? []
        XCTAssertTrue(copied.isEmpty, "a Dev Plugin loads in place; nothing is copied")

        // The development directory is byte-for-byte unchanged.
        XCTAssertEqual(snapshot(of: dir), before, "the host must never modify the dev directory")

        // The rows build in place through the real runtime.
        let source = try XCTUnwrap(f.registry.rowSource(for: id))
        await source.refresh()
        XCTAssertEqual(source.rows().map(\.title), ["Alpha"])
    }

    // MARK: - Duplicate id refusals across kinds

    func testRegisterRefusesDuplicateOfInstalledPackage() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)

        let installedDir = try rowsFixture(id: "com.acme.shared")
        let id = try f.registry.sideload(fromDirectory: installedDir)

        let devDir = try rowsFixture(id: "com.acme.shared")
        XCTAssertThrowsError(try f.registry.registerDevPlugin(fromDirectory: devDir)) { error in
            XCTAssertEqual(error as? ScriptPluginError, .duplicateID(id))
        }
        XCTAssertFalse(f.registry.isDevPlugin(id))
    }

    func testSideloadRefusesDuplicateOfDevPlugin() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)

        let devDir = try rowsFixture(id: "com.acme.shared")
        let id = try f.registry.registerDevPlugin(fromDirectory: devDir)

        let installedDir = try rowsFixture(id: "com.acme.shared")
        XCTAssertThrowsError(try f.registry.sideload(fromDirectory: installedDir)) { error in
            XCTAssertEqual(error as? ScriptPluginError, .duplicateID(id))
        }
        XCTAssertTrue(f.registry.installedManifests.isEmpty)
    }

    // MARK: - Removal leaves the directory intact

    func testUnregisterRemovesSurfacesButNeverTouchesDirectory() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)

        let dir = try rowsFixture(id: "com.acme.dev")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)
        let before = snapshot(of: dir)

        f.registry.unregisterDevPlugin(id)

        XCTAssertFalse(f.registry.isDevPlugin(id))
        XCTAssertTrue(f.registry.devPluginManifests.isEmpty)
        XCTAssertNil(f.palette.rowSource(for: rowSourceKey(for: id)))
        XCTAssertNil(f.registry.rowSource(for: id))
        // The directory still exists, byte-for-byte unchanged.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(snapshot(of: dir), before, "removal must never modify the dev directory")
    }

    // MARK: - Toggling developer mode

    func testDisablingDeveloperModeDeactivatesButKeepsRegistration() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)

        let dir = try rowsFixture(id: "com.acme.dev")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)
        XCTAssertNotNil(f.palette.rowSource(for: rowSourceKey(for: id)))

        // Turning developer mode off tears the surface down…
        f.registry.setDeveloperMode(false)
        XCTAssertNil(f.palette.rowSource(for: rowSourceKey(for: id)))
        XCTAssertTrue(f.registry.devPluginManifests.isEmpty)

        // …but the registration is retained, so re-enabling restores it.
        f.registry.setDeveloperMode(true)
        XCTAssertNotNil(f.palette.rowSource(for: rowSourceKey(for: id)))
        XCTAssertEqual(f.registry.devPluginManifests.map(\.id), [id])
    }

    // MARK: - Bootstrap restores registrations only behind the switch

    func testBootstrapRestoresDevPluginsWhenDeveloperModeOn() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)
        let dir = try rowsFixture(id: "com.acme.persist")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)

        // Relaunch: a fresh registry over the same defaults.
        let palette2 = CommandPaletteExtensions()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
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

        XCTAssertTrue(registry2.isDevPlugin(id))
        XCTAssertNotNil(palette2.rowSource(for: rowSourceKey(for: id)))
    }

    func testBootstrapSkipsDevPluginsWhenDeveloperModeOff() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.setDeveloperMode(true)
        let dir = try rowsFixture(id: "com.acme.persist")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)
        // Author turns developer mode off before quitting.
        f.registry.setDeveloperMode(false)

        let palette2 = CommandPaletteExtensions()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
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

        // No surface exists with developer mode off, though the registration
        // persists for the next time it is turned on.
        XCTAssertNil(palette2.rowSource(for: rowSourceKey(for: id)))
        XCTAssertTrue(registry2.devPluginManifests.isEmpty)
        registry2.setDeveloperMode(true)
        XCTAssertNotNil(palette2.rowSource(for: rowSourceKey(for: id)))
    }
}
