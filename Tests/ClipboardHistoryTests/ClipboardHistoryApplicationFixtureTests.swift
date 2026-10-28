import AppKit
import Foundation
import XCTest

final class ClipboardHistoryApplicationFixtureTests: XCTestCase {
    @MainActor
    func testOwnedApplicationIsNativelyVisibleAndExitsWithoutChangingItsPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("running-application-fixture-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixture = try ClipboardApplicationTestFixture.create(at: root.appendingPathComponent("Visible.app"),
            bundleIdentifier: "dev.bybee.AnyDoor.tests.fixture.\(UUID().uuidString)", resource: "native fixture")
        try fixture.verifySignature()
        let baseline = try fixture.contentsSnapshot()

        let process = try await fixture.launch()
        addTeardownBlock { try await process.stop() }

        XCTAssertTrue(process.isRunning)
        let running = try XCTUnwrap(process.runningApplication)
        XCTAssertEqual(running.processIdentifier, process.processIdentifier)
        XCTAssertEqual(running.bundleURL?.resolvingSymlinksInPath(), fixture.url.resolvingSymlinksInPath())
        let workspace = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier == process.processIdentifier })
        XCTAssertEqual(workspace.executableURL?.resolvingSymlinksInPath(), fixture.executableURL.resolvingSymlinksInPath())
        XCTAssertEqual(workspace.bundleURL?.resolvingSymlinksInPath(), fixture.url.resolvingSymlinksInPath())

        try await process.stop()

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(running.isTerminated)
        try fixture.verifySignature()
        XCTAssertEqual(try fixture.contentsSnapshot(), baseline)
    }

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
