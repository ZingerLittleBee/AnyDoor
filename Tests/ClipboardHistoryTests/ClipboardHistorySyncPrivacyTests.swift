import AppKit
import Darwin
import Foundation
import XCTest
import os

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFrozenConflictAndCleanupJournalsStayEncryptedAcrossRestart() async throws {
        let initial = Data("private initial retention birch meadow".utf8)
        let frozen = Data("private frozen retention coral valley".utf8)
        let newer = Data("private newer retention indigo orchard".utf8)
        let remote = Data("private remote retention copper garden".utf8)
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictAfterBranchFreeze]), initialBytes: initial)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let markers = [String(decoding: initial, as: UTF8.self), String(decoding: frozen, as: UTF8.self),
            String(decoding: newer, as: UTF8.self), String(decoding: remote, as: UTF8.self), fixture.original.path,
            "private preservation tag emerald river", fixture.original.lastPathComponent]
        let probe = PrivacyArtifactProbe(roots: [fixture.root.appendingPathComponent("Sender"), fixture.receiverRoot], markers: markers)
        probe.allowVisible(working.url)
        _ = try await fixture.receiver.createTagDefinition(named: "private preservation tag emerald river", assigningTo: fixture.entryID)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try remote.write(to: fixture.original)
        try frozen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        for candidate in plan.candidates where candidate.availability == .available {
            let url = try XCTUnwrap(candidate.localURL)
            XCTAssertTrue([initial, frozen, remote].contains(try Data(contentsOf: url)))
            probe.allowVisible(url)
        }
        do {
            _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
            XCTFail("Expected the already-frozen branch to survive interruption")
        } catch ClipboardHistoryStorageError.injected(.fileConflictAfterBranchFreeze) { }
        probe.scan(stage: "frozen-conflict")
        try await fixture.receiver.setSyncEnabled(false)
        try await fixture.receiver.closeStoreForTesting()
        try newer.write(to: working.url)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        let interrupted = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52,
            faultInjector: .init(points: [.syncFileCleanupBeforeRemoval]))
        probe.scan(stage: "reopened-preparation")
        try await interrupted.setSyncEnabled(true)
        let notices = try await interrupted.preservedSyncEdits()
        XCTAssertEqual(notices.count, 2)
        var preserved: [URL: Data] = [:]
        for notice in notices {
            let materialized = try await interrupted.materialize(.init(entryID: notice.id, purpose: .normalPaste))
            guard case .file(let file) = materialized.items.first?.representations.first else {
                return XCTFail("Expected visible, independent preserved work")
            }
            preserved[file.currentURL] = try Data(contentsOf: file.currentURL)
            probe.allowVisible(file.currentURL)
        }
        XCTAssertEqual(Set(preserved.values), [frozen, newer])
        let transfers = fixture.receiverRoot.appendingPathComponent("SyncTransfers")
        let retained = privacyCiphertextFiles(in: transfers)
        XCTAssertFalse(retained.isEmpty, "Interrupted cleanup must leave real encrypted owned artifacts to inspect")
        probe.scan(stage: "pending-cleanup")
        try await interrupted.closeStoreForTesting()
        let resumed = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await resumed.resumeSync()
        await resumed.retrySync()
        let replayedNotices = try await resumed.preservedSyncEdits()
        XCTAssertEqual(Set(replayedNotices.map(\.id)), Set(notices.map(\.id)))
        XCTAssertTrue(privacyCiphertextFiles(in: transfers).isEmpty)
        for (url, bytes) in preserved { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        XCTAssertEqual(try Data(contentsOf: working.url), newer)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
        probe.scan(stage: "completed-cleanup")
        for upload in await fixture.cloud.uploadedRecords() {
            try PrivacyArtifactProbe.assertEncrypted([JSONEncoder().encode(upload.record)] + upload.chunks, markers: markers)
        }
        let evidence = probe.evidence
        XCTAssertTrue(evidence.errors.isEmpty, evidence.errors.joined(separator: "\n"))
        XCTAssertEqual(evidence.stages, ["frozen-conflict", "reopened-preparation", "pending-cleanup", "completed-cleanup"])
        XCTAssertGreaterThan(evidence.encryptedFiles, 0)
    }

    private func privacyCiphertextFiles(in root: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "ciphertext" }
    }

    @MainActor
    func testInterruptedTreeArtifactsKeepContentNamesAndMetadataEncrypted() async throws {
        guard let privateTemporaryPath = ProcessInfo.processInfo.environment[PrivacySubprocess.rootKey] else {
            let result = try await PrivacySubprocess.run(bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testInterruptedTreeArtifactsKeepContentNamesAndMetadataEncrypted")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("Executed 1 test"), result.output)
            return
        }
        let temporary = URL(fileURLWithPath: privateTemporaryPath).resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("Scenario")
        removeClipboardHistoryDirectoryAfterTest(root)
        let senderRoot = root.appendingPathComponent("Sender")
        let receiverRoot = root.appendingPathComponent("Receiver")
        let original = root.appendingPathComponent("private-original-orchid-folder")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let memberName = "private-member-lantern.txt"
        let member = original.appendingPathComponent(memberName)
        let contents = Data("private content copper horizon".utf8) + Data(repeating: 0x41, count: 5_000_001)
        try contents.write(to: member)
        let attribute = Data("private attribute silver orchard".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes { setxattr(member.path, "com.example.AnyDoor.privacy", $0.baseAddress, $0.count, 0, 0) }, 0)
        let fork = Data("private resource fork violet harbor".utf8)
        try fork.write(to: member.appendingPathComponent("..namedfork/rsrc"))
        let markers = ["private-original-orchid-folder", memberName, "private content copper horizon",
            "private attribute silver orchard", "private resource fork violet harbor", "private tag amber meadow", original.path]
        let probe = PrivacyArtifactProbe(roots: [senderRoot, receiverRoot], markers: markers, observesScratch: true)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: senderRoot, services: services, key: 0x51, faultInjector: .init { point in
            if point == .syncFileTreeBeforeFreezeVerification { probe.scan(stage: "frozen") }
            return false
        })
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0x52, faultInjector: .init { point in
            guard point == .syncFileTreeBeforeMetadata else { return false }
            probe.inspectConstruction(in: receiverRoot.appendingPathComponent("Linked Working Copies"),
                memberName: memberName, contents: contents)
            return true
        })
        let board = NSPasteboard(name: .init("dev.bybee.AnyDoor.privacy.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let captured) = try await sender.capture(.init(pasteboard: board), source: .unknown) else {
            return XCTFail("Expected real tree capture")
        }
        let tag = try await sender.createTagDefinition(named: "private tag amber meadow", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let page = try await receiver.page(.init())
        let file = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertGreaterThan(try XCTUnwrap(file.originalByteCount), 5_000_000)
        XCTAssertFalse(file.downloadRequested)
        XCTAssertNotEqual(file.state, .complete)
        probe.expect(version: file.versionID, object: file.id)
        await cloud.holdNextDownload(at: 1)
        addTeardownBlock { await cloud.releaseDownload() }
        let downloading = Task {
            try await receiver.requestSyncFileDownload(entryID: captured.entryID, objectID: file.id, versionID: file.versionID)
        }
        try await eventually { await cloud.downloadIsHeld() }
        let partial = try await receiver.page(.init())
        XCTAssertGreaterThan(try XCTUnwrap(partial.entries.first?.syncFiles.first?.transferredByteCount), 0)
        probe.scan(stage: "partial")
        await cloud.releaseDownload()
        try await downloading.value
        let failed = try await receiver.page(.init())
        XCTAssertNotEqual(failed.entries.first?.syncFiles.first?.state, .complete)
        do {
            _ = try await receiver.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
            XCTFail("An interrupted ordinary candidate must not materialize")
        } catch ClipboardHistoryModuleError.syncFilesPending { }
        let pendingNotices = try await receiver.workingOutputRecoveries()
        XCTAssertEqual(pendingNotices.count, probe.candidates.count)
        XCTAssertEqual(Set(pendingNotices.map { $0.url.resolvingSymlinksInPath() }),
            Set(probe.candidates.map { $0.resolvingSymlinksInPath() }))
        for notice in pendingNotices {
            XCTAssertEqual(notice.reason, .incomplete)
            XCTAssertEqual(try Data(contentsOf: notice.url.appendingPathComponent(memberName)), contents)
        }
        probe.scan(stage: "interrupted")
        let uploads = await cloud.uploadedRecords()
        XCTAssertTrue(uploads.contains { $0.record.kind == .fileBody })
        for upload in uploads {
            try PrivacyArtifactProbe.assertEncrypted([JSONEncoder().encode(upload.record)] + upload.chunks, markers: markers)
        }
        try await receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: receiverRoot, services: services, key: 0x52, faultInjector: .init { point in
            if point == .linkedFileBeforeReplacement { probe.inspectReplacement() }
            return false
        })
        let retainedNotices = try await reopened.workingOutputRecoveries()
        XCTAssertEqual(retainedNotices.map(\.id), pendingNotices.map(\.id))
        for notice in retainedNotices {
            try await reopened.keepWorkingOutput(notice.id)
            XCTAssertEqual(try Data(contentsOf: notice.url.appendingPathComponent(memberName)), contents)
        }
        await reopened.resumeSync()
        await reopened.retrySync()
        let materialized = try await reopened.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        guard case .file(let complete) = materialized.items.first?.representations.first else {
            return XCTFail("Expected verified working tree after retry")
        }
        XCTAssertEqual(try Data(contentsOf: complete.currentURL.appendingPathComponent(memberName)), contents)
        XCTAssertEqual(try Data(contentsOf: complete.currentURL.appendingPathComponent(memberName + "/..namedfork/rsrc")), fork)
        probe.allowVisible(complete.currentURL)
        probe.scan(stage: "reopened")
        try await sender.setSyncEnabled(false)
        let update = contents + Data(" changed contents".utf8)
        try update.write(to: member)
        try await sender.setSyncEnabled(true)
        await reopened.retrySync()
        let updatePage = try await reopened.page(.init())
        let updateFile = try XCTUnwrap(updatePage.entries.first?.syncFiles.first)
        XCTAssertNotEqual(updateFile.versionID, file.versionID)
        XCTAssertFalse(updateFile.downloadRequested)
        let account = await cloud.account()
        let verified = receiverRoot.appendingPathComponent("Linked Working Copies")
            .appendingPathComponent(account.identifier).appendingPathComponent(file.id.uuidString.lowercased())
            .appendingPathComponent(updateFile.versionID.uuidString.lowercased()).appendingPathComponent(original.lastPathComponent)
        probe.expectReplacement(at: complete.currentURL, verified: verified, member: memberName, contents: update)
        try await reopened.requestSyncFileDownload(entryID: captured.entryID, objectID: file.id, versionID: updateFile.versionID)
        let updated = try await reopened.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        guard case .file(let updatedFile) = updated.items.first?.representations.first else {
            return XCTFail("Expected linked replacement after explicit download")
        }
        XCTAssertEqual(updatedFile.currentURL, complete.currentURL)
        XCTAssertEqual(try Data(contentsOf: updatedFile.currentURL.appendingPathComponent(memberName)), update)
        probe.scan(stage: "updated")
        let evidence = probe.evidence
        XCTAssertTrue(evidence.errors.isEmpty, evidence.errors.joined(separator: "\n"))
        XCTAssertTrue(evidence.stages.isSuperset(of: ["frozen", "partial", "constructing", "interrupted", "reopened", "replacement", "updated"]))
        XCTAssertEqual(evidence.sidecars.count, 1, "Only the proven, complete source-parent replacement is a readable sidecar")
        XCTAssertTrue(evidence.inventoryObserved)
        XCTAssertTrue(evidence.parserObserved)
        XCTAssertGreaterThan(evidence.encryptedFiles, 0)
        XCTAssertFalse(probe.candidates.isEmpty, "The plaintext exception must be an actually observed, owned reconstruction")
    }
}

