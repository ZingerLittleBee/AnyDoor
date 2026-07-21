import Foundation
import PluginInterface
import XCTest
import ScriptPluginRuntime

/// Per-plugin diagnostics (ticket 023): the runtime appends load refusals,
/// watchdog kills, and capability errors to each plugin's log file, for every
/// Script Plugin regardless of install state. Exercised through the real
/// package boundary and a real `FileScriptPluginLog` on disk — the log file is
/// the observed seam.
@MainActor
final class ScriptPluginDiagnosticsTests: XCTestCase {

    private func makeRuntime(
        log: FileScriptPluginLog,
        transport: any ScriptFetchTransport = RecordingFetchTransport(
            response: ScriptFetchResponse(status: 200, body: "")
        ),
        timeout: TimeInterval = 0.6
    ) -> ScriptPluginRuntime {
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: transport,
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
        )
        return ScriptPluginRuntime(capabilityHost: host, timeout: timeout, diagnostics: log)
    }

    private func makeLogDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-plugin-logs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Load refusal

    func testLoadRefusalIsLogged() async throws {
        let logDir = makeLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = FileScriptPluginLog(directory: logDir)
        let runtime = makeRuntime(log: log)

        // A bundle that never calls registerPlugin — the runtime refuses to bring
        // the context up.
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.noregister",
            bundle: "var x = 1;"
        ))

        _ = try? await runtime.buildRows(pluginID: id, query: "")

        let contents = log.contents(for: id)
        XCTAssertTrue(contents.contains("[loadRefused]"), "log was: \(contents)")
        XCTAssertTrue(contents.contains("registerPlugin"), "log was: \(contents)")
    }

    // MARK: - Watchdog kill

    func testWatchdogKillIsLogged() async throws {
        let logDir = makeLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = FileScriptPluginLog(directory: logDir)
        let runtime = makeRuntime(log: log, timeout: 0.4)

        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.looper",
            bundle: #"anydoor.registerPlugin({ rows: function () { while (true) {} } });"#
        ))

        do {
            _ = try await runtime.buildRows(pluginID: id, query: "")
            XCTFail("expected the looping plugin to be killed")
        } catch let error as ScriptPluginError {
            XCTAssertEqual(error, .timedOut)
        }

        let contents = log.contents(for: id)
        XCTAssertTrue(contents.contains("[watchdogKill]"), "log was: \(contents)")
    }

    // MARK: - Capability error

    func testCapabilityErrorIsLogged() async throws {
        let logDir = makeLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = FileScriptPluginLog(directory: logDir)
        struct Boom: Error {}
        let runtime = makeRuntime(log: log, transport: RecordingFetchTransport(failure: Boom()))

        // The plugin declares fetch, calls it, and the injected transport fails —
        // the host rejects the capability promise, which is logged.
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.fetcher",
            capabilities: ["fetch"],
            bundle: """
            anydoor.registerPlugin({
              rows: async function () {
                await anydoor.fetch("https://example.com");
                return [];
              }
            });
            """
        ))

        _ = try? await runtime.buildRows(pluginID: id, query: "")

        let contents = log.contents(for: id)
        XCTAssertTrue(contents.contains("[capabilityError]"), "log was: \(contents)")
        XCTAssertTrue(contents.contains("fetch failed"), "log was: \(contents)")
    }

    func testBlockedOpenURLSchemeIsLoggedAsCapabilityError() async throws {
        let logDir = makeLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = FileScriptPluginLog(directory: logDir)
        let runtime = makeRuntime(log: log)

        // The plugin declares openURL and hands it a file:// URL; the runtime
        // rejects the capability promise for the off-surface scheme, which is
        // logged like any other capability error.
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.opener",
            capabilities: ["openURL"],
            bundle: """
            anydoor.registerPlugin({
              rows: async function () {
                await anydoor.openURL("file:///etc/hosts");
                return [];
              }
            });
            """
        ))

        _ = try? await runtime.buildRows(pluginID: id, query: "")

        let contents = log.contents(for: id)
        XCTAssertTrue(contents.contains("[capabilityError]"), "log was: \(contents)")
        XCTAssertTrue(contents.contains("openURL"), "log was: \(contents)")
    }

    // MARK: - File routing

    func testEachPluginGetsItsOwnFile() async throws {
        let logDir = makeLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = FileScriptPluginLog(directory: logDir)

        let a = ScriptPluginID("com.acme.a")
        let b = ScriptPluginID("author.plugin")
        log.record(ScriptDiagnosticEvent(pluginID: a, category: .loadRefused, message: "one"))
        log.record(ScriptDiagnosticEvent(pluginID: b, category: .watchdogKill, message: "two"))

        XCTAssertTrue(log.contents(for: a).contains("one"))
        XCTAssertFalse(log.contents(for: a).contains("two"))
        XCTAssertTrue(log.contents(for: b).contains("two"))
        // The author-namespaced id maps to one safe file name.
        XCTAssertNotEqual(
            FileScriptPluginLog.fileURL(for: a, inDirectory: logDir),
            FileScriptPluginLog.fileURL(for: b, inDirectory: logDir)
        )
    }
}
