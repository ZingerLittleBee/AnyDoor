import Foundation
import PluginInterface
import XCTest

@testable import ScriptPluginRuntime

/// Decodes the committed Swift↔TS behaviour-contract fixture
/// (`Fixtures/ScriptContract/contract.json`). The fixture's source of truth is
/// `tooling/packages/api/type-tests/contract-fixtures.ts` — values type-checked
/// against `@anydoor/api` and emitted by
/// `tooling/scripts/refresh-contract-fixtures.mjs` — so the same bytes are
/// pinned on both sides of the contract: TS types on emit, the host decoder
/// here. A contract change that only lands on one side fails a machine (this
/// test or `pnpm verify`) instead of a plugin author at runtime.
final class ScriptContractFixtureTests: XCTestCase {

    // MARK: - Capabilities

    func testCapabilityListMatchesHost() throws {
        let contract = try loadContract()
        let hostKeys = ScriptCapability.allCases.map(\.manifestKey)
        XCTAssertEqual(Set(contract.capabilities), Set(hostKeys))
        XCTAssertEqual(contract.capabilities.count, hostKeys.count, "duplicate capability names")
    }

    // MARK: - Manifest

    func testManifestFixtureDecodes() throws {
        let contract = try loadContract()
        let manifest = try ScriptPluginManifest.decode(from: contract.manifestData)
        XCTAssertEqual(manifest.id, ScriptPluginID("dev.anydoor.contract-fixture"))
        XCTAssertEqual(manifest.apiVersion, 1)
        XCTAssertEqual(manifest.capabilities, Set(ScriptCapability.allCases))
        XCTAssertEqual(manifest.localizedNames["zh"], "契约夹具")
    }

    // MARK: - Rows

    /// The id → commit-semantics mapping this side of the contract expects.
    /// Ids are declared in `contract-fixtures.ts`; extending the contract means
    /// adding a fixture row there and its expectation here.
    private static let expectedCommits: [String: PluginRowDescriptor.CommitSemantics] = [
        "action-detail": .pushDetail,
        "action-list": .pushList("hot"),
        "action-openURL": .openURL("https://example.com"),
        "action-copy": .copy("copied text"),
        "action-argument": .enterArgument,
        "action-run-default": .closeThenAct,
        "action-run-stay": .stayOpen,
        "legacy-stayOpen": .stayOpen,
        "legacy-closeThenAct": .closeThenAct,
        "bare": .stayOpen,
    ]

    func testRowFixturesDecodeToExpectedCommitSemantics() throws {
        let rows = try decodeRows()
        XCTAssertEqual(Set(rows.keys), Set(Self.expectedCommits.keys))
        for (id, expected) in Self.expectedCommits {
            XCTAssertEqual(rows[id]?.commit, expected, "row '\(id)'")
        }
    }

    func testRowFixtureFieldsSurviveDecoding() throws {
        let rows = try decodeRows()

        let full = try XCTUnwrap(rows["action-run-stay"])
        XCTAssertEqual(full.subtitle, "keeps the palette open")
        XCTAssertEqual(full.symbol, "star")
        XCTAssertEqual(full.actionLabel, "Toggle")
        XCTAssertTrue(full.isChecked)
        XCTAssertEqual(full.badge, "On")

        let bare = try XCTUnwrap(rows["bare"])
        XCTAssertNil(bare.subtitle)
        XCTAssertEqual(bare.symbol, "puzzlepiece.extension")
        XCTAssertNil(bare.badge)
        XCTAssertFalse(bare.isChecked)
    }

    /// Exhaustiveness pin: the fixture set must exercise every commit case a
    /// plugin can author. The switch is deliberately exhaustive with no default,
    /// so adding a `CommitSemantics` case fails to compile here until it is
    /// classified — the reminder to extend the fixtures and the TS union too.
    func testFixturesCoverEveryAuthorableCommitCase() throws {
        var seen: Set<String> = []
        for descriptor in try decodeRows().values {
            switch descriptor.commit {
            case .closeThenAct: seen.insert("closeThenAct")
            case .stayOpen: seen.insert("stayOpen")
            case .pushDetail: seen.insert("pushDetail")
            case .openURL: seen.insert("openURL")
            case .copy: seen.insert("copy")
            case .enterArgument: seen.insert("enterArgument")
            case .pushList: seen.insert("pushList")
            case .noAction, .runArgument:
                XCTFail("host-only semantics must never decode from a package: \(descriptor.commit)")
            }
        }
        XCTAssertEqual(seen, [
            "closeThenAct", "stayOpen", "pushDetail", "openURL",
            "copy", "enterArgument", "pushList",
        ])
    }

    // MARK: - Fixture plumbing

    private struct Contract {
        let capabilities: [String]
        let manifestData: Data
        let rows: ScriptValue
    }

    private func decodeRows() throws -> [String: PluginRowDescriptor] {
        let descriptors = try ScriptRowDecoder.decode(loadContract().rows)
        return Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    private func loadContract() throws -> Contract {
        // The `.process` resource rule may flatten the fixture subdirectory, so
        // fall back through the possible locations (same as the tooling
        // template fixture).
        let candidates = [
            Bundle.module.url(forResource: "contract", withExtension: "json", subdirectory: "Fixtures/ScriptContract"),
            Bundle.module.url(forResource: "contract", withExtension: "json", subdirectory: "ScriptContract"),
            Bundle.module.url(forResource: "contract", withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: "contract", withExtension: "json"),
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "contract.json fixture missing")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(object as? [String: Any])
        let manifest = try XCTUnwrap(json["manifest"], "fixture missing 'manifest'")
        return Contract(
            capabilities: try XCTUnwrap(json["capabilities"] as? [String]),
            manifestData: try JSONSerialization.data(withJSONObject: manifest),
            rows: Self.scriptValue(fromJSON: try XCTUnwrap(json["rows"]))
        )
    }

    /// Rebuild the `ScriptValue` the runtime would hand the decoder for this
    /// JSON — the same value shape a plugin's `rows()` result decodes into
    /// after crossing off the plugin queue.
    private static func scriptValue(fromJSON object: Any) -> ScriptValue {
        switch object {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map(scriptValue(fromJSON:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(scriptValue(fromJSON:)))
        default:
            return .null
        }
    }
}
