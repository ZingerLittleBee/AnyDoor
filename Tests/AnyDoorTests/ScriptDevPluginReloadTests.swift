import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// Dev Plugin auto-reload (ticket 023): editing a registered development
/// directory's bundle reloads the plugin's context automatically, so an edit
/// shows up in already-visible palette rows in seconds without reinstalling.
/// Exercised with real file writes and the real FSEvents watcher (allowing for
/// the debounce), through real JavaScriptCore.
@MainActor
final class ScriptDevPluginReloadTests: XCTestCase {

    private struct Fixture {
        let registry: ScriptPluginRegistry
        let log: FileScriptPluginLog
        let teardown: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "ScriptDevPluginReloadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-logs-\(UUID().uuidString)", isDirectory: true)
        let log = FileScriptPluginLog(directory: logDirectory)
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: storeDirectory
        )
        let registry = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host, diagnostics: log),
            packagesDirectory: packagesDirectory,
            diagnostics: log,
            paletteExtensions: CommandPaletteExtensions(),
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: {}
        )
        registry.setDeveloperMode(true)
        return Fixture(
            registry: registry,
            log: log,
            teardown: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: packagesDirectory)
                try? FileManager.default.removeItem(at: storeDirectory)
                try? FileManager.default.removeItem(at: logDirectory)
            }
        )
    }

    private func writeDevPackage(id: String, rowTitle: String) throws -> URL {
        try ScriptPluginFixture.writePackage(
            id: id,
            name: "Reload Fixture",
            bundle: """
            anydoor.registerPlugin({
              rows: function () { return [{ id: "a", title: "\(rowTitle)" }]; }
            });
            """
        )
    }

    /// Poll a condition on the main actor up to `timeout`, yielding so the
    /// watcher's debounced reload and the async row fetch can run.
    private func waitUntil(
        timeout: TimeInterval = 6,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Bundle edit reloads visible rows

    func testEditingBundleReloadsVisibleRows() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let dir = try writeDevPackage(id: "com.acme.reload", rowTitle: "Alpha")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)
        let source = try XCTUnwrap(f.registry.rowSource(for: id))

        await source.refresh()
        XCTAssertEqual(source.rows().map(\.title), ["Alpha"])

        // Edit the bundle on disk the way esbuild would rewrite it.
        let bundle = dir.appendingPathComponent("bundle.js")
        try """
        anydoor.registerPlugin({
          rows: function () { return [{ id: "a", title: "Gamma" }]; }
        });
        """.write(to: bundle, atomically: true, encoding: .utf8)

        // The watcher reloads the context automatically; the visible rows update
        // without any reinstall or manual refresh.
        await waitUntil { source.rows().map(\.title) == ["Gamma"] }
        XCTAssertEqual(source.rows().map(\.title), ["Gamma"],
                       "auto-reload must update already-visible palette rows")
    }

    // MARK: - A broken reload surfaces to the author and logs a refusal

    func testBrokenManifestOnReloadIsRefusedAndLogged() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let dir = try writeDevPackage(id: "com.acme.breakable", rowTitle: "Alpha")
        let id = try f.registry.registerDevPlugin(fromDirectory: dir)
        let source = try XCTUnwrap(f.registry.rowSource(for: id))
        await source.refresh()
        XCTAssertEqual(source.rows().map(\.title), ["Alpha"])

        // Corrupt the manifest — the reload cannot validate the package.
        try "{ not json".write(
            to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        await waitUntil {
            if case .failed = source.loadState { return true }
            return false
        }
        guard case .failed(let message) = source.loadState else {
            return XCTFail("expected the broken reload to fail the source, got \(source.loadState)")
        }
        // The author sees the detail, and the refusal is in the plugin's log.
        XCTAssertFalse(message.isEmpty)
        await waitUntil { f.log.contents(for: id).contains("[loadRefused]") }
        XCTAssertTrue(f.log.contents(for: id).contains("[loadRefused]"),
                      "a dev reload refusal must append to the plugin's log file")
    }
}
