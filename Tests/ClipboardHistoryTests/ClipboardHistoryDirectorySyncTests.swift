import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testCompleteDirectoryPreservesNestedFilesEmptyDirectoriesAndLinks() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
            try Data("directory content".utf8).write(to: root.appendingPathComponent("nested/notes.txt"))
            try Data("#!/bin/sh\necho preserved\n".utf8).write(to: root.appendingPathComponent("run"))
            XCTAssertEqual(chmod(root.appendingPathComponent("run").path, 0o755), 0)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("inside").path, withDestinationPath: "nested/notes.txt")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/unavailable/external/target")
        })
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.state, .complete)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("nested/notes.txt")), Data("directory content".utf8))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.url.appendingPathComponent("nested/empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: working.url.appendingPathComponent("inside").path), "nested/notes.txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: working.url.appendingPathComponent("outside").path), "/unavailable/external/target")
        var mode = stat()
        XCTAssertEqual(lstat(working.url.appendingPathComponent("run").path, &mode), 0)
        XCTAssertEqual(mode.st_mode & 0o777, 0o755)
        let copied = fixture.root.appendingPathComponent("Independent tree")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [copied])
        try Data("independent edit".utf8).write(to: copied.appendingPathComponent("nested/notes.txt"))
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("nested/notes.txt")), Data("directory content".utf8))
    }
}
