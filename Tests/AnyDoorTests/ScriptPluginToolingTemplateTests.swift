import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest

/// End-to-end proof that the npm tooling (ticket 024) produces a package that
/// loads and runs on the real Script Plugin runtime.
///
/// The fixture under `Fixtures/ScriptToolingTemplate/` is the committed, prebuilt
/// output of `@anydoor-dev/create-plugin`'s default template (regenerated with
/// `tooling/scripts/refresh-fixture.mjs`). This test loads that manifest + bundle
/// through the real `ScriptPluginRuntime` — real JavaScriptCore underneath — so
/// `swift test` needs no Node or pnpm, yet the generated bundle is exercised for
/// real: rows, markdown Detail, and the openURL row action.
@MainActor
final class ScriptPluginToolingTemplateTests: XCTestCase {
    /// A canned Hacker News Algolia response so the template's single `fetch`
    /// resolves deterministically through the injected transport boundary.
    private static let algoliaJSON = """
    {
      "hits": [
        {
          "objectID": "1001",
          "title": "Show HN: AnyDoor Script Plugins",
          "url": "https://anydoor.dev/plugins",
          "author": "bybee",
          "points": 128,
          "num_comments": 42
        },
        {
          "objectID": "1002",
          "title": "A deep dive into JavaScriptCore",
          "url": "https://example.com/jsc",
          "author": "hacker",
          "points": 64,
          "num_comments": 13
        }
      ]
    }
    """

    /// Reconstruct the committed package directory from the test bundle. SwiftPM's
    /// `.process` rule may flatten the fixture subdirectory, so locate each file
    /// by name (with subdirectory fallbacks) and stage a real package directory.
    private func stageTemplatePackage() throws -> URL {
        let manifestURL = try resource(named: "manifest", extension: "json")
        let bundleURL = try resource(named: "bundle", extension: "js")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-tooling-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifestURL, to: directory.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: bundleURL, to: directory.appendingPathComponent("bundle.js"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func resource(named name: String, extension ext: String) throws -> URL {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/ScriptToolingTemplate"),
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "ScriptToolingTemplate"),
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: ext),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw XCTSkip("fixture \(name).\(ext) not found in the test bundle")
        }
        return url
    }

    private func makeRuntime(spy: ScriptCapabilitySpy) -> ScriptPluginRuntime {
        let transport = RecordingFetchTransport(
            response: ScriptFetchResponse(status: 200, body: Self.algoliaJSON)
        )
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: spy,
            transport: transport,
            storeDirectory: ScriptPluginFixture.makeStoreDirectory()
        )
        return ScriptPluginRuntime(capabilityHost: host, timeout: 5)
    }

    func testGeneratedTemplateManifestLoads() throws {
        let directory = try stageTemplatePackage()
        let runtime = makeRuntime(spy: ScriptCapabilitySpy())
        let id = try runtime.load(fromDirectory: directory)

        let manifest = try XCTUnwrap(runtime.manifest(for: id))
        XCTAssertEqual(manifest.id.rawValue, "dev.anydoor.hn-top")
        XCTAssertEqual(manifest.apiVersion, 1)
        XCTAssertEqual(manifest.capabilities, [.fetch, .openURL])
        // The template ships a localized name; the base name is the fallback.
        XCTAssertEqual(manifest.displayName(forLanguageCode: "zh"), "Hacker News 热门")
        XCTAssertEqual(manifest.displayName(forLanguageCode: "en"), "Hacker News Top")
    }

    func testGeneratedTemplateRendersRowsDetailAndAction() async throws {
        let directory = try stageTemplatePackage()
        let spy = ScriptCapabilitySpy()
        let runtime = makeRuntime(spy: spy)
        let id = try runtime.load(fromDirectory: directory)

        // rows(): fetch -> list. The template maps each story to a Detail row.
        let rows = try await runtime.buildRows(pluginID: id, query: "")
        XCTAssertEqual(rows.map(\.id), ["1001", "1002"])
        XCTAssertEqual(rows.first?.title, "Show HN: AnyDoor Script Plugins")
        XCTAssertEqual(rows.first?.symbol, "newspaper")
        XCTAssertEqual(rows.first?.commit, .pushDetail)

        // The query filter runs inside the plugin.
        let filtered = try await runtime.buildRows(pluginID: id, query: "JavaScriptCore")
        XCTAssertEqual(filtered.map(\.id), ["1002"])

        // detail(): per-row markdown (a plain string, so no pagination cursor).
        let detail = try await runtime.buildDetail(pluginID: id, rowID: "1001")
        XCTAssertTrue(detail.markdown.contains("# Show HN: AnyDoor Script Plugins"), detail.markdown)
        XCTAssertTrue(detail.markdown.contains("https://anydoor.dev/plugins"), detail.markdown)
        XCTAssertNil(detail.more)

        // action(): the openURL capability reaches the host through the spy.
        let result = try await runtime.performAction(pluginID: id, rowID: "1001", actionID: "default")
        XCTAssertEqual(result, .string("opened https://anydoor.dev/plugins"))
        XCTAssertEqual(spy.openedURLs.map(\.absoluteString), ["https://anydoor.dev/plugins"])
    }
}
