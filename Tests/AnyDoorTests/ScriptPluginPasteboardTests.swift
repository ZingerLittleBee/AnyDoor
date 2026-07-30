import AppKit
import Foundation
import XCTest
import ScriptPluginRuntime
@testable import AnyDoor
@testable import ClipboardHistory

/// The pasteboard capability must route through the host's real self-write
/// funnel, so a plugin's copy never lands in clipboard history (user story 13).
/// This test wires the runtime's `writePasteboard` to the production
/// module-facing self-write funnel and drives the real v2 monitor.
@MainActor
final class ScriptPluginPasteboardTests: XCTestCase {
    func testPluginCopySuppressesClipboardHistory() async throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ScriptClipboard-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: storeRoot
                .appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x5A, count: 32)
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AnyDoorScript-\(UUID().uuidString)"))
        let funnel = module.pasteboardSelfWrites
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        let spy = ScriptCapabilitySpy()
        // Route the pasteboard capability at the real self-write funnel.
        spy.onPasteboardWrite = { text in
            funnel.write(string: text, to: pasteboard)
        }
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: spy,
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "")),
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
        )
        let runtime = ScriptPluginRuntime(capabilityHost: host, timeout: 1.0)

        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.copier",
            capabilities: ["pasteboard"],
            bundle: #"anydoor.registerPlugin({ action: async function () { await anydoor.copy("plugin-clip"); return "copied"; } });"#
        )
        let id = try runtime.load(fromDirectory: directory)
        let result = try await runtime.performAction(pluginID: id, rowID: "r", actionID: "a")
        XCTAssertEqual(result, .string("copied"))

        // The write reached the pasteboard...
        XCTAssertEqual(pasteboard.string(forType: .string), "plugin-clip")
        XCTAssertEqual(spy.pasteboardWrites, ["plugin-clip"])

        // ...but the funnel suppressed it from clipboard history.
        await monitor.observeForTesting()
        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }
}
