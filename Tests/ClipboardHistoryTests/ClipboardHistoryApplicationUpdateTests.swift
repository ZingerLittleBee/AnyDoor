import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testApplicationVersionDownloadsWithoutReplacingItsLinkedLocation() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let plist: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "dev.bybee.AnyDoor.tests.update-boundary"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
            try Data("previous application resource".utf8).write(to: root.appendingPathComponent("Contents/Resources/value.txt"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("downloaded application update".utf8).write(to: fixture.original.appendingPathComponent("Contents/Resources/value.txt"))

        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        let page = try await fixture.receiver.page(.init())
        let update = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertNotEqual(update.versionID, working.baseVersionID)
        XCTAssertEqual(update.availableVersionID, working.baseVersionID, "Normal actions still use the installed version")
        let downloaded = await fixture.cloud.downloadedFileVersions()
        XCTAssertTrue(downloaded.contains(update.versionID), "The update downloads without authorizing replacement")
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("Contents/Resources/value.txt")), Data("previous application resource".utf8))
        let unchanged = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(unchanged.first?.baseVersionID, working.baseVersionID)
        let materialized = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("The linked application remains available") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("Contents/Resources/value.txt")), Data("previous application resource".utf8))
    }
}
