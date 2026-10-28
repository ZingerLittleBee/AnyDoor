import CryptoKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testConflictResolutionRejectsNestedChangesToItsConstructedResult() async throws {
        let mutation = ConflictTreeOutputMutation()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .fileConflictBeforeStaging { mutation.changeCandidate() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("initial tree".utf8).write(to: root.appendingPathComponent("nested/note.txt"))
        })
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote branch".utf8).write(to: fixture.original.appendingPathComponent("nested/note.txt"))
        let localBytes = Data("chosen local branch".utf8)
        try localBytes.write(to: working.url.appendingPathComponent("nested/note.txt"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let before = try await fixture.receiver.page(.init()).entries.first?.syncFiles.first
        mutation.arm(fixture.receiverRoot)
        do {
            _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
            XCTFail("A changed constructed tree cannot become a complete conflict result")
        } catch {}
        XCTAssertTrue(mutation.changed)
        let after = try await fixture.receiver.page(.init()).entries.first?.syncFiles.first
        XCTAssertEqual(after?.availableVersionID, before?.availableVersionID)
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("nested/note.txt")), localBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original.appendingPathComponent("nested/note.txt")), Data("remote branch".utf8))
    }

    @MainActor
    func testAuthenticatedTreeTraversalCannotReplaceTheCompleteDirectoryOrEscapeItsRoot() async throws {
        try await assertInvalidTreePath(.parentTraversal, reopen: true)
    }

    @MainActor
    func testAuthenticatedAbsoluteTreePathCannotReplaceTheCompleteDirectoryOrOutsideFile() async throws {
        try await assertInvalidTreePath(.absolute)
    }

    @MainActor
    func testAuthenticatedTreeSymlinkDescendantCannotWriteThroughTheLinkOrReplaceTheCompleteTree() async throws {
        try await assertInvalidTreePath(.symlinkDescendant)
    }

    @MainActor
    private func assertInvalidTreePath(_ attack: InvalidTreePath, reopen: Bool = false) async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("trusted complete tree".utf8).write(to: root.appendingPathComponent("payload.txt"))
            if attack == .symlinkDescendant {
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape-link").path,
                    withDestinationPath: root.deletingLastPathComponent().appendingPathComponent("Outside").path)
            }
        })
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        let protectedBytes = Data("outside sentinel must remain untouched".utf8)
        try protectedBytes.write(to: sentinel)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let account = await fixture.cloud.account()
        let current = await fixture.cloud.control(for: account)
        var control = try XCTUnwrap(current)
        let loaded = try await fixture.services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let uploads = await fixture.cloud.uploadedRecords()
        let descriptors = try uploads.filter { $0.record.kind == .entry }.flatMap { upload -> [ClipboardSyncFileDescriptor] in
            guard case .entry(let entry) = try ClipboardSyncCodec.open(upload.record, chunks: upload.chunks,
                account: account, control: control, key: key) else { return [] }
            return entry.items.flatMap(\.representations).compactMap { if case .file(let file) = $0 { file } else { nil } }
        }
        let original = try XCTUnwrap(descriptors.first { $0.objectID == working.objectID })
        let body = try XCTUnwrap(uploads.first { $0.record == original.body })
        let plaintext = try body.chunks.enumerated().reduce(into: Data()) { result, segment in
            result.append(try ClipboardSyncCodec.openFileSegment(segment.element, descriptor: original,
                account: account, control: control, key: key, index: segment.offset))
        }
        let path = switch attack {
        case .parentTraversal: "../sentinel.txt"
        case .absolute: sentinel.path
        case .symlinkDescendant: "escape-link/sentinel.txt"
        }
        let malformed = try replacingTreePath(in: plaintext, from: "payload.txt", to: path)
        let versionID = UUID()
        let originalCount = try XCTUnwrap(original.originalByteCount)
        let count = max(1, (malformed.count + ClipboardSyncCodec.chunkByteCount - 1) / ClipboardSyncCodec.chunkByteCount)
        let chunks = try (0..<count).map { index in
            let start = index * ClipboardSyncCodec.chunkByteCount
            return try ClipboardSyncCodec.sealFileSegment(malformed.subdata(in: start..<min(start + ClipboardSyncCodec.chunkByteCount, malformed.count)),
                account: account, control: control, key: key, objectID: original.objectID, versionID: versionID,
                originalByteCount: originalCount, index: index, count: count, encodedByteCount: Int64(malformed.count))
        }
        let record = ClipboardSyncRemoteRecord(recordID: "v1-\(versionID.uuidString.lowercased())", operationID: versionID,
            epoch: control.epoch, keyID: control.keyID, kind: .fileBody, chunkCount: chunks.count,
            encryptedByteCount: chunks.reduce(0) { $0 + Int64($1.count) }, digest: ClipboardSyncCodec.digest(chunks))
        let descriptor = ClipboardSyncFileDescriptor(objectID: original.objectID, versionID: versionID,
            displayName: original.displayName, originalByteCount: originalCount, contentDigest: Data(SHA256.hash(data: malformed)),
            body: record, state: .available, bodyFormat: .treeSegmentsV1, kind: original.kind, encodedByteCount: Int64(malformed.count))
        control = try await fixture.cloud.commit(.init(record: record, chunks: chunks), for: account, control: control)
        let event = try ClipboardSyncCodec.seal(.fileVersion(.init(descriptor: descriptor, parents: [working.baseVersionID])),
            account: account, control: control, key: key)
        _ = try await fixture.cloud.commit(event, for: account, control: control)

        try await fixture.receiver.setSyncEnabled(true)

        try await assertRejectedTree(fixture.receiver, entryID: fixture.entryID, working: working,
            rejectedVersion: versionID, sentinel: sentinel, protectedBytes: protectedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: working.url.path).sorted(),
            attack == .symlinkDescendant ? ["escape-link", "payload.txt"] : ["payload.txt"])
        if attack == .symlinkDescendant {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: working.url.appendingPathComponent("escape-link").path), outside.path)
        }
        let downloads = await fixture.cloud.downloadedFileVersions()
        XCTAssertTrue(downloads.contains(versionID), "The authenticated malformed body must reach the real receiving parser")
        if reopen {
            try await fixture.receiver.closeStoreForTesting()
            let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
            await reopened.resumeSync()
            try await assertRejectedTree(reopened, entryID: fixture.entryID, working: working,
                rejectedVersion: versionID, sentinel: sentinel, protectedBytes: protectedBytes)
        }
    }

    @MainActor
    private func assertRejectedTree(_ module: ClipboardHistoryModule, entryID: ClipboardHistoryEntryID,
        working: ClipboardHistoryLinkedFileLocation, rejectedVersion: UUID, sentinel: URL, protectedBytes: Data) async throws {
        let page = try await module.page(.init())
        let file = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertEqual(file.versionID, rejectedVersion)
        XCTAssertEqual(file.availableVersionID, working.baseVersionID)
        XCTAssertEqual(file.transferFailure, .corruptData)
        let locations = try await module.linkedFileLocations(for: entryID)
        XCTAssertEqual(locations.first?.baseVersionID, working.baseVersionID)
        let materialized = try await module.materialize(.init(entryID: entryID, purpose: .normalPaste))
        guard case .file(let content) = materialized.items.first?.representations.first else { return XCTFail("The old complete tree remains pasteable") }
        XCTAssertEqual(content.currentURL.resolvingSymlinksInPath(), working.url.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("payload.txt")), Data("trusted complete tree".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), protectedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinel.deletingLastPathComponent().path), ["sentinel.txt"])
    }

    @MainActor
    func testOfflineDirectoryEditsPreserveBothTreesAndResolveThroughTheFileConflictFlow() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("original tree".utf8).write(to: root.appendingPathComponent("nested/note.txt"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remoteBytes = Data("saved on the other Mac while offline".utf8)
        let localBytes = Data("local directory choice".utf8)
        try remoteBytes.write(to: fixture.original.appendingPathComponent("nested/note.txt"))
        try Data("remote branch only".utf8).write(to: fixture.original.appendingPathComponent("remote-only.txt"))
        try localBytes.write(to: working.url.appendingPathComponent("nested/note.txt"))
        try Data("chosen local branch only".utf8).write(to: working.url.appendingPathComponent("local-only.txt"))

        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertEqual(plan.candidates.count, 2)
        let remote = try XCTUnwrap(plan.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let remoteID) = remote.id else { return XCTFail("Expected the competing remote tree") }
        let remoteTree = try XCTUnwrap(remote.localURL)
        XCTAssertEqual(try Data(contentsOf: remoteTree.appendingPathComponent("nested/note.txt")), remoteBytes)
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("nested/note.txt")), localBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteTree.appendingPathComponent("remote-only.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.url.appendingPathComponent("local-only.txt").path))

        let resultID = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
        await fixture.sender.retrySync()

        for tree in [fixture.original, working.url] {
            XCTAssertEqual(try Data(contentsOf: tree.appendingPathComponent("nested/note.txt")), localBytes)
            XCTAssertEqual(try Data(contentsOf: tree.appendingPathComponent("local-only.txt")), Data("chosen local branch only".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree.appendingPathComponent("remote-only.txt").path))
        }
        let versions = try await decodedConflictVersions(cloud: fixture.cloud, services: fixture.services)
        let result = try XCTUnwrap(versions.first { $0.descriptor.versionID == resultID })
        XCTAssertEqual(result.parents.count, 2)
        XCTAssertTrue(result.parents.contains(remoteID))
        let localBranch = try XCTUnwrap(versions.first {
            result.parents.contains($0.descriptor.versionID) && $0.descriptor.versionID != remoteID
        })
        XCTAssertEqual(localBranch.parents, [working.baseVersionID], "The chosen tree must retain its actual edited base")
        let resolved = try await fixture.receiver.page(.init())
        XCTAssertEqual(resolved.entries.first?.syncFiles.first?.hasConflict, false)
    }
}

