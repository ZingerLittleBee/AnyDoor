import Foundation
import PluginInterface
import XCTest
import ScriptPluginRuntime

/// Exercises the runtime through the package boundary with real JavaScriptCore.
/// A short watchdog timeout keeps the kill tests fast.
@MainActor
final class ScriptPluginRuntimeTests: XCTestCase {
    private func makeRuntime(
        spy: ScriptCapabilitySpy = ScriptCapabilitySpy(),
        transport: any ScriptFetchTransport = RecordingFetchTransport(
            response: ScriptFetchResponse(status: 200, body: "")
        ),
        storeDirectory: URL? = nil,
        timeout: TimeInterval = 0.6
    ) -> ScriptPluginRuntime {
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: spy,
            transport: transport,
            storeDirectory: storeDirectory ?? ScriptPluginFixture.makeStoreDirectory()
        )
        return ScriptPluginRuntime(capabilityHost: host, timeout: timeout)
    }

    // MARK: - Rows + Detail

    func testLoadProducesRowsAndDetail() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.list",
            bundle: """
            anydoor.registerPlugin({
              rows: function (query) {
                return [
                  { id: "a", title: "Alpha " + query, subtitle: "first", symbol: "star", commit: "stayOpen" },
                  { id: "b", title: "Beta", commit: "closeThenAct" }
                ];
              },
              detail: function (rowId) { return "# Detail " + rowId; }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)

        let rows = try await runtime.buildRows(pluginID: id, query: "q")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "a")
        XCTAssertEqual(rows[0].title, "Alpha q")
        XCTAssertEqual(rows[0].subtitle, "first")
        XCTAssertEqual(rows[0].symbol, "star")
        XCTAssertEqual(rows[0].commit, .stayOpen)
        XCTAssertEqual(rows[1].id, "b")
        XCTAssertEqual(rows[1].commit, .closeThenAct)

        let detail = try await runtime.buildDetail(pluginID: id, rowID: "a")
        XCTAssertEqual(detail, "# Detail a")
    }

    // MARK: - Row action declarations (the `action` union)

    func testRowActionUnionDecodesEverySemantic() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.actions",
            bundle: """
            anydoor.registerPlugin({
              rows: function () {
                return [
                  { id: "detail", title: "Detail", action: { type: "detail" } },
                  { id: "open", title: "Open", action: { type: "openURL", url: "https://anydoor.dev" } },
                  { id: "copy", title: "Copy", action: { type: "copy", text: "clip" } },
                  { id: "arg", title: "Arg", action: { type: "argument" } },
                  { id: "run", title: "Run", action: { type: "run" } },
                  { id: "runOpen", title: "RunOpen", action: { type: "run", close: false } }
                ];
              }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let rows = try await runtime.buildRows(pluginID: id, query: "")

        XCTAssertEqual(rows.map(\.commit), [
            .pushDetail,
            .openURL("https://anydoor.dev"),
            .copy("clip"),
            .enterArgument,
            .closeThenAct,
            .stayOpen,
        ])
    }

    func testLegacyCommitStringStillDecodes() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.legacy",
            bundle: """
            anydoor.registerPlugin({
              rows: function () {
                return [
                  { id: "a", title: "A", commit: "stayOpen" },
                  { id: "b", title: "B", commit: "closeThenAct" },
                  { id: "c", title: "C" }
                ];
              }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let rows = try await runtime.buildRows(pluginID: id, query: "")
        XCTAssertEqual(rows.map(\.commit), [.stayOpen, .closeThenAct, .stayOpen])
    }

    func testOpenURLActionMissingURLIsTypedDecodeError() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.badopen",
            bundle: #"anydoor.registerPlugin({ rows: function () { return [{ id: "x", title: "X", action: { type: "openURL" } }]; } });"#
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        do {
            _ = try await runtime.buildRows(pluginID: id, query: "")
            XCTFail("expected a decode error")
        } catch let error as ScriptPluginError {
            guard case .resultDecodingFailed = error else {
                return XCTFail("expected resultDecodingFailed, got \(error)")
            }
        }
    }

    func testActionReceivesArgumentAsThirdParameter() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.arg",
            bundle: """
            anydoor.registerPlugin({
              action: function (rowID, actionID, argument) {
                return rowID + "|" + actionID + "|" + argument;
              }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let result = try await runtime.performAction(
            pluginID: id, rowID: "search", actionID: "default", argument: "anydoor"
        )
        XCTAssertEqual(result, .string("search|default|anydoor"))
    }

    // MARK: - Throwing fixture

    func testThrowingFixtureYieldsTypedErrorNotCrash() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.throws",
            bundle: #"anydoor.registerPlugin({ rows: function () { throw new Error("boom"); } });"#
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)

        do {
            _ = try await runtime.buildRows(pluginID: id, query: "")
            XCTFail("expected a thrown error")
        } catch let error as ScriptPluginError {
            guard case let .invocationFailed(message) = error else {
                return XCTFail("expected invocationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("boom"), "message was \(message)")
        }
    }

    // MARK: - Watchdog kill + recovery + sibling isolation

    func testWatchdogKillsLoopRecoversAndSiblingUnaffected() async throws {
        let looper = try ScriptPluginFixture.writePackage(
            id: "com.example.looper",
            bundle: """
            anydoor.registerPlugin({
              rows: function (query) {
                if (query === "loop") { while (true) {} }
                return [{ id: "ok", title: "recovered", commit: "stayOpen" }];
              }
            });
            """
        )
        let sibling = try ScriptPluginFixture.writePackage(
            id: "com.example.sibling",
            bundle: #"anydoor.registerPlugin({ rows: function () { return [{ id: "s", title: "sibling", commit: "stayOpen" }]; } });"#
        )
        let runtime = makeRuntime(timeout: 0.5)
        let looperID = try runtime.load(fromDirectory: looper)
        let siblingID = try runtime.load(fromDirectory: sibling)

        // The sibling runs concurrently with the looping plugin's runaway and
        // must complete on its own queue, unaffected.
        async let loopResult: [PluginRowDescriptor] = runtime.buildRows(pluginID: looperID, query: "loop")
        async let siblingResult: [PluginRowDescriptor] = runtime.buildRows(pluginID: siblingID, query: "")

        let siblingRows = try await siblingResult
        XCTAssertEqual(siblingRows.map(\.title), ["sibling"])

        do {
            _ = try await loopResult
            XCTFail("expected the looping plugin to be killed")
        } catch let error as ScriptPluginError {
            XCTAssertEqual(error, .timedOut)
        }

        // The killed plugin recovers on a fresh context at the next invocation.
        let recovered = try await runtime.buildRows(pluginID: looperID, query: "fine")
        XCTAssertEqual(recovered.map(\.title), ["recovered"])
    }

    // MARK: - Capability gating

    func testUndeclaredCapabilitiesAreAbsent() async throws {
        // Declares nothing: no capability object exists on `anydoor`.
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.nocaps",
            capabilities: [],
            bundle: """
            anydoor.registerPlugin({
              rows: function () {
                var probe = [typeof anydoor.fetch, typeof anydoor.store, typeof anydoor.toast,
                             typeof anydoor.copy, typeof anydoor.delay, typeof anydoor.openURL].join(",");
                return [{ id: "probe", title: probe, commit: "stayOpen" }];
              }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let rows = try await runtime.buildRows(pluginID: id, query: "")
        XCTAssertEqual(rows.first?.title, "undefined,undefined,undefined,undefined,undefined,undefined")
    }

    func testDeclaredCapabilitiesArePresent() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.somecaps",
            capabilities: ["fetch", "toast"],
            bundle: """
            anydoor.registerPlugin({
              rows: function () {
                var present = [typeof anydoor.fetch, typeof anydoor.toast].join(",");
                var absent = [typeof anydoor.store, typeof anydoor.delay].join(",");
                return [{ id: "p", title: present + "|" + absent, commit: "stayOpen" }];
              }
            });
            """
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let rows = try await runtime.buildRows(pluginID: id, query: "")
        XCTAssertEqual(rows.first?.title, "function,function|undefined,undefined")
    }

    // MARK: - fetch (injected transport boundary only)

    func testFetchGoesThroughInjectedTransport() async throws {
        let transport = RecordingFetchTransport(
            response: ScriptFetchResponse(status: 201, headers: ["X-Test": "1"], body: "PAYLOAD")
        )
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.fetcher",
            capabilities: ["fetch"],
            bundle: """
            anydoor.registerPlugin({
              action: async function (rowId, actionId) {
                var res = await anydoor.fetch("https://example.com/api", { method: "POST", body: "hi" });
                return { status: res.status, ok: res.ok, body: res.body };
              }
            });
            """
        )
        let runtime = makeRuntime(transport: transport)
        let id = try runtime.load(fromDirectory: directory)

        let result = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "a")
        guard case let .object(fields) = result else { return XCTFail("expected object, got \(result)") }
        XCTAssertEqual(fields["status"], .number(201))
        XCTAssertEqual(fields["ok"], .bool(true))
        XCTAssertEqual(fields["body"], .string("PAYLOAD"))

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, "https://example.com/api")
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.body, "hi")
    }

    // MARK: - toast / openURL / delay

    func testToastCapabilityReachesHost() async throws {
        let spy = ScriptCapabilitySpy()
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.toaster",
            capabilities: ["toast"],
            bundle: #"anydoor.registerPlugin({ action: async function () { await anydoor.toast("success", "done!"); return "ok"; } });"#
        )
        let runtime = makeRuntime(spy: spy)
        let id = try runtime.load(fromDirectory: directory)
        _ = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "a")

        XCTAssertEqual(spy.toasts.count, 1)
        XCTAssertEqual(spy.toasts.first?.0, id)
        guard case .success("done!") = spy.toasts.first?.1 else {
            return XCTFail("expected success toast, got \(String(describing: spy.toasts.first?.1))")
        }
    }

    func testOpenURLCapabilityReachesHost() async throws {
        let spy = ScriptCapabilitySpy()
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.opener",
            capabilities: ["openURL"],
            bundle: #"anydoor.registerPlugin({ action: async function () { await anydoor.openURL("https://anydoor.dev/x"); return "ok"; } });"#
        )
        let runtime = makeRuntime(spy: spy)
        let id = try runtime.load(fromDirectory: directory)
        _ = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "a")

        XCTAssertEqual(spy.openedURLs.map(\.absoluteString), ["https://anydoor.dev/x"])
    }

    func testDelayCapabilityResolves() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.delayer",
            capabilities: ["delay"],
            bundle: #"anydoor.registerPlugin({ action: async function () { await anydoor.delay(15); return "awoke"; } });"#
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        let result = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "a")
        XCTAssertEqual(result, .string("awoke"))
    }

    // MARK: - Key-value store persistence across teardown

    func testStoreDataSurvivesRuntimeTeardownAndRecreation() async throws {
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.persist",
            capabilities: ["store"],
            bundle: """
            anydoor.registerPlugin({
              action: async function (rowId, actionId) {
                if (actionId === "write") { await anydoor.store.set("count", 42); return "written"; }
                if (actionId === "read") { return await anydoor.store.get("count"); }
                return null;
              }
            });
            """
        )

        // First runtime writes, then is torn down entirely.
        do {
            let runtime = makeRuntime(storeDirectory: storeDirectory)
            let id = try runtime.load(fromDirectory: directory)
            let written = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "write")
            XCTAssertEqual(written, .string("written"))
            runtime.unload(id)
        }

        // A brand-new runtime over the same store directory finds the data.
        let runtime2 = makeRuntime(storeDirectory: storeDirectory)
        let id2 = try runtime2.load(fromDirectory: directory)
        let read = try await runtime2.performAction(pluginID: id2, rowID: "r", actionID: "read")
        XCTAssertEqual(read, .number(42))
    }

    // MARK: - Load errors

    func testDuplicateIDIsRejectedWithoutStateChange() throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.dup",
            bundle: "anydoor.registerPlugin({});"
        )
        let other = try ScriptPluginFixture.writePackage(
            id: "com.example.dup",
            bundle: "anydoor.registerPlugin({});"
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        XCTAssertEqual(runtime.loadedIDs, [id])

        XCTAssertThrowsError(try runtime.load(fromDirectory: other)) { error in
            XCTAssertEqual(error as? ScriptPluginError, .duplicateID(id))
        }
        // The already-loaded plugin is untouched.
        XCTAssertEqual(runtime.loadedIDs, [id])
    }

    func testInvokingUnloadedPluginThrows() async {
        let runtime = makeRuntime()
        do {
            _ = try await runtime.buildRows(pluginID: ScriptPluginID("nope"), query: "")
            XCTFail("expected notLoaded")
        } catch let error as ScriptPluginError {
            XCTAssertEqual(error, .notLoaded(ScriptPluginID("nope")))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Bad results / registration

    func testMissingEntryPointIsTyped() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.norows",
            bundle: #"anydoor.registerPlugin({ detail: function () { return "x"; } });"#
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        do {
            _ = try await runtime.buildRows(pluginID: id, query: "")
            XCTFail("expected entryPointMissing")
        } catch let error as ScriptPluginError {
            XCTAssertEqual(error, .entryPointMissing("rows"))
        }
    }

    func testUnregisteredPluginIsTyped() async throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.unregistered",
            bundle: "var noop = 1;" // never calls registerPlugin
        )
        let runtime = makeRuntime()
        let id = try runtime.load(fromDirectory: directory)
        do {
            _ = try await runtime.buildRows(pluginID: id, query: "")
            XCTFail("expected pluginNotRegistered")
        } catch let error as ScriptPluginError {
            XCTAssertEqual(error, .pluginNotRegistered)
        }
    }
}
