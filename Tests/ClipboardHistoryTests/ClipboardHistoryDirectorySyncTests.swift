import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testSubstitutedCandidateFIFORejectsReceiptAndAllowsOffToDrain() async throws {
        let race = DirectoryFIFORace()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileTreeBeforeMetadata { race.replaceCandidateMember() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old complete tree".utf8).write(to: root.appendingPathComponent("deep/member"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try Data("remote replacement".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        race.arm(receiver: fixture.receiverRoot)
        let receive = Task { await fixture.receiver.retrySync() }
        // Polling and rescue are bounded even if the native read-open blocks.
        for _ in 0..<500 {
            if race.triggered { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        var disabled = false
        let disable = Task { try await fixture.receiver.setSyncEnabled(false); disabled = true }
        for _ in 0..<500 {
            if disabled { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let completedWithoutRescue = disabled
        let rescue = race.openOwnedRescueWriter()
        defer { if rescue >= 0 { close(rescue) } }
        await receive.value
        try await disable.value

        XCTAssertTrue(race.triggered)
        XCTAssertTrue(completedWithoutRescue, "A writerless FIFO must not block receipt or Off")
        let status = await fixture.receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.availableVersionID, working.baseVersionID)
        let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = content.items.first?.representations.first else { return XCTFail("Expected the previous complete tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("deep/member")), Data("old complete tree".utf8))
    }

    @MainActor
    func testSaveThroughDisplacedTreeDescriptorSurvivesCompletedReplacement() async throws {
        try await assertDisplacedTreeSaveSurvives(recovering: false)
    }

    @MainActor
    func testSaveThroughDisplacedTreeDescriptorSurvivesRecoveryAdmission() async throws {
        try await assertDisplacedTreeSaveSurvives(recovering: true)
    }

    @MainActor
    private func assertDisplacedTreeSaveSurvives(recovering: Bool) async throws {
        let save = DisplacedTreeSave()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == (recovering ? .linkedFileBeforeRecoveryCommit : .linkedFileAfterReplacement) {
                save.writeSavedBytes()
            }
            return recovering && point == .linkedFileAfterReplacement
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old tree".utf8).write(to: root.appendingPathComponent("deep/member"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let descriptor = open(working.url.appendingPathComponent("deep/member").path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        save.arm(descriptor)
        try Data("complete remote tree".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        if recovering { await fixture.receiver.retrySync() }

        XCTAssertTrue(save.saved, "The old FD must save after the previous content proof")
        let siblings = try FileManager.default.contentsOfDirectory(at: working.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let displaced = siblings.filter { $0.lastPathComponent.hasPrefix(working.url.lastPathComponent + " (AnyDoor update ") }
        XCTAssertEqual(displaced.count, 1, "The displaced inode must remain reachable after completion")
        if let retained = displaced.first {
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("deep/member")), DisplacedTreeSave.bytes)
        }
        let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = content.items.first?.representations.first else { return XCTFail("Expected the complete installed tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("deep/member")), Data("complete remote tree".utf8))
    }

    @MainActor
    func testTreeUploadProgressCountsEncodedPlaintextWithoutAuthenticationOverhead() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: root.appendingPathComponent("member"))
        })
        let initial = try await fixture.sender.page(.init())
        let object = try XCTUnwrap(initial.entries.first?.syncFiles.first)
        await fixture.cloud.failCommits(true)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: object.id)
        let page = try await fixture.sender.page(.init())
        let pending = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertTrue(pending.uploadPending)
        XCTAssertEqual(pending.originalByteCount, 7)
        XCTAssertGreaterThan(try XCTUnwrap(pending.transferTotalByteCount), 7)
        XCTAssertEqual(pending.transferredByteCount, pending.transferTotalByteCount)
    }

    @MainActor
    func testDirectoryAtAggregateThresholdDownloadsAutomatically() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 2_500_000).write(to: root.appendingPathComponent("one"))
            try Data(repeating: 0x62, count: 2_500_000).write(to: root.appendingPathComponent("two"))
        })
        let page = try await fixture.receiver.page(.init())
        let file = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertEqual(file.originalByteCount, 5_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(file.transferTotalByteCount), 5_000_000,
            "Transfer progress includes tree framing without changing the automatic-download threshold")
        XCTAssertEqual(file.transferredByteCount, try XCTUnwrap(file.transferTotalByteCount))
        XCTAssertEqual(file.state, .complete)
        XCTAssertFalse(file.downloadRequested)
        let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let result) = content.items.first?.representations.first else { return XCTFail("Expected complete directory") }
        XCTAssertEqual(try Data(contentsOf: result.currentURL.appendingPathComponent("two")), Data(repeating: 0x62, count: 2_500_000))
    }

    @MainActor
    func testDisablingDuringDirectoryOutputVerificationKeepsThePreviousCompleteTree() async throws {
        let race = DirectoryFreezeRace()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileTreeBeforeOutputVerification { race.pauseIfArmed() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old complete tree".utf8).write(to: root.appendingPathComponent("deep/member"))
        })
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try Data("remote replacement".utf8).write(to: fixture.original.appendingPathComponent("deep/member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        race.arm()
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { race.barrier.isWaiting }
        let cancellations = await fixture.cloud.cancellationCount()
        let disable = Task { try await fixture.receiver.setSyncEnabled(false) }
        // Shutdown drains its task before returning, but revocation/cancellation
        // must reach the external boundary while the recursive proof is paused.
        try await eventually { await fixture.cloud.cancellationCount() > cancellations }
        race.barrier.release()
        try await disable.value
        await receive.value
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.availableVersionID, working.baseVersionID)
        let materialized = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing previous complete tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("deep/member")), Data("old complete tree".utf8))
    }

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

private final class DirectoryFIFORace: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: URL?
    private var fifo: URL?
    var triggered: Bool { lock.withLock { fifo != nil } }
    func arm(receiver: URL) { lock.withLock { self.receiver = receiver } }
    func replaceCandidateMember() {
        lock.withLock {
            guard fifo == nil, let receiver,
                  let entries = FileManager.default.enumerator(at: receiver, includingPropertiesForKeys: nil) else { return }
            for case let url as URL in entries where url.lastPathComponent.hasPrefix("Receiving-") && url.pathExtension == "partial" {
                let member = url.appendingPathComponent("deep/member")
                do {
                    try FileManager.default.removeItem(at: member)
                    if mkfifo(member.path, 0o600) == 0 { fifo = member }
                } catch {}
                return
            }
        }
    }
    func openOwnedRescueWriter() -> Int32 {
        lock.withLock {
            guard let fifo else { return -1 }
            // O_RDWR is nonblocking and releases the old blocking read-open.
            // Keep this FD alive until both test-owned tasks have drained.
            return open(fifo.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
    }
}

private final class DisplacedTreeSave: @unchecked Sendable {
    static let bytes = Data("saved through the old descriptor after verification".utf8)
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var didSave = false
    var saved: Bool { lock.withLock { didSave } }
    func arm(_ descriptor: Int32) { lock.withLock { self.descriptor = descriptor } }
    func writeSavedBytes() {
        lock.withLock {
            guard descriptor >= 0, !didSave else { return }
            didSave = Self.bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == Self.bytes.count
                && ftruncate(descriptor, off_t(Self.bytes.count)) == 0 && fsync(descriptor) == 0
        }
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
