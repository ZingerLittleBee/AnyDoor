import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testRootAttributeSavedDuringExchangePreservesTheEditedCompleteTree() async throws {
        let race = DirectoryRootAttributeRace()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileAfterNameExchange { race.saveAttributeToOldRoot() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old complete tree".utf8).write(to: root.appendingPathComponent("deep/member"))
            let value = Data("first".utf8)
            XCTAssertEqual(value.withUnsafeBytes { setxattr(root.path, "com.example.AnyDoor.root", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        race.arm(working.url)
        try Data("remote tree".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        XCTAssertTrue(race.triggered)
        var value = Data(count: 5)
        XCTAssertEqual(value.withUnsafeMutableBytes { getxattr(working.url.path, "com.example.AnyDoor.root", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 5)
        XCTAssertEqual(value, Data("other".utf8))
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("deep/member")), Data("old complete tree".utf8))
        let final = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(final.first?.state, .conflict)
    }

    @MainActor
    func testChangingNestedSourceRejectsTheFrozenVersionAndKeepsCompleteHistory() async throws {
        let race = DirectoryFreezeRace()
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("complete before edit".utf8).write(to: root.appendingPathComponent("deep/member"))
        }, senderFault: .init { point in
            if point == .syncFileTreeBeforeFreezeVerification { race.pauseIfArmed() }
            return false
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        await fixture.cloud.failCommits(true)
        race.arm()
        let freeze = Task {
            do { try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID); return false }
            catch { return true }
        }
        try await eventually { race.barrier.isWaiting }
        let edited = Data("saved while the source was being frozen".utf8)
        try edited.write(to: fixture.original.appendingPathComponent("deep/member"))
        race.barrier.release()
        let rejected = await freeze.value
        XCTAssertTrue(rejected)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("deep/member")), Data("complete before edit".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.original.appendingPathComponent("deep/member")), edited)
    }

    @MainActor
    func testCandidateDirectoryReplacementCannotRedirectMetadataOutsideTheTree() async throws {
        let race = DirectoryMetadataRace()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileTreeBeforeMetadata { race.replaceCandidateParent() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old complete tree".utf8).write(to: root.appendingPathComponent("deep/member"))
            XCTAssertEqual(chmod(root.appendingPathComponent("deep").path, 0o755), 0)
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside sentinel".utf8).write(to: outside.appendingPathComponent("member"))
        XCTAssertEqual(chmod(outside.path, 0o701), 0)
        race.arm(receiver: fixture.receiverRoot, outside: outside)
        try Data("remote replacement".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        XCTAssertTrue(race.triggered)
        var status = stat()
        XCTAssertEqual(lstat(outside.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o701)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("member")), Data("outside sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("deep/member")), Data("old complete tree".utf8))
    }

    @MainActor
    func testManyPortableAttributesNeverCreateAnUndecodableTreeHeader() async throws {
        let prefix = "com.example.AnyDoor." + String(repeating: "a", count: 80)
        let value = Data([0xD3])
        let fixture = try await makeLinkedFixture(initialBytes: Data([0x42]), prepareSource: { url in
            for index in 0..<200 {
                XCTAssertEqual(value.withUnsafeBytes { setxattr(url.path, prefix + String(index), $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
            }
        })
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.state, .complete)
        XCTAssertEqual(page.entries.first?.syncFiles.first?.originalByteCount, 201)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        var actual: UInt8 = 0
        XCTAssertEqual(getxattr(working.url.path, prefix + "199", &actual, 1, 0, XATTR_NOFOLLOW), 1)
        XCTAssertEqual(actual, 0xD3)
    }

    @MainActor
    func testDirectoryAndLinkMetadataPreservesQuarantineAndFinderInformation() async throws {
        let quarantine = Data("0081;12345678;AnyDoor fixture;".utf8)
        let finder = Data([UInt8(0x41)] + [UInt8](repeating: 0, count: 31))
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("external").path, withDestinationPath: "/unavailable/target")
            XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(root.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
            XCTAssertEqual(finder.withUnsafeBytes { setxattr(root.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
            XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(root.appendingPathComponent("external").path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        for (url, name, expected) in [(working.url, "com.apple.quarantine", quarantine),
            (working.url, "com.apple.FinderInfo", finder), (working.url.appendingPathComponent("external"), "com.apple.quarantine", quarantine)] {
            var value = Data(count: expected.count)
            XCTAssertEqual(value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, expected.count)
            XCTAssertEqual(value, expected)
        }
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.originalByteCount, Int64(quarantine.count * 2 + finder.count))
    }

    @MainActor
    func testResourceForkCountsTowardWholeObjectDownloadAndPortableMetadataSurvives() async throws {
        let fork = Data(repeating: 0xA7, count: 5_000_001)
        let attribute = Data([0, 1, 127, 255])
        let fixture = try await makeLinkedFixture(initialBytes: Data([0x42]), prepareSource: { url in
            let fd = open(url.path + "/..namedfork/rsrc", O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer { close(fd) }
            XCTAssertEqual(fork.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, fork.count)
            var dataStatus = stat(), forkStatus = stat()
            XCTAssertEqual(lstat(url.path, &dataStatus), 0)
            XCTAssertEqual(fstat(fd, &forkStatus), 0)
            XCTAssertEqual(dataStatus.st_ino, forkStatus.st_ino, "The native fork FD must identify its data-file inode")
            XCTAssertEqual(attribute.withUnsafeBytes { setxattr(url.path, "com.example.AnyDoor.fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        })
        let page = try await fixture.receiver.page(.init())
        let file = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertEqual(file.originalByteCount, 5_000_006)
        XCTAssertEqual(file.state, .waitingForDownload)
        let downloadedBefore = await fixture.cloud.downloadedFileVersions()
        XCTAssertFalse(downloadedBefore.contains(file.versionID))
        try await fixture.receiver.requestSyncFileDownload(entryID: fixture.entryID, objectID: file.id, versionID: file.versionID)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let output = try XCTUnwrap(locations.first?.url)
        XCTAssertEqual(try Data(contentsOf: output), Data([0x42]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output.path + "/..namedfork/rsrc")), fork)
        var bytes = Data(count: 4)
        XCTAssertEqual(bytes.withUnsafeMutableBytes { getxattr(output.path, "com.example.AnyDoor.fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 4)
        XCTAssertEqual(bytes, attribute)
    }

    @MainActor
    func testNestedSaveAtFinalDirectoryReplacementGateKeepsTheEditedTree() async throws {
        let barrier = LinkedReplacementBarrier()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old tree".utf8).write(to: root.appendingPathComponent("deep/member"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try Data("remote tree".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        let saved = Data("concurrent saved tree".utf8)
        try saved.write(to: working.url.appendingPathComponent("deep/member"))
        barrier.release()
        await receive.value
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("deep/member")), saved)
        let final = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(final.first?.state, .conflict)
        let materialized = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing complete tree") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), working.url.resolvingSymlinksInPath())
    }

    @MainActor
    func testAggregateDirectoryRequiresEachLargeVersionAndKeepsCompleteTreeDuringInterruption() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: 2_500_000).write(to: root.appendingPathComponent("one"))
            try Data(repeating: 0x32, count: 2_500_001).write(to: root.appendingPathComponent("two"))
        })
        var page = try await fixture.receiver.page(.init())
        let first = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertEqual(first.originalByteCount, 5_000_001)
        XCTAssertEqual(first.state, .waitingForDownload)
        try await fixture.receiver.requestSyncFileDownload(entryID: fixture.entryID, objectID: first.id, versionID: first.versionID)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try Data(repeating: 0x39, count: 2_500_001).write(to: fixture.original.appendingPathComponent("two"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: first.id)
        await fixture.receiver.retrySync()
        page = try await fixture.receiver.page(.init())
        let next = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertNotEqual(next.versionID, first.versionID)
        XCTAssertEqual(next.state, .updateAvailable)
        XCTAssertFalse(next.downloadRequested)
        await fixture.cloud.holdNextDownload()
        let download = Task { try await fixture.receiver.requestSyncFileDownload(entryID: fixture.entryID, objectID: next.id, versionID: next.versionID) }
        try await eventually { await fixture.cloud.downloadIsHeld() }
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("two")), Data(repeating: 0x32, count: 2_500_001))
        let old = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        XCTAssertEqual(old.items.count, 1)
        await fixture.cloud.releaseDownload()
        try await download.value
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("two")), Data(repeating: 0x39, count: 2_500_001))
    }

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

private final class DirectoryMetadataRace: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: URL?
    private var outside: URL?
    private var didTrigger = false
    var triggered: Bool { lock.withLock { didTrigger } }
    func arm(receiver: URL, outside: URL) { lock.withLock { self.receiver = receiver; self.outside = outside } }
    func replaceCandidateParent() {
        lock.withLock {
            guard !didTrigger, let receiver, let outside,
                  let entries = FileManager.default.enumerator(at: receiver, includingPropertiesForKeys: nil) else { return }
            for case let url as URL in entries where url.lastPathComponent.hasPrefix("Receiving-") && url.pathExtension == "partial" {
                let child = url.appendingPathComponent("deep")
                do {
                    try FileManager.default.removeItem(at: child)
                    try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
                    didTrigger = true
                    return
                } catch { continue }
            }
        }
    }
}

private final class DirectoryFreezeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let barrier = LinkedReplacementBarrier()
    func arm() { lock.withLock { armed = true } }
    func pauseIfArmed() {
        let shouldPause = lock.withLock { if armed { armed = false; return true }; return false }
        if shouldPause { barrier.pause() }
    }
}

private final class DirectoryRootAttributeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var working: URL?
    private var didTrigger = false
    var triggered: Bool { lock.withLock { didTrigger } }
    func arm(_ url: URL) { lock.withLock { working = url } }
    func saveAttributeToOldRoot() {
        lock.withLock {
            guard !didTrigger, let working,
                  let siblings = try? FileManager.default.contentsOfDirectory(at: working.deletingLastPathComponent(), includingPropertiesForKeys: nil),
                  let old = siblings.first(where: { $0.lastPathComponent.hasPrefix(working.lastPathComponent + " (AnyDoor update ") }) else { return }
            let value = Data("other".utf8)
            didTrigger = value.withUnsafeBytes { setxattr(old.path, "com.example.AnyDoor.root", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0
        }
    }
}
