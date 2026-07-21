import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// The dev-vs-installed error presentation policy (ticket 023): a Dev Plugin
/// author sees the error detail (message and stack); a normally installed plugin
/// keeps the plain generic inline string. Covered first as a pure seam, then end
/// to end through the real runtime and a throwing fixture.
@MainActor
final class ScriptPluginErrorPresentationTests: XCTestCase {

    // MARK: - Pure policy

    func testInstalledPluginShowsGenericStringNotDetail() {
        let error = ScriptPluginError.invocationFailed("boom\nrows@bundle.js:2")
        let shown = ScriptPluginErrorPresentation.message(
            for: error, surfacesDetail: false, generic: "generic message"
        )
        XCTAssertEqual(shown, "generic message")
        XCTAssertFalse(shown.contains("boom"))
    }

    func testDevPluginShowsErrorDetail() {
        let error = ScriptPluginError.invocationFailed("boom\nrows@bundle.js:2")
        let shown = ScriptPluginErrorPresentation.message(
            for: error, surfacesDetail: true, generic: "generic message"
        )
        XCTAssertTrue(shown.contains("boom"))
        XCTAssertTrue(shown.contains("bundle.js"), "the stack must reach the author")
    }

    func testDetailWordsEachErrorCase() {
        XCTAssertEqual(ScriptPluginErrorPresentation.detail(of: ScriptPluginError.timedOut),
                       "Invocation timed out (watchdog killed the context).")
        XCTAssertEqual(ScriptPluginErrorPresentation.detail(of: ScriptPluginError.pluginNotRegistered),
                       "Plugin never called anydoor.registerPlugin.")
    }

    // MARK: - Row source end to end

    private func makeRuntime() -> ScriptPluginRuntime {
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
        )
        return ScriptPluginRuntime(capabilityHost: host, timeout: 0.6)
    }

    func testInstalledRowSourceFailsGenericDevSourceFailsWithDetail() async throws {
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.throws",
            bundle: #"anydoor.registerPlugin({ rows: function () { throw new Error("kaboom"); } });"#
        ))

        let installed = ScriptPluginRowSource(
            scriptID: id, runtime: runtime, sectionTitle: "Fixture", surfacesErrorDetail: false
        )
        await installed.refresh()
        guard case .failed(let installedMessage) = installed.loadState else {
            return XCTFail("expected a failed state, got \(installed.loadState)")
        }
        XCTAssertFalse(installedMessage.contains("kaboom"),
                       "an installed plugin must not leak the plugin's error text")

        let dev = ScriptPluginRowSource(
            scriptID: id, runtime: runtime, sectionTitle: "Fixture", surfacesErrorDetail: true
        )
        await dev.refresh()
        guard case .failed(let devMessage) = dev.loadState else {
            return XCTFail("expected a failed state, got \(dev.loadState)")
        }
        XCTAssertTrue(devMessage.contains("kaboom"),
                      "a Dev Plugin must surface the error detail to the author")
    }
}
