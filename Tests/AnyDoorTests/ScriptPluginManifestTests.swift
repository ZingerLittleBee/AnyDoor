import Foundation
import XCTest
import ScriptPluginRuntime

/// Manifest validation gates loading: missing fields, unknown apiVersion, and
/// unknown capabilities are typed refusals, and none of them change any state.
final class ScriptPluginManifestTests: XCTestCase {
    func testValidManifestLoads() throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.valid",
            name: "Valid",
            description: "Fine.",
            version: "2.1.0",
            capabilities: ["fetch", "store", "openURL"],
            bundle: "anydoor.registerPlugin({});"
        )
        let package = try ScriptPluginPackage.load(fromDirectory: directory)
        XCTAssertEqual(package.id, ScriptPluginID("com.example.valid"))
        XCTAssertEqual(package.manifest.name, "Valid")
        XCTAssertEqual(package.manifest.version, "2.1.0")
        XCTAssertEqual(package.manifest.capabilities, [.fetch, .store, .openURL])
        XCTAssertEqual(package.manifest.entryPoint, "bundle.js")
    }

    func testMissingRequiredFieldIsTyped() throws {
        // Omit "name".
        let directory = try ScriptPluginFixture.writeRawPackage(
            manifest: [
                "id": "com.example.noname",
                "description": "x",
                "version": "1.0.0",
                "apiVersion": 1,
            ],
            bundle: "anydoor.registerPlugin({});"
        )
        XCTAssertThrowsError(try ScriptPluginPackage.load(fromDirectory: directory)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .missingField("name"))
        }
    }

    func testMissingApiVersionIsTyped() throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.noapi",
            apiVersion: nil,
            bundle: "anydoor.registerPlugin({});"
        )
        XCTAssertThrowsError(try ScriptPluginPackage.load(fromDirectory: directory)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .missingField("apiVersion"))
        }
    }

    func testUnknownApiVersionIsTyped() throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.badapi",
            apiVersion: 99,
            bundle: "anydoor.registerPlugin({});"
        )
        XCTAssertThrowsError(try ScriptPluginPackage.load(fromDirectory: directory)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .unknownAPIVersion(99))
        }
    }

    func testUnknownCapabilityIsTyped() throws {
        let directory = try ScriptPluginFixture.writePackage(
            id: "com.example.badcap",
            capabilities: ["fetch", "shell"],
            bundle: "anydoor.registerPlugin({});"
        )
        XCTAssertThrowsError(try ScriptPluginPackage.load(fromDirectory: directory)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .unknownCapability("shell"))
        }
    }

    func testUnreadableManifestIsTyped() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try ScriptPluginPackage.load(fromDirectory: directory)) { error in
            XCTAssertEqual(error as? ScriptManifestError, .fileUnreadable)
        }
    }
}
