import Foundation
import XCTest

final class ClipboardHistoryApplicationFixtureTests: XCTestCase {
    func testSignedFixtureContainsNestedCodeResourcesAndRelativeLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("application-fixture-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixture = try ClipboardApplicationTestFixture.create(at: root.appendingPathComponent("Fixture.app"),
            bundleIdentifier: "dev.bybee.AnyDoor.tests.fixture.\(UUID().uuidString)", resource: "fixture resource\n")

        try fixture.verifySignature()
        let tree = try fixture.contentsSnapshot()

        XCTAssertEqual(tree["Contents/MacOS/FixtureApplication"]?.kind, .file)
        XCTAssertEqual(tree["Contents/MacOS/FixtureApplication"]?.mode, 0o755)
        XCTAssertEqual(tree["Contents/Helpers/FixtureHelper"]?.kind, .file)
        XCTAssertEqual(tree["Contents/Helpers/FixtureHelper"]?.mode, 0o755)
        XCTAssertEqual(tree["Contents/Resources/ResourceLink.txt"]?.kind, .symbolicLink)
        XCTAssertEqual(tree["Contents/Resources/ResourceLink.txt"]?.linkTarget, "Resource.txt")
        XCTAssertEqual(tree["Contents/Resources/Resource.txt"]?.kind, .file)
        XCTAssertEqual(tree["Contents/Resources/Resource.txt"]?.digest?.count, 64)
        XCTAssertEqual(tree["Contents/_CodeSignature/CodeResources"]?.kind, .file)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("Contents/Resources/ResourceLink.txt"), encoding: .utf8),
            "fixture resource\n")
        let copy = root.appendingPathComponent("Copied.app")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        XCTAssertEqual(try ClipboardApplicationTestFixture(url: copy).contentsSnapshot(), tree)
    }
}
