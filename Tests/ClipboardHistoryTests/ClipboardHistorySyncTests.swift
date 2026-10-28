import AppKit
import Foundation
import XCTest
import ClipboardHistoryTestSupport
import os

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    @MainActor
    func testSelectedOrdinaryFileArrivesAsUsableHistoryWithoutChangingPasteboard() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x71, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x72, time: 2_000)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-file-source-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let original = sourceRoot.appendingPathComponent("Private notes.txt")
        let expected = Data("a complete ordinary file\n".utf8)
        try expected.write(to: original)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-file-tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "com.apple.finder", displayName: "Finder")
        let outcome = try await first.capture(.init(pasteboard: pasteboard), source: source)
        guard case .captured(let captured) = outcome else {
            return XCTFail("Expected the original file reference to be captured")
        }
        let tag = try await first.createTagDefinition(named: "Shared files", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("leave the current clipboard alone", forType: .string)
        let generation = pasteboard.changeCount

        try await second.setSyncEnabled(true)

        let page = try await second.page(.init(tagID: tag.definition.id))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(received.source, source)
        XCTAssertTrue(received.facets.contains(.file))
        let materialized = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        guard materialized.items.count == 1,
              case .file(let file) = materialized.items[0].representations.first else {
            return XCTFail("Expected one complete working-file representation")
        }
        XCTAssertEqual(file.displayName, "Private notes.txt")
        XCTAssertNotEqual(file.currentURL, original)
        XCTAssertEqual(try Data(contentsOf: file.currentURL), expected)
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "leave the current clipboard alone")
    }

    @MainActor
    func testOrderedRichTextAndLinkRepresentationsTransferAsOneCompleteEntry() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x81, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x82, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-rich.\(UUID())"))
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        let rtf = Data(#"{\rtf1\ansi Shared rich words}"#.utf8)
        let html = Data("<p>Shared rich words</p>".utf8)
        rich.setString(" Shared exact words\r\n", forType: .string)
        rich.setData(rtf, forType: .rtf)
        rich.setData(html, forType: .html)
        let link = NSPasteboardItem()
        link.setString("Example link", forType: .string)
        link.setString("https://example.com/shared", forType: .URL)
        XCTAssertTrue(pasteboard.writeObjects([rich, link]))
        let captured = try await first.capture(.init(pasteboard: pasteboard), source: .unknown)
        guard case .captured(let outcome) = captured else { return XCTFail("Expected a complete captured entry") }
        let tag = try await first.createTagDefinition(named: "Rich", assigningTo: outcome.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("receiver sentinel", forType: .string)
        let generation = pasteboard.changeCount
        try await second.setSyncEnabled(true)
        let page = try await second.page(.init(tagID: tag.definition.id))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        let normal = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(normal.items, [
            .init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: " Shared exact words\r\n"),
                .data(typeIdentifier: "public.rtf", rtf), .data(typeIdentifier: "public.html", html)]),
            .init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "Example link"),
                .text(typeIdentifier: "public.url", value: "https://example.com/shared")]),
        ])
        let plain = try await second.materialize(.init(entryID: received.id, purpose: .plainTextPaste))
        XCTAssertEqual(plain.items.count, 2)
        let search = try await second.page(.init(text: "Shared rich words"))
        XCTAssertEqual(search.entries.map(\.id), [received.id])
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "receiver sentinel")
    }

    func testDisableRevokesActivationDeferredByProviderBackoff() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x17,
            time: 1_000, clock: { clock.withLock { $0 } })
        try await module.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await module.retrySync()
        await cloud.switchAccount(to: "account-B")
        try await module.setSyncEnabled(true)
        try await module.setSyncEnabled(false)
        let readsBeforeDeadline = await cloud.accountReadCount()
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let status = await module.syncStatus()
        let readsAfterDeadline = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(readsAfterDeadline, readsBeforeDeadline)
        XCTAssertEqual(keyCount, 1)
    }

    func testExplicitNewAccountActivationSurvivesProviderBackoff() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x16,
            time: 1_000, clock: { clock.withLock { $0 } })
        try await module.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await module.retrySync()
        await cloud.switchAccount(to: "explicitly-enabled-account-B")
        try await module.setSyncEnabled(false)
        try await module.setSyncEnabled(true)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let status = await module.syncStatus()
        let keyCount = await keys.count()
        XCTAssertTrue(status.isEnabled)
        XCTAssertEqual(status.phase, .upToDate)
        XCTAssertEqual(keyCount, 2)
    }

    func testDamagedCiphertextDoesNotImportAndRetryKeepsTheUnreadCursor() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x14, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x15, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("authenticated history")))
        let tag = try await first.createTagDefinition(named: "Authenticated", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        await cloud.damageNextDownload()
        try await second.setSyncEnabled(true)
        let rejected = await second.syncStatus()
        let empty = try await second.page(.init())
        XCTAssertEqual(rejected.phase, .failed(.corruptData))
        XCTAssertTrue(empty.entries.isEmpty)
        await second.retrySync()
        let recovered = try await second.page(.init())
        XCTAssertEqual(recovered.entries.count, 1)
        let complete = await second.syncStatus()
        XCTAssertEqual(complete.phase, .upToDate)
    }

    func testRetryWaitsForProviderDelayBeforeConsultingCloudAgain() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x13,
            time: 1_000, clock: { clock.withLock { $0 } })
        await cloud.failNextAccountRead(retryAfter: 120)
        try await module.setSyncEnabled(true)
        let waiting = await module.syncStatus()
        XCTAssertEqual(waiting.phase, .failed(.network))
        await module.retrySync()
        let earlyReads = await cloud.accountReadCount()
        XCTAssertEqual(earlyReads, 1)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let recovered = await module.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
    }

    func testRemoteTagInNewAccountDoesNotAuthorizeOldAccountHistory() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x11, time: 1_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("account A private text")))
        let tag = try await first.createTagDefinition(named: "Retained identity", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)

        await cloud.switchAccount(to: "account-B")
        await first.retrySync()
        let peer = makeModule(services: services, keyByte: 0x12, time: 2_000)
        _ = try await peer.replaceTagDefinitions(with: [tag.definition])
        try await peer.setSyncTagSelected(tag.definition.id, selected: true)
        try await peer.setSyncEnabled(true)
        try await first.setSyncEnabled(true)
        let beforeAuthorization = await cloud.currentUploads()
        XCTAssertTrue(beforeAuthorization.allSatisfy { $0.record.kind == .tag })

        let fresh = try await first.capture(.init(source: .unknown, content: .text("new account B text")))
        _ = try await first.apply(.setTags(fresh.entryID, [tag.definition.id]))
        await first.retrySync()
        let afterFreshCapture = await cloud.currentUploads()
        XCTAssertEqual(afterFreshCapture.filter { $0.record.kind == .entry }.count, 1)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        let afterExplicitSelection = await cloud.currentUploads()
        XCTAssertEqual(afterExplicitSelection.filter { $0.record.kind == .entry }.count, 2)
    }

    func testInterruptedBootstrapWaitsForItsJournaledCandidateKeyBeforePublishingControl() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-bootstrap-\(UUID())")
        let first = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x19, time: 1_000, root: root)
        await cloud.failNextControlCreation()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        try await first.closeStoreForTesting()

        let delayedKeys = SyncTestDelayedKeys(backing: keys)
        let reopened = makeModule(services: .init(transport: cloud, keys: delayedKeys, pollingInterval: nil), keyByte: 0x19, time: 2_000, root: root)
        await reopened.resumeSync()
        let waiting = await reopened.syncStatus()
        let account = try await cloud.account()
        let unpublished = try await cloud.control(for: account)
        let waitingAttempts = await cloud.controlCreationAttempts()
        XCTAssertEqual(waiting.phase, .waitingForKey)
        XCTAssertNil(unpublished)
        XCTAssertEqual(waitingAttempts.count, 1)

        await delayedKeys.deliver()
        await reopened.retrySync()
        let published = try await cloud.control(for: account)
        let allAttempts = await cloud.controlCreationAttempts()
        let keyCount = await keys.count()
        XCTAssertEqual(published?.keyID, waitingAttempts.first)
        XCTAssertEqual(Set(allAttempts).count, 1)
        XCTAssertEqual(keyCount, 1)
        let completed = await reopened.syncStatus()
        XCTAssertEqual(completed.phase, .upToDate)
    }

    func testLaterDisableWinsWhenEarlierEnableFinishesCancellationLate() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x18, time: 1_000)
        await cloud.holdNextCancellation()
        let enabling = Task { try await module.setSyncEnabled(true) }
        await cloud.waitForHeldCancellation()
        try await module.setSyncEnabled(false)
        await cloud.releaseCancellation()
        try await enabling.value
        let status = await module.syncStatus()
        let accountReads = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertEqual(accountReads, 0)
        XCTAssertEqual(keyCount, 0)
    }

    func testDisabledResumeDoesNotConsultCloudOrCreateSyncKeys() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x21, time: 1_000)
        await module.resumeSync()
        let reads = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(keyCount, 0)
        let records = await cloud.currentUploads()
        XCTAssertTrue(records.isEmpty)
    }

    func testSimultaneousFirstUseSelectsOneKeyAndBothDevicesReadTheCollection() async throws {
        let cloud = SyncTestCloud()
        await cloud.rendezvousInitialControlReads()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x23, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x24, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("one agreed key")))
        let tag = try await first.createTagDefinition(named: "Race", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        async let enableFirst: Void = first.setSyncEnabled(true)
        async let enableSecond: Void = second.setSyncEnabled(true)
        _ = try await (enableFirst, enableSecond)
        await first.retrySync()
        await second.retrySync()
        let created = await keys.count()
        XCTAssertEqual(created, 2, "Both isolated candidates must exist before the server chooses its winner")
        let published = await cloud.currentUploads()
        XCTAssertEqual(Set(published.map(\.record.keyID)).count, 1)
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let final = await second.syncStatus()
        XCTAssertEqual(final.phase, .upToDate)
    }

    func testLargeTextUsesEncryptedChunksAndDoesNotShareAnUnselectedTag() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x25, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x26, time: 2_000)
        let value = String(repeating: "z", count: 4 * 1_024 * 1_024) + " confidential end marker"
        let entry = try await first.capture(.init(source: .unknown, content: .text(value)))
        let shared = try await first.createTagDefinition(named: "Shared secret label", assigningTo: entry.entryID)
        _ = try await first.createTagDefinition(named: "Local private label", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(shared.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let uploads = await cloud.currentUploads()
        let textUpload = try XCTUnwrap(uploads.first { $0.record.kind == .entry })
        XCTAssertGreaterThan(textUpload.chunks.count, 1)
        for upload in uploads {
            let metadata = try JSONEncoder().encode(upload.record)
            for data in [metadata] + upload.chunks {
                XCTAssertNil(data.range(of: Data("Shared secret label".utf8)))
                XCTAssertNil(data.range(of: Data("Local private label".utf8)))
                XCTAssertNil(data.range(of: Data("confidential end marker".utf8)))
            }
        }
        try await second.setSyncEnabled(true)
        let tags = try await second.tagDefinitions()
        XCTAssertEqual(tags.map(\.id), [shared.definition.id])
        let page = try await second.page(.init())
        let received = try XCTUnwrap(page.entries.first)
        let materialized = try await second.materialize(.init(entryID: received.id, purpose: .plainTextPaste))
        XCTAssertEqual(materialized.items.first?.representations, [.text(typeIdentifier: "public.utf8-plain-text", value: value)])
    }

    func testMissingPreviouslyObservedControlNeverReinitializesOrReplacesKey() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x28, time: 1_000)
        try await module.setSyncEnabled(true)
        await cloud.removeControl()
        await module.retrySync()
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .failed(.recoveryRequired))
        let count = await keys.count()
        XCTAssertEqual(count, 1)
        let account = try await cloud.account()
        let control = try await cloud.control(for: account)
        XCTAssertNil(control)
    }

    func testLostCommitResponseAndRestartReuseFrozenOperationWithoutDuplicateImport() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-restart-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x51, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x52, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("survives lost response")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        await cloud.loseNextEntryCommitResponse()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        try await first.closeStoreForTesting()

        try await second.setSyncEnabled(true)
        let next = try await second.capture(.init(source: .unknown, content: .text("peer advances control")))
        _ = try await second.apply(.setTags(next.entryID, [tag.definition.id]))
        await second.retrySync()
        let publishedBeforeRetry = await cloud.currentUploads()
        let reopened = makeModule(services: services, keyByte: 0x51, time: 3_000, root: root)
        await reopened.resumeSync()
        await reopened.retrySync()
        await second.retrySync()
        let publishedAfterRetry = await cloud.currentUploads()
        XCTAssertEqual(publishedAfterRetry, publishedBeforeRetry)
        let received = try await second.page(.init())
        let restored = try await reopened.page(.init())
        XCTAssertEqual(received.entries.count, 2)
        XCTAssertEqual(restored.entries.count, 2)
        let restoredState = await reopened.syncStatus()
        XCTAssertEqual(restoredState.phase, .upToDate)
        XCTAssertEqual(restoredState.uploadedEntryCount, 1)
    }

    func testDelayedSharedKeyWaitsWithoutReplacingCiphertextAndResumes() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let first = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x61, time: 1_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("wait for system key delivery")))
        let tag = try await first.createTagDefinition(named: "Secret label", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let encryptedBefore = await cloud.currentUploads()
        let delayedKeys = SyncTestDelayedKeys(backing: keys)
        let second = makeModule(services: .init(transport: cloud, keys: delayedKeys, pollingInterval: nil), keyByte: 0x62, time: 2_000)
        try await second.setSyncEnabled(true)
        let waiting = await second.syncStatus()
        XCTAssertEqual(waiting.phase, .waitingForKey)
        let empty = try await second.page(.init())
        XCTAssertTrue(empty.entries.isEmpty)
        let encryptedAfter = await cloud.currentUploads()
        XCTAssertEqual(encryptedAfter, encryptedBefore)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        await delayedKeys.deliver()
        await second.retrySync()
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let complete = await second.syncStatus()
        XCTAssertEqual(complete.phase, .upToDate)
    }

    func testUnsignedNativeServicesFailBeforeAccountOrKeychainAccess() async throws {
        let module = makeModule(services: .production(), keyByte: 0x71, time: 1_000)
        let local = try await module.capture(.init(source: .unknown, content: .text("still usable")))
        try await module.setSyncEnabled(true)
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .capabilityUnavailable)
        XCTAssertTrue(status.isEnabled)
        XCTAssertNil(status.lastCompletedAt)
        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [local.entryID])
    }

    func testAccountChangeDisablesDeviceAndRequiresFreshSelectionForNewAccount() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x39, time: 1_000)
        let entry = try await module.capture(.init(source: .unknown, content: .text("account A only")))
        let tag = try await module.createTagDefinition(named: "Account A", assigningTo: entry.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        await cloud.switchAccount(to: "second-user")
        await module.retrySync()
        let stopped = await module.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.phase, .failed(.accountChanged))
        try await module.setSyncEnabled(true)
        let afterManualActivation = await module.syncStatus()
        XCTAssertTrue(afterManualActivation.isEnabled)
        let choices = try await module.syncTags()
        XCTAssertTrue(choices.allSatisfy { !$0.isSelected })
        let cloudRecords = await cloud.currentUploads()
        XCTAssertTrue(cloudRecords.isEmpty)
        let local = try await module.page(.init())
        XCTAssertEqual(local.entries.map(\.id), [entry.entryID])
    }

    @MainActor
    func testSelectedTextArrivesAsHistoryWithOriginalProvenanceAndNoPasteboardWrite() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x31, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x42, time: 2_000)
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "example.editor", displayName: "Editor")
        let captured = try await first.capture(ClipboardHistoryCaptureRequest(
            source: source, content: .text("private example \t\r\n")
        ))
        let tag = try await first.createTagDefinition(named: "Shared work", assigningTo: captured.entryID)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("leave this alone", forType: .string)
        let generation = pasteboard.changeCount

        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let secondBeforeActivation = await second.syncStatus()
        XCTAssertFalse(secondBeforeActivation.isEnabled)
        try await second.setSyncEnabled(true)
        let page = try await second.page(ClipboardHistoryQuery(tagID: tag.definition.id))
        XCTAssertEqual(page.entries.count, 1)
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(received.source, source)
        let materialization = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(materialization.items, [ClipboardHistoryMaterializedItem(representations: [
            .text(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, value: "private example \t\r\n")
        ])])
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "leave this alone")
        let firstStatus = await first.syncStatus()
        let secondStatus = await second.syncStatus()
        XCTAssertEqual(firstStatus.uploadedEntryCount, 1)
        XCTAssertEqual(secondStatus.receivedEntryCount, 1)
        XCTAssertEqual(secondStatus.phase, .upToDate)
    }

    private func makeModule(
        services: ClipboardSyncServices, keyByte: UInt8, time: TimeInterval,
        root: URL? = nil, clock: (@Sendable () -> Date)? = nil
    ) -> ClipboardHistoryModule {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore(byte: keyByte),
            now: clock ?? { Date(timeIntervalSince1970: time) },
            syncServices: services
        ))
    }

    func testSyncTagsShowExistingEligibleTextWithoutEnablingDevice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root, keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("shared later")
        ))
        let tag = try await module.createTagDefinition(named: "Work", assigningTo: captured.entryID)
        let choices = try await module.syncTags()
        XCTAssertEqual(choices, [ClipboardHistorySyncTag(
            id: tag.definition.id, displayName: "Work", isSelected: false, eligibleEntryCount: 1
        )])
        let status = await module.syncStatus()
        XCTAssertFalse(status.isEnabled)
    }

    func testNewDeviceStartsDisabledAndKeepsLocalHistoryUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("local only")
        ))
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertFalse(status.isEnabled)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
    }
}

