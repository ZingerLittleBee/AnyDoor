import AppKit
import Foundation
import os
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testMixedPageSyncWorkDoesNotGrowWithUnrelatedFileMemberships() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.sender.suspendSync()
        try await fixture.receiver.closeStoreForTesting()
        let probe = ClipboardHistorySQLWorkProbe(table: "clipboard_sync_")
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: fixture.receiverRoot, keyStore: SearchEnrichmentLocalKey(),
            syncServices: fixture.services, testingDatabasePreparation: { probe.install(on: $0) }))
        let content = try await searchFixtureContent(cloud: fixture.cloud, services: fixture.services)
        for index in 0..<100 {
            try await publishSearchEntry(index: index, descriptor: content.descriptor, favorite: true,
                tags: content.tags, cloud: fixture.cloud, key: content.key)
        }
        var measured: [[Int64]] = []
        var pages: [[ClipboardHistoryPage]] = []
        for batch in 0..<2 {
            for index in (batch * 100)..<((batch + 1) * 100) {
                let unrelated = ClipboardSyncFileDescriptor(objectID: UUID(), versionID: UUID(),
                    displayName: "Unrelated \(index).txt", originalByteCount: nil, contentDigest: nil,
                    body: nil, state: .sourceUnavailable)
                try await publishSearchEntry(index: index, descriptor: unrelated, favorite: false,
                    tags: content.tags, cloud: fixture.cloud, key: content.key)
            }
            await receiver.resumeSync()
            await receiver.suspendSync()
            var work: [Int64] = []
            var results: [ClipboardHistoryPage] = []
            for query in [ClipboardHistoryQuery(favoritesOnly: true), .init(text: "needle", favoritesOnly: true)] {
                probe.start()
                let page = try await receiver.page(query)
                let instructions = probe.stop()
                work.append(instructions)
                results.append(page)
                XCTAssertEqual(page.entries.count, 100)
                XCTAssertTrue(page.entries.allSatisfy { $0.syncFiles.count == 1 && $0.syncFiles.first?.state == .complete })
                XCTAssertTrue(page.entries.allSatisfy { $0.linkedFileLocations.count == 1 && !$0.hasTextConflict })
                XCTAssertNil(page.nextCursor)
                XCTAssertGreaterThan(instructions, 0, "The native observer must see the real page SQL")
            }
            measured.append(work)
            pages.append(results)
        }
        XCTAssertEqual(pages[0], pages[1], "Unrelated sync records must not change the visible page")
        for index in 0..<2 {
            print("SEARCH_ENRICHMENT_VM mode=\(index == 0 ? "browse" : "search") unrelated=100/200 steps=\(measured[0][index])/\(measured[1][index])")
            XCTAssertLessThanOrEqual(measured[1][index], measured[0][index] * 6 / 5,
                "A fixed page must not scan unrelated sync memberships for every result")
        }
    }

    @MainActor
    func testPageReadsAccountContextOnceForOneOrOneHundredMixedResults() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.sender.suspendSync()
        try await fixture.receiver.closeStoreForTesting()
        let probe = ClipboardHistorySQLWorkProbe(table: "clipboard_sync_accounts")
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: fixture.receiverRoot, keyStore: SearchEnrichmentLocalKey(),
            syncServices: fixture.services, testingDatabasePreparation: { probe.install(on: $0) }))
        let content = try await searchFixtureContent(cloud: fixture.cloud, services: fixture.services)
        for index in 0..<100 {
            try await publishSearchEntry(index: index, descriptor: content.descriptor, favorite: true,
                tags: content.tags, cloud: fixture.cloud, key: content.key)
        }
        await receiver.resumeSync()
        await receiver.suspendSync()
        var work: [Int64] = []
        for (query, count) in [("needle mixed result 99", 1), ("needle", 100)] {
            probe.start()
            let page = try await receiver.page(.init(text: query, favoritesOnly: true))
            work.append(probe.stop())
            XCTAssertEqual(page.entries.count, count)
            XCTAssertTrue(page.entries.allSatisfy { $0.syncFiles.first?.state == .complete })
        }
        print("SEARCH_ACCOUNT_CONTEXT_VM rows=1/100 steps=\(work[0])/\(work[1])")
        XCTAssertGreaterThan(work[0], 0)
        XCTAssertEqual(work[0], work[1], "The account context belongs to the page, not each result")
    }

    @MainActor
    func testPageShowsPendingRestorationOwnedByAnotherEntryAndClearsRevokedWork() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileVerificationSegment, armed.withLock({ $0 }) { barrier.pause() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("shared tree body".utf8).write(to: root.appendingPathComponent("member"))
        })
        await fixture.sender.suspendSync()
        let content = try await searchFixtureContent(cloud: fixture.cloud, services: fixture.services)
        for index in 0..<2 {
            try await publishSearchEntry(index: index, descriptor: content.descriptor, favorite: true,
                tags: content.tags, cloud: fixture.cloud, key: content.key)
        }
        await fixture.receiver.retrySync()
        let initial = try await fixture.receiver.page(.init(favoritesOnly: true))
        XCTAssertEqual(initial.entries.count, 2)
        XCTAssertFalse(initial.entries.contains { $0.id == fixture.entryID })
        XCTAssertTrue(initial.entries.allSatisfy { $0.syncFiles.first?.uploadPending == false })
        _ = try await fixture.receiver.apply(.setTags(fixture.entryID, []))
        await fixture.receiver.retrySync()
        armed.withLock { $0 = true }
        let rejoin = Task {
            _ = try await fixture.receiver.apply(.setTags(fixture.entryID, Set(content.tags.map(\.id))))
            await fixture.receiver.retrySync()
        }
        try await eventually { barrier.isWaiting }
        let pending = try await fixture.receiver.page(.init(favoritesOnly: true))
        XCTAssertEqual(pending.entries.map(\.id), initial.entries.map(\.id))
        XCTAssertTrue(pending.entries.allSatisfy { $0.syncFiles.first?.uploadPending == true },
            "A hidden entry's active journal still owns work for this shared file object")
        _ = try await fixture.receiver.apply(.setTags(fixture.entryID, []))
        let revoked = try await fixture.receiver.page(.init(favoritesOnly: true))
        XCTAssertTrue(revoked.entries.allSatisfy { $0.syncFiles.first?.uploadPending == false })
        armed.withLock { $0 = false }
        barrier.release()
        try await rejoin.value
    }

    @MainActor
    func testFreshMixedPageReflectsFileLossAndReceivedTextAndFileConflicts() async throws {
        let fixture = try await makeLinkedFixture(sourceName: "needle-linked.txt")
        let definitions = try await fixture.sender.tagDefinitions()
        let tag = try XCTUnwrap(definitions.first)
        let text = try await fixture.sender.capture(.init(source: .unknown, content: .text("needle editable text")))
        _ = try await fixture.sender.apply(.setTags(text.entryID, [tag.id]))
        let secondURL = fixture.root.appendingPathComponent("needle-second.txt")
        let secondBytes = Data("independent second file".utf8)
        try secondBytes.write(to: secondURL)
        let board = NSPasteboard(name: .init("dev.bybee.AnyDoor.search-freshness.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString(secondURL.absoluteString, forType: .fileURL)
        guard case .captured(let second) = try await fixture.sender.capture(.init(pasteboard: board), source: .unknown) else {
            return XCTFail("Expected second real file capture")
        }
        _ = try await fixture.sender.apply(.setTags(second.entryID, [tag.id]))
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let before = try await fixture.receiver.page(.init(text: "needle"))
        XCTAssertEqual(before.entries.count, 3)
        XCTAssertTrue(before.entries.flatMap(\.syncFiles).allSatisfy { $0.state == .complete && !$0.hasConflict })
        XCTAssertFalse(before.entries.contains(where: \.hasTextConflict))
        let opened = try await fixture.receiver.textEditPlan(for: text.entryID)
        _ = try await fixture.sender.apply(.editText(text.entryID, "needle remote text"))
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        _ = try await fixture.receiver.saveTextEdit("needle draft from old basis", using: opened)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        await fixture.sender.suspendSync()
        for branch in ["first branch", "second branch"] {
            _ = try await commitConflictRemoteFile(bytes: Data(branch.utf8), versionID: UUID(),
                parents: [working.baseVersionID], objectID: working.objectID,
                root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        }
        await fixture.receiver.retrySync()
        let conflicted = try await fixture.receiver.page(.init(text: "needle"))
        XCTAssertEqual(conflicted.entries.first { $0.id == text.entryID }?.hasTextConflict, true)
        XCTAssertEqual(conflicted.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.hasConflict, true)
        XCTAssertEqual(conflicted.entries.first { $0.id == second.entryID }?.syncFiles.first?.hasConflict, false)
        try FileManager.default.removeItem(at: working.url)
        let unavailable = try await fixture.receiver.page(.init(text: "needle"))
        XCTAssertEqual(unavailable.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.state, .localUnavailable)
        XCTAssertEqual(unavailable.entries.first { $0.id == second.entryID }?.syncFiles.first?.state, .complete)
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
            XCTFail("A previous complete page cannot authorize a missing file")
        } catch ClipboardHistoryModuleError.fileReferencesUnavailable {}
        let retained = try await fixture.receiver.materialize(.init(entryID: second.entryID, purpose: .normalPaste))
        guard case .file(let file) = retained.items.first?.representations.first else { return XCTFail("Expected independent file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), secondBytes)
        let plan = try await fixture.receiver.textEditPlan(for: text.entryID)
        let chosen = try XCTUnwrap(plan.versions.first)
        _ = try await fixture.receiver.resolveTextConflict(.init(plan: plan, versionID: chosen.id))
        let resolved = try await fixture.receiver.page(.init(text: "needle"))
        XCTAssertEqual(resolved.entries.first { $0.id == text.entryID }?.hasTextConflict, false)
    }

    @MainActor
    private func searchFixtureContent(cloud: LinkedFileCloud, services: ClipboardSyncServices) async throws
        -> (descriptor: ClipboardSyncFileDescriptor, tags: [ClipboardSyncTagContent], key: Data) {
        let account = await cloud.account()
        let current = await cloud.control(for: account)
        let control = try XCTUnwrap(current)
        let loaded = try await services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let uploads = await cloud.uploadedRecords()
        for upload in uploads where upload.record.kind == .entry {
            if case .entry(let entry) = try ClipboardSyncCodec.open(upload.record, chunks: upload.chunks,
                account: account, control: control, key: key) {
                for representation in entry.items.flatMap(\.representations) {
                    if case .file(let descriptor) = representation { return (descriptor, entry.tags, key) }
                }
            }
        }
        throw ClipboardHistoryModuleError.operationUnavailable
    }

    /// Publish at the external transport boundary using the real encrypted format.
    /// Repeated references deliberately share the existing, actually downloaded file.
    @MainActor
    private func publishSearchEntry(index: Int, descriptor: ClipboardSyncFileDescriptor, favorite: Bool,
        tags: [ClipboardSyncTagContent], cloud: LinkedFileCloud, key: Data) async throws {
        let account = await cloud.account()
        let current = await cloud.control(for: account)
        let control = try XCTUnwrap(current)
        let text = favorite ? "needle mixed result \(index)" : "unrelated content \(index)"
        let content = ClipboardSyncEntryContent(id: UUID(), capturedAt: Date(), sourceBundleID: nil,
            sourceDisplayName: nil, sourceProvenance: "unknown", favorite: favorite, tags: tags,
            items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: text)]),
                    .init(representations: [.file(descriptor)])], facets: ["text", "file"], recognition: .init())
        let upload = try ClipboardSyncCodec.seal(.entry(content), account: account, control: control, key: key)
        _ = try await cloud.commit(upload, for: account, control: control)
    }
}

private struct SearchEnrichmentLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x52, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}
