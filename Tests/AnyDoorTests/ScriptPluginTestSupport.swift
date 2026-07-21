import Foundation
import PluginInterface
import ScriptPluginRuntime

// Test support for the Script Plugin runtime. Fixture packages are real
// directories (manifest.json + bundle.js) written from inline JavaScript, so
// every test exercises the true plugin-package boundary — a directory in, real
// JavaScriptCore underneath.

enum ScriptPluginFixture {
    /// Write a package directory under a fresh temp location and return it.
    /// The manifest fields are supplied directly so tests can also produce
    /// deliberately-malformed manifests.
    static func writePackage(
        id: String,
        name: String = "Fixture",
        description: String = "A fixture plugin.",
        version: String = "1.0.0",
        apiVersion: Int? = 1,
        capabilities: [String] = [],
        bundle: String,
        includeBundle: Bool = true,
        entryPoint: String? = nil
    ) throws -> URL {
        var manifest: [String: Any] = [
            "id": id,
            "name": name,
            "description": description,
            "version": version,
            "capabilities": capabilities,
        ]
        if let apiVersion { manifest["apiVersion"] = apiVersion }
        if let entryPoint { manifest["entryPoint"] = entryPoint }
        return try writeRawPackage(manifest: manifest, bundle: includeBundle ? bundle : nil)
    }

    /// Write a package from a raw manifest dictionary (for validation tests that
    /// need to omit or corrupt fields).
    static func writeRawPackage(manifest: [String: Any], bundle: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-plugin-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        if let bundle {
            let entryPoint = (manifest["entryPoint"] as? String) ?? "bundle.js"
            try bundle.write(
                to: directory.appendingPathComponent(entryPoint),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    /// A unique temp directory usable as a runtime store root.
    static func makeStoreDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-plugin-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Records every capability side effect so tests can assert them, and lets a
/// test point `writePasteboard` at the real clipboard self-write funnel.
@MainActor
final class ScriptCapabilitySpy {
    private(set) var toasts: [(ScriptPluginID, PluginToast)] = []
    private(set) var pasteboardWrites: [String] = []
    private(set) var openedURLs: [URL] = []

    /// Optional override for the pasteboard write (e.g. route to the real funnel).
    var onPasteboardWrite: (@MainActor (String) -> Void)?

    func recordToast(_ id: ScriptPluginID, _ toast: PluginToast) {
        toasts.append((id, toast))
    }

    func recordOpenURL(_ url: URL) {
        openedURLs.append(url)
    }

    func recordPasteboard(_ text: String) {
        pasteboardWrites.append(text)
        onPasteboardWrite?(text)
    }
}

/// A `ScriptFetchTransport` that records requests and replays a fixed response —
/// the single injected external boundary; nothing else in the runtime is mocked.
actor RecordingFetchTransport: ScriptFetchTransport {
    private(set) var requests: [ScriptFetchRequest] = []
    private let response: ScriptFetchResponse
    private let error: Error?

    init(response: ScriptFetchResponse) {
        self.response = response
        self.error = nil
    }

    init(failure: Error) {
        self.response = ScriptFetchResponse(status: 0, body: "")
        self.error = failure
    }

    func fetch(_ request: ScriptFetchRequest) async throws -> ScriptFetchResponse {
        requests.append(request)
        if let error { throw error }
        return response
    }
}

@MainActor
enum ScriptRuntimeHarness {
    /// Build a capability host wired to a spy and an injected transport.
    static func makeCapabilityHost(
        spy: ScriptCapabilitySpy,
        transport: any ScriptFetchTransport,
        storeDirectory: URL
    ) -> ScriptCapabilityHost {
        ScriptCapabilityHost(
            transport: transport,
            storeDirectory: storeDirectory,
            presentToast: { id, toast in spy.recordToast(id, toast) },
            writePasteboard: { text in spy.recordPasteboard(text) },
            openURL: { url in spy.recordOpenURL(url) }
        )
    }
}