private struct SyncTestLocalKeyStore: ClipboardHistoryMasterKeyStoring {
    var byte: UInt8 = 0x67
    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Data(repeating: byte, count: 32))
    }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor SyncTestCloud: ClipboardSyncTransport {
    private var currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: "test-user")
    private var descriptors: [String: ClipboardSyncControl] = [:]
    private var records: [String: [ClipboardSyncUpload]] = [:]
    private var revision = 0
    private var losesEntryResponse = false
    private var reads = 0
    private var rendezvous = false
    private var initialReadWaiter: CheckedContinuation<ClipboardSyncControl?, Never>?
    private var shouldHoldCancellation = false
    private var heldCancellation: CheckedContinuation<Void, Never>?
    private var cancellationObserver: CheckedContinuation<Void, Never>?
    private var failsControlCreation = false
    private var controlAttempts: [UUID] = []
    private var accountFailureDelay: TimeInterval?
    private var damagesDownload = false

    func account() throws -> ClipboardSyncAccount {
        reads += 1
        if let delay = accountFailureDelay {
            accountFailureDelay = nil
            throw ClipboardSyncServiceError.network(retryAfter: delay)
        }
        return currentAccount
    }
    func failNextAccountRead(retryAfter: TimeInterval) { accountFailureDelay = retryAfter }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        try checkAccount(account)
        if rendezvous, descriptors[account.identifier] == nil {
            if let initialReadWaiter {
                self.initialReadWaiter = nil
                rendezvous = false
                initialReadWaiter.resume(returning: nil)
                return nil
            }
            return await withCheckedContinuation { initialReadWaiter = $0 }
        }
        return descriptors[account.identifier]
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        try checkAccount(account)
        controlAttempts.append(candidate.keyID)
        if failsControlCreation {
            failsControlCreation = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        if let descriptor = descriptors[account.identifier] { return descriptor }
        let result = advanced(candidate)
        descriptors[account.identifier] = result
        return result
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) throws -> ClipboardSyncChanges {
        try checkAccount(account)
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let uploads = records[account.identifier] ?? []
        return ClipboardSyncChanges(records: uploads.dropFirst(offset).map(\.record),
            cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        try checkAccount(account)
        guard let upload = records[account.identifier]?.first(where: { $0.record == record }) else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if damagesDownload {
            damagesDownload = false
            var changed = upload.chunks
            changed[0][0] ^= 1
            return changed
        }
        return upload.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount,
                control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        try checkAccount(account)
        guard let descriptor = descriptors[account.identifier], descriptor.epoch == control.epoch else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if let existing = records[account.identifier]?.first(where: { $0.record.recordID == upload.record.recordID }) {
            guard existing == upload else { throw ClipboardSyncServiceError.corruptData }
            return descriptor
        }
        guard descriptor.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        records[account.identifier, default: []].append(upload)
        let result = advanced(descriptor)
        descriptors[account.identifier] = result
        if losesEntryResponse, upload.record.kind == .entry {
            losesEntryResponse = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        return result
    }
    func cancel() async {
        guard shouldHoldCancellation else { return }
        shouldHoldCancellation = false
        await withCheckedContinuation {
            heldCancellation = $0
            cancellationObserver?.resume()
            cancellationObserver = nil
        }
    }
    func holdNextCancellation() { shouldHoldCancellation = true }
    func waitForHeldCancellation() async {
        guard heldCancellation == nil else { return }
        await withCheckedContinuation { cancellationObserver = $0 }
    }
    func releaseCancellation() { heldCancellation?.resume(); heldCancellation = nil }
    func switchAccount(to owner: String) {
        currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: owner)
    }
    func currentUploads() -> [ClipboardSyncUpload] { records[currentAccount.identifier] ?? [] }
    func loseNextEntryCommitResponse() { losesEntryResponse = true }
    func damageNextDownload() { damagesDownload = true }
    func failNextControlCreation() { failsControlCreation = true }
    func controlCreationAttempts() -> [UUID] { controlAttempts }
    func rendezvousInitialControlReads() { rendezvous = true }
    func removeControl() { descriptors[currentAccount.identifier] = nil }
    func accountReadCount() -> Int { reads }
    private func checkAccount(_ account: ClipboardSyncAccount) throws {
        guard currentAccount == account else { throw ClipboardSyncServiceError.accountChanged }
    }
    private func advanced(_ value: ClipboardSyncControl) -> ClipboardSyncControl {
        revision += 1
        return ClipboardSyncControl(accountID: value.accountID, keyID: value.keyID,
            keyCheck: value.keyCheck, epoch: value.epoch, phase: value.phase,
            serverToken: Data(String(revision).utf8))
    }
}

private actor SyncTestKeys: ClipboardSyncKeyStoring {
    private var values: [String: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? {
        values[account.identifier + keyID.uuidString]
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        let id = account.identifier + keyID.uuidString
        if let existing = values[id], existing != key { throw ClipboardSyncServiceError.corruptData }
        values[id] = key
        return key
    }
    func count() -> Int { values.count }
}

private actor SyncTestDelayedKeys: ClipboardSyncKeyStoring {
    let backing: SyncTestKeys
    private var available = false
    init(backing: SyncTestKeys) { self.backing = backing }
    func deliver() { available = true }
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        guard available else { return nil }
        return await backing.load(account: account, keyID: keyID)
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await backing.create(account: account, keyID: keyID, key: key)
    }
}