private final class PrivacyArtifactProbe: @unchecked Sendable {
    struct Replacement {
        let destination: URL
        let verified: URL
        let member: String
        let contents: Data
    }
    struct Evidence {
        var errors: [String] = []
        var stages: Set<String> = []
        var allowed: [URL] = []
        var candidates: [URL] = []
        var expectedVersion: UUID?
        var expectedObject: UUID?
        var inventoryObserved = false
        var parserObserved = false
        var encryptedFiles = 0
        var replacement: Replacement?
        var sidecars: [URL] = []
    }
    let roots: [URL]
    let observesScratch: Bool
    let markers: [String]
    private let state = OSAllocatedUnfairLock(initialState: Evidence())
    init(roots: [URL], markers: [String], observesScratch: Bool = false) {
        self.roots = roots
        self.markers = markers
        self.observesScratch = observesScratch
    }
    var evidence: Evidence { state.withLock { $0 } }
    var candidates: [URL] { state.withLock { $0.candidates } }
    func expect(version: UUID, object: UUID) {
        state.withLock { $0.expectedVersion = version; $0.expectedObject = object }
    }
    func allowVisible(_ url: URL) { state.withLock { $0.allowed.append(url.standardizedFileURL) } }
    func expectReplacement(at destination: URL, verified: URL, member: String, contents: Data) {
        state.withLock { $0.replacement = .init(destination: destination, verified: verified, member: member, contents: contents) }
    }
    func inspectReplacement() {
        guard let replacement = evidence.replacement else { return }
        do {
            let siblings = try FileManager.default.contentsOfDirectory(at: replacement.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            let candidates = siblings.filter { $0.lastPathComponent.hasPrefix(replacement.destination.lastPathComponent + " (AnyDoor update ") }
            guard candidates.count == 1, let candidate = candidates.first,
                  try Data(contentsOf: candidate.appendingPathComponent(replacement.member)) == replacement.contents,
                  try Data(contentsOf: replacement.verified.appendingPathComponent(replacement.member)) == replacement.contents else {
                throw PrivacyScanError.invalidCandidate
            }
            allowVisible(replacement.verified)
            allowVisible(candidate)
            state.withLock { $0.sidecars.append(candidate) }
            scan(stage: "replacement")
        } catch { state.withLock { $0.errors.append("replacement: \(error)") } }
    }
    func inspectConstruction(in root: URL, memberName: String, contents: Data) {
        do {
            let expected = evidence
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            let matches = (files?.allObjects as? [URL] ?? []).filter {
                $0.lastPathComponent.hasPrefix("Receiving-") && $0.pathExtension == "partial"
                    && $0.deletingLastPathComponent().lastPathComponent == expected.expectedVersion?.uuidString.lowercased()
                    && $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == expected.expectedObject?.uuidString.lowercased()
            }
            guard matches.count == 1, let candidate = matches.first,
                  try Data(contentsOf: candidate.appendingPathComponent(memberName)) == contents else {
                throw PrivacyScanError.invalidCandidate
            }
            state.withLock { $0.candidates.append(candidate) }
            allowVisible(candidate)
            scan(stage: "constructing")
        } catch { state.withLock { $0.errors.append("construction: \(error)") } }
    }
    func scan(stage: String) {
        do {
            let scratch = observesScratch ? try Self.openScratchRoots() : []
            let allowed = evidence.allowed
            var count = 0
            for root in roots + scratch where FileManager.default.fileExists(atPath: root.path) {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    throw PrivacyScanError.unreadableArtifact
                }
                for case let url as URL in enumerator {
                    if allowed.contains(where: { url.standardizedFileURL.path == $0.path || url.path.hasPrefix($0.path + "/") }) {
                        enumerator.skipDescendants()
                        continue
                    }
                    try Self.assertEncrypted([Data(url.path.utf8)], markers: markers)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw PrivacyScanError.unexpectedBackgroundLink }
                    if values.isRegularFile == true {
                        try Self.assertEncrypted([Data(contentsOf: url)], markers: markers)
                        count += 1
                    }
                }
            }
            let observedCount = count
            state.withLock {
                $0.stages.insert(stage)
                $0.inventoryObserved = $0.inventoryObserved || scratch.contains { !$0.lastPathComponent.hasPrefix("AnyDoor-tree-parse-") }
                $0.parserObserved = $0.parserObserved || scratch.contains { $0.lastPathComponent.hasPrefix("AnyDoor-tree-parse-") }
                $0.encryptedFiles += observedCount
            }
        } catch { state.withLock { $0.errors.append("\(stage): \(error)") } }
    }
    /// The isolated child runs only this scenario. Resolve its own open file
    /// descriptors instead of enumerating the user's global temporary folder.
    private static func openScratchRoots() throws -> [URL] {
        var roots: Set<URL> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let descriptor = Int32(name) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { continue }
            let file = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            let parent = file.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("AnyDoor-tree-"),
               file.lastPathComponent == "inventory.sqlite" || file.lastPathComponent == "entries.sqlite" {
                roots.insert(parent)
            }
        }
        return Array(roots)
    }

    static func assertEncrypted(_ values: [Data], markers: [String]) throws {
        for value in values {
            for marker in markers where value.range(of: Data(marker.utf8)) != nil {
                throw PrivacyScanError.readableMarker(marker)
            }
        }
    }
}

private enum PrivacyScanError: Error {
    case invalidCandidate, unreadableArtifact, unexpectedBackgroundLink
    case readableMarker(String)
}

private enum PrivacySubprocess {
    static let rootKey = "ANYDOOR_PRIVACY_TEST_ROOT"
    struct Result: Sendable { let status: Int32; let output: String }

    /// A single-case process makes open inventory descriptors attributable to
    /// this scenario, without changing another test's process environment.
    @concurrent static func run(bundle: URL, test: String) async throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-test-process-\(UUID())")
        let scratch = root.appendingPathComponent("Scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("child.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw PrivacyScanError.unreadableArtifact }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        process.arguments = ["-XCTest", test, bundle.path]
        var environment = ProcessInfo.processInfo.environment
        environment[rootKey] = scratch.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let transcript = try String(contentsOf: log, encoding: .utf8)
        return .init(status: process.terminationReason == .exit ? process.terminationStatus : -1, output: transcript)
    }
}