private final class ConflictTreeOutputMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?
    private var didChange = false
    var changed: Bool { lock.withLock { didChange } }
    func arm(_ root: URL) { lock.withLock { self.root = root } }
    func changeCandidate() {
        lock.withLock {
            guard !didChange, let root,
                  let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
            for case let url as URL in entries where url.lastPathComponent.hasPrefix("Receiving-") && url.pathExtension == "partial" {
                do {
                    try Data("unverified nested edit".utf8).write(to: url.appendingPathComponent("nested/note.txt"))
                    didChange = true
                } catch {}
                return
            }
        }
    }
}

private enum InvalidTreePath {
    case parentTraversal, absolute, symlinkDescendant
}

/// Mutate an authentic external record without constructing a substitute tree
/// encoder. Data/resource forks and attribute frames remain byte-for-byte intact.
private func replacingTreePath(in original: Data, from originalPath: String, to replacement: String) throws -> Data {
    var offset = Data("AnyDoorTree1\n".utf8).count
    func readFrame() throws -> (start: Int, end: Int, values: [String: Any]) {
        let start = offset
        guard offset + 4 <= original.count else { throw ClipboardSyncServiceError.corruptData }
        let length = original[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length > 0, offset + length <= original.count,
              let values = try JSONSerialization.jsonObject(with: original.subdata(in: offset..<(offset + length))) as? [String: Any] else {
            throw ClipboardSyncServiceError.corruptData
        }
        offset += length
        return (start, offset, values)
    }
    while offset < original.count {
        let frame = try readFrame()
        if frame.values["path"] as? String == originalPath {
            var values = frame.values
            values["path"] = replacement
            let header = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            var length = UInt32(header.count).bigEndian
            var result = Data(original.prefix(frame.start))
            result.append(withUnsafeBytes(of: &length) { Data($0) })
            result.append(header)
            result.append(original.suffix(from: frame.end))
            return result
        }
        guard let size = frame.values["size"] as? Int, let forkSize = frame.values["forkSize"] as? Int,
              let attributes = frame.values["attributeCount"] as? Int, size >= 0, forkSize >= 0, attributes >= 0 else {
            throw ClipboardSyncServiceError.corruptData
        }
        offset += size + forkSize
        for _ in 0..<attributes {
            let attribute = try readFrame()
            guard let size = attribute.values["size"] as? Int, size >= 0 else { throw ClipboardSyncServiceError.corruptData }
            offset += size
        }
    }
    throw ClipboardSyncServiceError.corruptData
}
