import AppKit
import ClipboardHistory
import Foundation
import SwiftData
import XCTest
import ScriptPluginRuntime
@testable import AnyDoor

/// The pasteboard capability must route through the host's real self-write
/// funnel, so a plugin's copy never lands in clipboard history (user story 13).
/// This test wires the runtime's `writePasteboard` to the production
/// module-facing self-write funnel and drives the real watcher.
@MainActor
final class ScriptPluginPasteboardTests: XCTestCase {
    private func makeStore() throws -> ClipboardHistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        return store
    }

    func testPluginCopySuppressesClipboardHistory() async throws {
        let store = try makeStore()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AnyDoorScript-\(UUID().uuidString)"))
        let funnel = ClipboardHistoryPasteboardSelfWriteFunnel()
        let watcher = ClipboardWatcher(
            store: store,
            pasteboard: pasteboard,
            selfWrites: funnel,
            sourceProvider: { nil }
        )

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
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)
    }
}
