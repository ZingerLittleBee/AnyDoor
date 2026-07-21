import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// Exercises `ScriptPluginRowSource` — the async bridge onto the palette's
/// `PluginRowSource` contract — through the real runtime and fixture packages
/// (the engine is never mocked; only the fetch transport is injectable). Covers
/// the load-state, Detail, Argument, and failure-toast behaviors ticket 022
/// adds, at the row-source seam rather than through the SwiftUI palette.
@MainActor
final class ScriptPluginRowSourceTests: XCTestCase {

    private func makeRuntime(spy: ScriptCapabilitySpy = ScriptCapabilitySpy()) -> ScriptPluginRuntime {
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: spy,
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
        )
        return ScriptPluginRuntime(capabilityHost: host, timeout: 0.6)
    }

    private func makeSource(
        runtime: ScriptPluginRuntime,
        id: ScriptPluginID,
        onActionError: @escaping @MainActor (ScriptPluginError) -> Void = { _ in }
    ) -> ScriptPluginRowSource {
        ScriptPluginRowSource(
            scriptID: id, runtime: runtime, sectionTitle: "Fixture",
            onActionError: onActionError
        )
    }

    // MARK: - Load state

    func testRefreshReportsReadyAndCachesRows() async throws {
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.rows",
            bundle: #"anydoor.registerPlugin({ rows: function () { return [{ id: "a", title: "Alpha" }]; } });"#
        ))
        let source = makeSource(runtime: runtime, id: id)

        // Starts loading (no fetch has completed yet).
        XCTAssertEqual(source.loadState, .loading)

        await source.refresh()
        XCTAssertEqual(source.loadState, .ready)
        XCTAssertEqual(source.rows().map(\.title), ["Alpha"])
    }

    func testRefreshReportsFailedWhenRowsThrow() async throws {
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.throws",
            bundle: #"anydoor.registerPlugin({ rows: function () { throw new Error("boom"); } });"#
        ))
        let source = makeSource(runtime: runtime, id: id)

        await source.refresh()
        guard case .failed = source.loadState else {
            return XCTFail("expected a failed load state, got \(source.loadState)")
        }
        XCTAssertTrue(source.rows().isEmpty)
    }

    // MARK: - Detail

    func testLoadDetailReturnsMarkdown() async throws {
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.detail",
            bundle: """
            anydoor.registerPlugin({
              rows: function () { return [{ id: "a", title: "A", action: { type: "detail" } }]; },
              detail: function (rowID) { return "# Post " + rowID; }
            });
            """
        ))
        let source = makeSource(runtime: runtime, id: id)

        let result = await source.loadDetail(id: "a")
        XCTAssertEqual(result, .markdown("# Post a"))
    }

    func testLoadDetailReturnsFailureWhenDetailThrows() async throws {
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.detailthrows",
            bundle: """
            anydoor.registerPlugin({
              rows: function () { return [{ id: "a", title: "A", action: { type: "detail" } }]; },
              detail: function () { throw new Error("nope"); }
            });
            """
        ))
        let source = makeSource(runtime: runtime, id: id)

        guard case .failure = await source.loadDetail(id: "a") else {
            return XCTFail("expected a Detail failure result")
        }
    }

    // MARK: - Argument passing

    func testPerformRowArgumentReachesPluginAction() async throws {
        let spy = ScriptCapabilitySpy()
        let runtime = makeRuntime(spy: spy)
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.search",
            capabilities: ["toast"],
            bundle: """
            anydoor.registerPlugin({
              rows: function () { return [{ id: "search", title: "Search", action: { type: "argument" } }]; },
              action: async function (rowID, actionID, argument) { await anydoor.toast("info", argument); }
            });
            """
        ))
        let source = makeSource(runtime: runtime, id: id)

        await source.performRow(id: "search", argument: "anydoor")

        XCTAssertEqual(spy.toasts.count, 1)
        guard case .info("anydoor") = spy.toasts.first?.1 else {
            return XCTFail("expected the argument to reach the plugin action")
        }
    }

    // MARK: - Action failure toast

    func testFailingActionReportsFailureToInjectedHandler() async throws {
        var errors: [ScriptPluginError] = []
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.failaction",
            bundle: #"anydoor.registerPlugin({ action: function () { throw new Error("action boom"); } });"#
        ))
        let source = makeSource(runtime: runtime, id: id, onActionError: { errors.append($0) })

        await source.performRow(id: "r")

        XCTAssertEqual(errors.count, 1)
        guard case .invocationFailed(let message) = errors.first else {
            return XCTFail("expected invocationFailed, got \(String(describing: errors.first))")
        }
        XCTAssertTrue(message.contains("action boom"))
    }

    func testActionAfterUnloadIsDroppedWithoutFailureToast() async throws {
        var errors: [ScriptPluginError] = []
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: try ScriptPluginFixture.writePackage(
            id: "com.acme.gone",
            bundle: #"anydoor.registerPlugin({ action: function () { return "ok"; } });"#
        ))
        let source = makeSource(runtime: runtime, id: id, onActionError: { errors.append($0) })

        // Uninstall unloads the context; a row committed just before must not
        // flash a spurious failure toast.
        runtime.unload(id)
        await source.performRow(id: "r")

        XCTAssertTrue(errors.isEmpty, "an action for an unloaded plugin is dropped silently")
    }
}
