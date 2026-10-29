import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testOrdinaryLinkedReplacementPreservesDestinationReadWritePermissions() async throws {
        for permissions: mode_t in [0o644, 0o664] {
            let fixture = try await makeLinkedFixture()
            let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            let working = try XCTUnwrap(locations.first)
            try await fixture.receiver.setSyncEnabled(false)
            XCTAssertEqual(chmod(working.url.path, permissions), 0)
            let saved = Data("new complete bytes for mode \(permissions)".utf8)
            try saved.write(to: fixture.original)
            try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)

            try await fixture.receiver.setSyncEnabled(true)

            XCTAssertEqual(try Data(contentsOf: working.url), saved)
            var installed = stat()
            XCTAssertEqual(lstat(working.url.path, &installed), 0)
            XCTAssertEqual(installed.st_mode & 0o7777, permissions,
                "A verified ordinary-file update must retain the destination's read/write sharing permissions")
            let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
            guard case .file(let file) = content.items.first?.representations.first else {
                return XCTFail("Expected the updated linked file")
            }
            XCTAssertEqual(try Data(contentsOf: file.currentURL), saved)
        }
    }
}
