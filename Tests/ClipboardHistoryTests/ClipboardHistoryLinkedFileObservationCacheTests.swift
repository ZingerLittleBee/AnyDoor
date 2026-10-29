import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryLinkedFileObservationCacheTests: XCTestCase {
    func testUnchangedFileSkipsContentButExpiryAndSavedChangesRequireIt() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("video.bin")
        try Data(repeating: 0x52, count: 2 * 1_024 * 1_024).write(to: file)
        let proof = try ClipboardLinkedFileIO.inspect(file)
        let source = source(for: proof)
        let now = ContinuousClock.now
        let cached = try ClipboardLinkedObservationCache(source: source, proof: proof, now: now)
        XCTAssertTrue(try cached.isUnchanged(source, now: now + .seconds(5)))
        XCTAssertFalse(try cached.isUnchanged(source, now: now + .seconds(300)))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("new saved bytes".utf8))
        try handle.close()
        XCTAssertFalse(try cached.isUnchanged(source, now: now + .seconds(10)))
    }

    func testTreeHintDetectsNestedSaveEvenWhenDirectoryStampDoesNotChange() throws {
        let root = try makeRoot()
        let tree = root.appendingPathComponent("Folder")
        let nested = tree.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = nested.appendingPathComponent("video.bin")
        try Data(repeating: 0x31, count: 2 * 1_024 * 1_024).write(to: child)
        let proof = try ClipboardLinkedFileIO.inspect(tree)
        let source = source(for: proof)
        let cached = try ClipboardLinkedObservationCache(source: source, proof: proof)
        XCTAssertTrue(try cached.isUnchanged(source))
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(tree.path, &before), 0)
        let handle = try FileHandle(forWritingTo: child)
        try handle.write(contentsOf: Data("saved nested content".utf8))
        try handle.close()
        XCTAssertEqual(lstat(tree.path, &after), 0)
        XCTAssertEqual(ClipboardSyncFileSnapshot(before), ClipboardSyncFileSnapshot(after))
        XCTAssertFalse(try cached.isUnchanged(source), "A root-only stat would miss this saved edit")
    }

    func testTreeHintTracksMembershipAndDoesNotFollowSymlinkTargets() throws {
        let root = try makeRoot()
        let tree = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: outside)
        let proof = try ClipboardLinkedFileIO.inspect(tree)
        let source = source(for: proof)
        let cached = try ClipboardLinkedObservationCache(source: source, proof: proof)
        try Data("independent bytes outside the tree".utf8).write(to: outside)
        XCTAssertTrue(try cached.isUnchanged(source))
        try Data("new member".utf8).write(to: tree.appendingPathComponent("added.txt"))
        XCTAssertFalse(try cached.isUnchanged(source))
    }

    private func source(for proof: ClipboardLinkedFileProof) -> ClipboardLinkedLocationSource {
        .init(id: UUID(), objectID: UUID(), url: proof.url, identity: proof.identity,
            bookmark: proof.bookmark, revision: 1, nativeIdentity: proof.nativeIdentity,
            hasPendingApplication: false, baseVersionID: UUID(), baseDigest: proof.digest, state: .current)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("observation-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
