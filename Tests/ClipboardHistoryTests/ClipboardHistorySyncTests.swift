import AppKit
import Foundation
import GRDB
import XCTest
import ClipboardHistoryTestSupport
import os

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    @MainActor
    func testCorruptOwnedAssetAndDuplicateFileMembersRejectTheEntireEnvelope() async throws {
        let validPNG = try makeSyncBitmap()
        let file = ClipboardSyncFileDescriptor(objectID: UUID(), versionID: UUID(), displayName: "pending.txt",
            originalByteCount: nil, contentDigest: nil, body: nil, state: .sourceUnavailable)
        let cases: [[ClipboardSyncRepresentationContent]] = [
            [.bitmap(png: Data(validPNG.prefix(24)), thumbnail: validPNG)],
            [.bitmap(png: validPNG, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]))],
            [.file(file), .file(file)],
        ]
        for (index, representations) in cases.enumerated() {
            let cloud = SyncTestCloud()
            let keys = SyncTestKeys()
            let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil),
                keyByte: UInt8(0xA0 + index), time: 1_000)
            try await module.setSyncEnabled(true)
            try await Self.publishFixture(.entry(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: 500),
                sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
                tags: [.init(id: "shared", name: "Shared")],
                items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "do not import alone")]),
                        .init(representations: representations)], facets: ["text", "image"], recognition: .init())), cloud: cloud, keys: keys)
            await module.retrySync()
            let page = try await module.page(.init())
            let status = await module.syncStatus()
            XCTAssertEqual(page.entries, [], "Malformed member \(index) must reject the complete entry")
            XCTAssertEqual(status.phase, .failed(.corruptData))
        }
    }

    @MainActor
    func testOwnedAssetPublicationFailureDoesNotPublishAPartialMixedEntry() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let failure = OSAllocatedUnfairLock(initialState: true)
        let first = makeModule(services: services, keyByte: 0x98, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x99, time: 2_000,
            faultInjector: .init { point in point == .payloadPublication && failure.withLock { $0 } })
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-partial-image.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let image = NSPasteboardItem()
        image.setData(try makeSyncBitmap(), forType: .png)
        let text = NSPasteboardItem()
        text.setString("second complete item", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([image, text]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected a complete mixed capture")
        }
        let tag = try await first.createTagDefinition(named: "Mixed", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("keep current clipboard", forType: .string)
        let generation = pasteboard.changeCount
        try await second.setSyncEnabled(true)
        let failedPage = try await second.page(.init())
        XCTAssertEqual(failedPage.entries, [])
        let failedStatus = await second.syncStatus()
        XCTAssertEqual(failedStatus.phase, .failed(.localStorage))
        failure.withLock { $0 = false }
        await second.retrySync()
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let received = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, original)
        do {
            _ = try await second.materialize(.init(entryID: captured.entryID, purpose: .plainTextPaste))
            XCTFail("An image-only item must not disappear from a plain-text paste")
        } catch { XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable) }
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep current clipboard")
        await second.retrySync()
        let repeated = try await second.page(.init())
        XCTAssertEqual(repeated.entries.count, 1)
    }

    @MainActor
    func testLateRecognitionCannotRestoreResultsAfterTextEditRemovesBitmap() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let recognizer = SyncTestRecognizer(results: [.ocr: ["obsolete image words"], .qr: ["anydoor://obsolete/image"]], held: true)
        let first = makeModule(services: services, keyByte: 0x9A, time: 1_000, recognizer: recognizer)
        let second = makeModule(services: services, keyByte: 0x9B, time: 2_000)
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-edited-image.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("editable original", forType: .string)
        item.setData(try makeSyncBitmap(), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected an editable bitmap entry")
        }
        let tag = try await first.createTagDefinition(named: "Edited", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await second.apply(.editText(captured.entryID, "current exact text"))
        await second.retrySync()
        await recognizer.release()
        await first.awaitDerivedJobsForTesting()
        await first.retrySync()
        await second.retrySync()
        let obsolete = try await second.page(.init(text: "obsolete"))
        let qr = try await second.page(.init(facet: .qrCode))
        XCTAssertEqual(obsolete.entries, [])
        XCTAssertEqual(qr.entries, [])
        let materialized = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(materialized.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "current exact text")])])
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x9C, time: 3_000)
        try await third.setSyncEnabled(true)
        let replayed = try await third.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(replayed, materialized)
        let stale = try await third.page(.init(text: "obsolete"))
        XCTAssertEqual(stale.entries, [])
    }

    func testAuthenticatedEntryWithDuplicateStandardTypesFailsAsAWhole() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x97, time: 1_000)
        try await module.setSyncEnabled(true)
        try await Self.publishFixture(.entry(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: 500),
            sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
            tags: [.init(id: "shared", name: "Shared")],
            items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                                           .text(typeIdentifier: "public.utf8-plain-text", value: "second")])],
            facets: ["text"], recognition: .init())), cloud: cloud, keys: keys)
        await module.retrySync()
        let page = try await module.page(.init())
        let status = await module.syncStatus()
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(status.phase, .failed(.corruptData))
    }

    func testLegacyTextSnapshotAppliesEarlierFavoriteMetadata() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let module = makeModule(services: services, keyByte: 0x96, time: 1_000)
        try await module.setSyncEnabled(true)
        let id = UUID()
        let operationID = UUID()
        try await Self.publishFixture(.metadata(.init(id: id,
            revision: .init(counter: 1, operationID: operationID.uuidString.lowercased()), value: .favorite(true))),
            operationID: operationID, cloud: cloud, keys: keys)
        try await Self.publishFixture(.text(.init(id: id, text: "legacy text", capturedAt: Date(timeIntervalSince1970: 500),
            sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
            tags: [.init(id: "legacy-shared", name: "Legacy")])), cloud: cloud, keys: keys)
        await module.retrySync()
        let page = try await module.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(page.entries.count, 1)
        let content = try await module.materialize(.init(entryID: entry.id, purpose: .plainTextPaste))
        XCTAssertEqual(content.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "legacy text")])])
    }

    @MainActor
    func testLaterRecognitionResultsSurviveRestartAndReverseDeliveryWithoutReprocessing() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let recognizer = SyncTestRecognizer(results: [.ocr: ["late invoice 9913"], .qr: ["anydoor://late/qr"]], held: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-late-recognition-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x93, time: 1_000, root: root, recognizer: recognizer)
        let second = makeModule(services: services, keyByte: 0x94, time: 2_000)
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let captured = try await first.capture(.init(source: .unknown, content: .bitmap(try makeSyncBitmap(), provenance: .image)))
        let tag = try await first.createTagDefinition(named: "Images", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncEnabled(false)
        await recognizer.release()
        await first.awaitDerivedJobsForTesting()
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x93, time: 3_000, root: root)
        try await reopened.setSyncEnabled(true)
        await second.retrySync()
        let ocr = try await second.page(.init(text: "invoice 9913"))
        let qr = try await second.page(.init(text: "late/qr", facet: .qrCode))
        XCTAssertEqual(ocr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.map(\.id), [captured.entryID])
        XCTAssertTrue(qr.entries.first?.isFavorite == true)
        let status = await reopened.syncStatus()
        XCTAssertEqual(status.uploadedEntryCount, 1)
        await cloud.reverseDelivery()
        let receiverRecognizer = SyncTestRecognizer()
        let third = makeModule(services: services, keyByte: 0x95, time: 4_000, recognizer: receiverRecognizer)
        try await third.setSyncEnabled(true)
        let reverseOCR = try await third.page(.init(text: "invoice 9913"))
        let reverseQR = try await third.page(.init(text: "late/qr", facet: .qrCode))
        XCTAssertEqual(reverseOCR.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(reverseQR.entries.map(\.id), [captured.entryID])
        XCTAssertTrue(reverseQR.entries.first?.isFavorite == true)
        let calls = await receiverRecognizer.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCompletedImageRecognitionTransfersAsSearchableResultsWithoutEnablingReceiverRecognition() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x91, time: 1_000,
            recognizer: SyncTestRecognizer(results: [.ocr: ["recognized invoice 4721"], .qr: ["anydoor://recognized/qr"]]))
        let receiverRecognizer = SyncTestRecognizer()
        let second = makeModule(services: services, keyByte: 0x92, time: 2_000, recognizer: receiverRecognizer)
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let captured = try await first.capture(.init(source: .unknown, content: .bitmap(try makeSyncBitmap(), provenance: .image)))
        await first.awaitDerivedJobsForTesting()
        let tag = try await first.createTagDefinition(named: "Images", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let ocr = try await second.page(.init(text: "invoice 4721"))
        let qr = try await second.page(.init(text: "recognized/qr", facet: .qrCode))
        XCTAssertEqual(ocr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.first?.facets, [.image, .qrCode])
        let recognitionEnabled = try await second.isAutomaticImageTextIndexingEnabled()
        XCTAssertFalse(recognitionEnabled)
        let calls = await receiverRecognizer.callCount()
        XCTAssertEqual(calls, 0)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let received = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, original)
    }

    @MainActor
    func testFavoriteUpdatesSurviveRestartAndReorderingWithoutReplacingRichContentOrPrivateTags() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-favorite-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x87, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x88, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-favorite.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let html = Data("<b>keep rich content</b>".utf8)
        item.setString("keep rich content", forType: .string)
        item.setData(html, forType: .html)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let capture) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected rich history")
        }
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let privateTag = try await second.createTagDefinition(named: "Receiver private", assigningTo: capture.entryID)
        let recentLocal = try await second.capture(.init(source: .unknown, content: .text("recent receiver-only history")))
        try await first.setSyncEnabled(false)
        _ = try await first.apply(.setFavorite(capture.entryID, true))
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x87, time: 3_000, root: root)
        try await reopened.setSyncEnabled(true)
        await second.retrySync()
        let page = try await second.page(.init())
        let received = try XCTUnwrap(page.entries.first { $0.id == capture.entryID })
        XCTAssertEqual(page.entries.first?.id, recentLocal.entryID)
        XCTAssertTrue(received.isFavorite)
        XCTAssertEqual(received.tagIDs, [tag.definition.id, privateTag.definition.id])
        let content = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(content.items, [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "keep rich content"), .data(typeIdentifier: "public.html", html),
        ])])
        let uploaded = await reopened.syncStatus()
        XCTAssertEqual(uploaded.uploadedEntryCount, 1)
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x89, time: 4_000)
        try await third.setSyncEnabled(true)
        let reversed = try await third.page(.init())
        XCTAssertEqual(reversed.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(reversed.entries.first).isFavorite)
        XCTAssertEqual(reversed.entries.first?.capturedAt, Date(timeIntervalSince1970: 1_000))
        _ = try await reopened.apply(.setFavorite(capture.entryID, false))
        await reopened.retrySync()
        await second.retrySync()
        await third.retrySync()
        let secondAfterToggle = try await second.page(.init())
        let thirdAfterToggle = try await third.page(.init())
        XCTAssertFalse(try XCTUnwrap(secondAfterToggle.entries.first { $0.id == capture.entryID }).isFavorite)
        XCTAssertFalse(try XCTUnwrap(thirdAfterToggle.entries.first).isFavorite)
        XCTAssertEqual(secondAfterToggle.entries.first?.id, recentLocal.entryID)
    }

    @MainActor
    func testSharedRichTextEditKeepsMetadataAndLateInitialContentCannotRestoreOldFormats() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x5A, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x5B, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-rich-edit.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let attributed = NSAttributedString(string: "formatted original")
        let rtf = try attributed.data(from: .init(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let item = NSPasteboardItem()
        item.setString("formatted original", forType: .string)
        item.setData(rtf, forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "test.editor", displayName: "Editor")
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: source) else {
            return XCTFail("Expected rich text capture")
        }
        let tag = try await first.createTagDefinition(named: "Rich edits", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let initial = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertTrue(initial.items[0].representations.contains(.data(typeIdentifier: "public.rtf", rtf)))
        let privateTag = try await second.createTagDefinition(named: "Private context", assigningTo: captured.entryID)
        _ = try await second.apply(.setFavorite(captured.entryID, true))

        _ = try await first.apply(.editText(captured.entryID, "edited exact text"))
        await first.retrySync()
        await second.retrySync()
        let expected = ClipboardHistoryMaterialization(items: [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "edited exact text")
        ])])
        let edited = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(edited, expected)
        let page = try await second.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.tagIDs, [tag.definition.id, privateTag.definition.id])
        XCTAssertEqual(entry.source, source)
        XCTAssertEqual(entry.capturedAt, Date(timeIntervalSince1970: 1_000))

        await cloud.replayAllChangesInReverseOrder()
        let late = makeModule(services: services, keyByte: 0x5C, time: 3_000)
        try await late.setSyncEnabled(true)
        await late.retrySync()
        let replayed = try await late.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(replayed, expected)
        let plan = try await late.textEditPlan(for: captured.entryID)
        XCTAssertFalse(plan.hasConflict)
    }

    func testEditorRetainsItsDisplayedAncestryWhenRemoteTextChangesBeforeSave() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x57, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x58, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("editor basis")))
        let tag = try await first.createTagDefinition(named: "Editor", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let secondPage = try await second.page(.init())
        let remote = try XCTUnwrap(secondPage.entries.first)
        let opened = try await first.textEditPlan(for: captured.entryID)
        _ = try await second.apply(.editText(remote.id, "remote edit"))
        await second.retrySync()
        await first.retrySync()

        let saved = try await first.saveTextEdit("draft from old basis", using: opened)
        guard case .updated(let entry) = saved else { return XCTFail("Expected saved draft") }
        XCTAssertTrue(entry.hasTextConflict)
        let conflict = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(Set(conflict.versions.map(\.text)), ["remote edit", "draft from old basis"])
        let choice = try XCTUnwrap(conflict.versions.first { $0.text == "draft from old basis" })
        _ = try await first.apply(.editText(captured.entryID, "continued draft"))
        do {
            _ = try await first.resolveTextConflict(.init(plan: conflict, versionID: choice.id))
            XCTFail("A stale choice must not discard a newer branch")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable)
        }
        let refreshed = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(Set(refreshed.versions.map(\.text)), ["remote edit", "continued draft"])
        let currentChoice = try XCTUnwrap(refreshed.versions.first { $0.text == "continued draft" })
        let resolved = try await first.resolveTextConflict(.init(plan: refreshed, versionID: currentChoice.id))
        guard case .updated(let updated) = resolved else { return XCTFail("Expected resolved entry") }
        XCTAssertFalse(updated.hasTextConflict)
    }

    func testUpgradeFromV14PreservesAnEditWhoseInitialCiphertextWasReclaimed() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-v14-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x55, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x56, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("v14 original")))
        let tag = try await first.createTagDefinition(named: "Upgrade", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        await first.retrySync()
        try await second.setSyncEnabled(true)
        await first.suspendSync()
        _ = try await first.apply(.editText(captured.entryID, "v14 unsent edit"))
        try await first.makeV14SyncFixtureForTesting()
        try await first.closeStoreForTesting()

        let upgraded = makeModule(services: services, keyByte: 0x55, time: 3_000, root: root)
        await upgraded.resumeSync()
        await second.retrySync()
        let local = try await upgraded.textEditPlan(for: captured.entryID)
        let page = try await second.page(.init())
        let remote = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(local.text, "v14 unsent edit")
        XCTAssertEqual(remote.previewText, "v14 unsent edit")
        XCTAssertEqual(local.versions.count, 1)
    }

    func testOfflineTextBranchesSurviveRestartAndExplicitResolutionConverges() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let firstRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-branches-A-\(UUID())")
        let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-branches-B-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x53, time: 1_000, root: firstRoot)
        let second = makeModule(services: services, keyByte: 0x54, time: 2_000, root: secondRoot)
        let captured = try await first.capture(.init(source: .unknown, content: .text("shared root")))
        let tag = try await first.createTagDefinition(named: "Branches", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let initial = try await second.page(.init())
        let received = try XCTUnwrap(initial.entries.first)
        await first.suspendSync()
        await second.suspendSync()
        _ = try await first.apply(.editText(captured.entryID, "offline A"))
        _ = try await second.apply(.editText(received.id, "offline B"))
        try await first.closeStoreForTesting()
        try await second.closeStoreForTesting()

        let reopenedA = makeModule(services: services, keyByte: 0x53, time: 3_000, root: firstRoot)
        let reopenedB = makeModule(services: services, keyByte: 0x54, time: 4_000, root: secondRoot)
        await reopenedA.resumeSync()
        await reopenedB.resumeSync()
        await reopenedA.retrySync()
        let conflictA = try await reopenedA.textEditPlan(for: captured.entryID)
        let conflictB = try await reopenedB.textEditPlan(for: received.id)
        XCTAssertEqual(Set(conflictA.versions.map(\.text)), ["offline A", "offline B"])
        XCTAssertEqual(Set(conflictB.versions.map(\.text)), ["offline A", "offline B"])
        XCTAssertEqual(conflictA.text, "offline A")
        XCTAssertEqual(conflictB.text, "offline B")
        let choice = try XCTUnwrap(conflictA.versions.first { $0.text == "offline B" })
        _ = try await reopenedA.resolveTextConflict(.init(plan: conflictA, versionID: choice.id))
        await reopenedA.retrySync()
        await reopenedB.retrySync()
        let resolvedA = try await reopenedA.textEditPlan(for: captured.entryID)
        let resolvedB = try await reopenedB.textEditPlan(for: received.id)
        XCTAssertEqual(resolvedA.text, "offline B")
        XCTAssertEqual(resolvedB.text, "offline B")
        XCTAssertFalse(resolvedA.hasConflict)
        XCTAssertFalse(resolvedB.hasConflict)
        try await reopenedB.closeStoreForTesting()
        let finalB = makeModule(services: services, keyByte: 0x54, time: 5_000, root: secondRoot)
        await finalB.resumeSync()
        let afterRestart = try await finalB.textEditPlan(for: received.id)
        XCTAssertEqual(afterRestart.text, "offline B")
        XCTAssertFalse(afterRestart.hasConflict)

        // A newly joining device receives the resolution before either branch
        // and the root. Durable pending versions must still converge; replaying
        // every record again must not restore the resolved conflict.
        await cloud.replayAllChangesInReverseOrder()
        let reordered = makeModule(services: services, keyByte: 0x59, time: 6_000)
        try await reordered.setSyncEnabled(true)
        await reordered.retrySync()
        let reorderedPage = try await reordered.page(.init())
        XCTAssertEqual(reorderedPage.entries.count, 1)
        let reorderedEntry = try XCTUnwrap(reorderedPage.entries.first)
        let reorderedPlan = try await reordered.textEditPlan(for: reorderedEntry.id)
        XCTAssertEqual(reorderedPlan.text, "offline B")
        XCTAssertFalse(reorderedPlan.hasConflict)
    }

    func testSharedTextEditUpdatesExistingEntryWithoutMovingLocalOrder() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x51, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x52, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-edit-tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("current clipboard", forType: .string)
        let pasteboardGeneration = pasteboard.changeCount
        let captured = try await first.capture(.init(source: .unknown, content: .text("original")))
        let tag = try await first.createTagDefinition(named: "Edits", assigningTo: captured.entryID)
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let before = try await second.page(.init())
        let received = try XCTUnwrap(before.entries.first)
        let privateTag = try await second.createTagDefinition(named: "Private", assigningTo: received.id)
        _ = try await second.apply(.setFavorite(received.id, false))
        let later = try await second.capture(.init(source: .unknown, content: .text("local newer")))

        _ = try await first.apply(.editText(captured.entryID, "revised"))
        await first.retrySync()
        await second.retrySync()

        let after = try await second.page(.init())
        XCTAssertEqual(after.entries.map(\.id), [later.entryID, received.id])
        let updated = try XCTUnwrap(after.entries.last)
        XCTAssertEqual(updated.previewText, "revised")
        XCTAssertEqual(updated.capturedAt, received.capturedAt)
        XCTAssertEqual(updated.source, received.source)
        XCTAssertFalse(updated.isFavorite)
        XCTAssertEqual(updated.tagIDs, [tag.definition.id, privateTag.definition.id])
        let content = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(content.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "revised")])])
        XCTAssertEqual(pasteboard.changeCount, pasteboardGeneration)
        XCTAssertEqual(pasteboard.string(forType: .string), "current clipboard")
    }

    @MainActor
    func testStandardColorAndExplicitRecognitionTextKeepTheirRepresentationsAndFacets() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x85, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x86, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-color.\(UUID())"))
        pasteboard.clearContents()
        let color = NSColor(displayP3Red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)
        let bytes = try XCTUnwrap(color.pasteboardPropertyList(forType: .color) as? Data)
        let item = NSPasteboardItem()
        item.setData(bytes, forType: .color)
        item.setString("original color label", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let colored) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected a captured color")
        }
        let ocr = try await first.capture(.init(source: .unknown, content: .ocr("https://example.com/recognized")))
        let qr = try await first.capture(.init(source: .unknown, content: .qrCode("qr result")))
        let tag = try await first.createTagDefinition(named: "Content", assigningTo: colored.entryID)
        _ = try await first.apply(.setTags(ocr.entryID, [tag.definition.id]))
        _ = try await first.apply(.setTags(qr.entryID, [tag.definition.id]))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 3)
        let restoredColor = try XCTUnwrap(page.entries.first { $0.id == colored.entryID })
        XCTAssertEqual(restoredColor.facets, [.text, .color])
        let normal = try await second.materialize(.init(entryID: restoredColor.id, purpose: .normalPaste))
        XCTAssertEqual(normal.items, [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "original color label"),
            .data(typeIdentifier: NSPasteboard.PasteboardType.color.rawValue, bytes),
        ])])
        XCTAssertEqual(page.entries.first { $0.id == ocr.entryID }?.facets, [.text, .ocr])
        XCTAssertEqual(page.entries.first { $0.id == qr.entryID }?.facets, [.text, .qrCode])
        let ocrSearch = try await second.page(.init(text: "recognized", facet: .ocr))
        XCTAssertEqual(ocrSearch.entries.map(\.id), [ocr.entryID])
    }

    @MainActor
    func testScreenshotTransfersOwnedPixelsAndThumbnailWithoutStartingReceiverRecognition() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x83, time: 1_000)
        let receiverRecognizer = SyncTestRecognizer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-owned-image-\(UUID())")
        let second = makeModule(services: services, keyByte: 0x84, time: 2_000, root: root, recognizer: receiverRecognizer)
        let bitmap = try makeSyncBitmap()
        let captured = try await first.capture(.init(source: .init(bundleIdentifier: "test.capture", displayName: "Capture"),
            content: .bitmap(bitmap, provenance: .anyDoorScreenshot)))
        await first.awaitDerivedJobsForTesting()
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        let tag = try await first.createTagDefinition(named: "Screenshots", assigningTo: captured.entryID)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let preview = try await first.materialize(.init(entryID: captured.entryID, purpose: .preview))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.awaitDerivedJobsForTesting()
        let page = try await second.page(.init(facet: .screenshot))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(received.facets, [.image, .screenshot])
        XCTAssertTrue(received.isFavorite)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        let full = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        let thumbnail = try await second.materialize(.init(entryID: received.id, purpose: .preview))
        XCTAssertEqual(full, original)
        XCTAssertEqual(thumbnail, preview)
        let recognitionCalls = await receiverRecognizer.callCount()
        XCTAssertEqual(recognitionCalls, 0)
        let payloads = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("payloads"), includingPropertiesForKeys: nil)
        XCTAssertEqual(payloads.count, 2)
        for file in payloads {
            XCTAssertNil(try Data(contentsOf: file).range(of: bitmap))
        }
    }

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
        let senderStatus = await first.syncStatus()
        XCTAssertEqual(senderStatus.phase, .upToDate)
        pasteboard.clearContents()
        pasteboard.setString("leave the current clipboard alone", forType: .string)
        let generation = pasteboard.changeCount

        try await second.setSyncEnabled(true)

        let receiverStatus = await second.syncStatus()
        XCTAssertEqual(receiverStatus.phase, .upToDate)

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

    func testIndependentTagRenamesConvergeAcrossReversedDeliveryAndRestart() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-tags-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x75, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x76, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("renamed collections")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncEnabled(false)
        try await second.setSyncEnabled(false)
        _ = try await first.renameTagDefinition(id: work.id, to: "Focused work")
        _ = try await second.renameTagDefinition(id: other.id, to: "Research")
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await first.retrySync()
        let expected = [work.id: "Focused work", other.id: "Research"]
        let firstTags = try await first.syncTags()
        let secondTags = try await second.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: firstTags.map { ($0.id, $0.displayName) }), expected)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: secondTags.map { ($0.id, $0.displayName) }), expected)
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x77, time: 3_000)
        try await third.setSyncEnabled(true)
        let reversedTags = try await third.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reversedTags.map { ($0.id, $0.displayName) }), expected)
        let reversedEntries = try await third.page(.init()).entries
        XCTAssertEqual(reversedEntries.first?.tagIDs, [work.id, other.id])
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x75, time: 4_000, root: root)
        await reopened.resumeSync()
        let reopenedTags = try await reopened.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reopenedTags.map { ($0.id, $0.displayName) }), expected)
    }

    func testSelectedMembershipChangesPreservePrivateTagsOnBothDevices() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x73, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x74, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("shared organization")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let personal = try await second.createTagDefinition(named: "Private on receiver", assigningTo: entry.entryID).definition
        _ = try await first.apply(.setTags(entry.entryID, [other.id]))
        await first.retrySync()
        await second.retrySync()
        let removed = try await second.page(.init()).entries
        XCTAssertEqual(removed.first?.tagIDs, [other.id, personal.id])
        _ = try await second.apply(.setTags(entry.entryID, [work.id, other.id, personal.id]))
        await second.retrySync()
        await first.retrySync()
        let restored = try await first.page(.init()).entries
        XCTAssertEqual(restored.first?.tagIDs, [work.id, other.id])
        let firstDefinitions = try await first.tagDefinitions()
        XCTAssertFalse(firstDefinitions.contains { $0.id == personal.id })
        let countBeforeReplay = await cloud.currentUploads().count
        await first.retrySync()
        await second.retrySync()
        let countAfterReplay = await cloud.currentUploads().count
        XCTAssertEqual(countAfterReplay, countBeforeReplay)
    }

    func testMultipleSelectedTagsBackfillTheirUnionWithoutPrivateLabels() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x71, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x72, time: 2_000)
        let workEntry = try await first.capture(.init(source: .unknown, content: .text("work history")))
        let otherEntry = try await first.capture(.init(source: .unknown, content: .text("other history")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: workEntry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: otherEntry.entryID).definition
        let personal = try await first.createTagDefinition(named: "Personal", assigningTo: workEntry.entryID).definition
        _ = try await first.apply(.setTags(workEntry.entryID, [work.id, other.id, personal.id]))
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let choices = try await second.syncTags()
        XCTAssertEqual(Set(choices.filter(\.isSelected).map(\.id)), [work.id, other.id])
        XCTAssertFalse(choices.contains { $0.id == personal.id })
        let entries = try await second.page(.init()).entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.id == workEntry.entryID }?.tagIDs, [work.id, other.id])
        await first.retrySync()
        await second.retrySync()
        let replayed = try await second.page(.init()).entries
        XCTAssertEqual(replayed.count, 2)
    }

    func testLostSuccessfulBootstrapReopensTheSameWinnerAfterPeerProgress() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-bootstrap-receipt-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x61, time: 1_000, root: root)
        let entry = try await first.capture(.init(source: .unknown, content: .text("original pending text")))
        let tag = try await first.createTagDefinition(named: "Original tag", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        await cloud.loseNextControlResponse()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        let account = try await cloud.account()
        let winner = try await cloud.control(for: account)
        try await first.closeStoreForTesting()

        let peer = makeModule(services: services, keyByte: 0x62, time: 2_000)
        let peerEntry = try await peer.capture(.init(source: .unknown, content: .text("peer progression")))
        let peerTag = try await peer.createTagDefinition(named: "Peer tag", assigningTo: peerEntry.entryID)
        try await peer.setSyncTagSelected(peerTag.definition.id, selected: true)
        try await peer.setSyncEnabled(true)
        let reopened = makeModule(services: services, keyByte: 0x61, time: 3_000, root: root)
        await reopened.resumeSync()
        await reopened.retrySync()
        await peer.retrySync()
        let after = try await cloud.control(for: account)
        XCTAssertEqual(after?.keyID, winner?.keyID)
        let attempts = await cloud.controlCreationAttempts()
        XCTAssertEqual(attempts.count, 1)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        let firstPage = try await reopened.page(.init())
        let peerPage = try await peer.page(.init())
        XCTAssertEqual(firstPage.entries.count, 2)
        XCTAssertEqual(peerPage.entries.count, 2)
    }

    func testAccountChangeDuringKeyDeliveryRejectsTheOldResponse() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x72, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        await source.cloud.switchAccount(to: "new-account")
        await held.releaseLoad()
        try await activation.value
        let status = await receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.phase, .failed(.accountChanged))
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let newAccountUploads = await source.cloud.currentUploads()
        XCTAssertTrue(newAccountUploads.isEmpty)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testDisableDuringKeyDeliveryKeepsTheSharedKeyAndPeerWorking() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x73, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        let cancellation = await source.cloud.cancellationCount()
        let disabling = Task { try await receiver.setSyncEnabled(false) }
        await source.cloud.waitForCancellation(after: cancellation)
        await held.releaseLoad()
        try await activation.value
        try await disabling.value
        let disabled = await receiver.syncStatus()
        XCTAssertFalse(disabled.isEnabled)
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let fresh = try await source.sender.capture(.init(source: .unknown, content: .text("peer remains enabled")))
        _ = try await source.sender.apply(.setTags(fresh.entryID, [source.tag]))
        await source.sender.retrySync()
        let uploads = await source.cloud.currentUploads()
        XCTAssertEqual(uploads.filter { $0.record.kind == .entry }.count, 2)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testLocalResetDuringKeyDeliveryCannotImportIntoTheReplacementStore() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x74, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        let beforeReset = await source.cloud.currentUploads()
        let cancellation = await source.cloud.cancellationCount()
        let resetting = Task { try await receiver.reset(confirmation: .confirmed) }
        await source.cloud.waitForCancellation(after: cancellation)
        await held.releaseLoad()
        try await activation.value
        try await resetting.value
        let status = await receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let afterReset = await source.cloud.currentUploads()
        XCTAssertEqual(afterReset, beforeReset)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testAccountChangeWhileQuitPersistsTheNeedForNewActivation() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-account-recovery-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x75, time: 1_000, root: root)
        let local = try await first.capture(.init(source: .unknown, content: .text("retained account A text")))
        let tag = try await first.createTagDefinition(named: "Account A tag", assigningTo: local.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await first.closeStoreForTesting()
        await cloud.switchAccount(to: "account-after-relaunch")
        let reopened = makeModule(services: services, keyByte: 0x75, time: 2_000, root: root)
        await reopened.resumeSync()
        try await reopened.closeStoreForTesting()
        let again = makeModule(services: services, keyByte: 0x75, time: 3_000, root: root)
        let stopped = await again.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.phase, .failed(.accountChanged))
        await again.resumeSync()
        let unpublished = await cloud.currentUploads()
        XCTAssertTrue(unpublished.isEmpty)
        try await again.setSyncEnabled(true)
        let afterActivation = await cloud.currentUploads()
        XCTAssertTrue(afterActivation.isEmpty)
        let retained = try await again.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
    }

    func testTemporaryAccountLossResumesPendingTextWithoutChangingItsKey() async throws {
        let source = try await recoverySource()
        let fresh = try await source.sender.capture(.init(source: .unknown, content: .text("pending through account outage")))
        _ = try await source.sender.apply(.setTags(fresh.entryID, [source.tag]))
        await source.cloud.failNextAccountRead(with: .accountUnavailable)
        await source.sender.retrySync()
        let waiting = await source.sender.syncStatus()
        XCTAssertEqual(waiting.phase, .waitingForAccount)
        let local = try await source.sender.materialize(.init(entryID: fresh.entryID, purpose: .plainTextPaste))
        XCTAssertFalse(local.items.isEmpty)
        await source.sender.retrySync()
        await source.sender.retrySync()
        let uploads = await source.cloud.currentUploads()
        XCTAssertEqual(uploads.filter { $0.record.kind == .entry }.count, 2)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    private func recoverySource() async throws -> (cloud: SyncTestCloud, keys: SyncTestKeys, sender: ClipboardHistoryModule, tag: String) {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let sender = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x71, time: 1_000)
        let entry = try await sender.capture(.init(source: .unknown, content: .text("account-bound source")))
        let tag = try await sender.createTagDefinition(named: "Source tag", assigningTo: entry.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        return (cloud, keys, sender, tag.definition.id)
    }

    func testLockedKeySurvivesRestartAndUnlockResumesWithoutReplacingCiphertext() async throws {
        try await assertKeyRecovery(fault: .keyLocked, expected: .keyLocked)
    }

    func testDeniedKeyAccessRemainsDistinctAndRecoveryPreservesHistory() async throws {
        try await assertKeyRecovery(fault: .accessDenied, expected: .accessDenied)
    }

    func testUnavailableKeyWaitsWithoutDiagnosingSystemSyncSettings() async throws {
        try await assertKeyRecovery(fault: .keyUnavailable, expected: .waitingForKey)
    }

    func testWrongSelectedKeyPreservesCiphertextUntilTheCorrectKeyReturns() async throws {
        try await assertKeyRecovery(fault: nil, expected: .failed(.corruptData), wrongKey: true)
    }

    private func assertKeyRecovery(fault: ClipboardSyncServiceError?, expected: ClipboardHistorySyncPhase,
                                   wrongKey: Bool = false) async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let sender = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x31, time: 1_000)
        let captured = try await sender.capture(.init(source: .unknown, content: .text("encrypted source")))
        let tag = try await sender.createTagDefinition(named: "Private tag", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        let originalCiphertext = await cloud.currentUploads()
        let unavailable = SyncTestFaultKeys(backing: keys, fault: fault, wrongKey: wrongKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-key-recovery-\(UUID())")
        let services = ClipboardSyncServices(transport: cloud, keys: unavailable, pollingInterval: nil)
        let receiver = makeModule(services: services, keyByte: 0x32, time: 2_000, root: root)
        let local = try await receiver.capture(.init(source: .unknown, content: .text("still local")))
        try await receiver.setSyncEnabled(true)
        let failure = await receiver.syncStatus()
        XCTAssertEqual(failure.phase, expected)
        try await receiver.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x32, time: 3_000, root: root)
        let persisted = await reopened.syncStatus()
        XCTAssertEqual(persisted.phase, expected)
        await reopened.resumeSync()
        let beforeRecovery = try await reopened.page(.init())
        XCTAssertEqual(beforeRecovery.entries.map(\.id), [local.entryID])
        let preservedCiphertext = await cloud.currentUploads()
        XCTAssertEqual(preservedCiphertext, originalCiphertext)
        await unavailable.recover()
        await reopened.retrySync()
        await reopened.retrySync()
        let afterRecovery = try await reopened.page(.init())
        XCTAssertEqual(afterRecovery.entries.count, 2)
        let recovered = await reopened.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
        XCTAssertEqual(recovered.receivedEntryCount, 1)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        let finalCiphertext = await cloud.currentUploads()
        XCTAssertEqual(finalCiphertext, originalCiphertext)
    }

    func testProviderBackoffAndFailureSurviveRestartWithoutEarlyCloudAccess() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-recovery-\(UUID())")
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x41, time: 1_000, root: root,
            clock: { clock.withLock { $0 } })
        try await first.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await first.retrySync()
        try await first.closeStoreForTesting()

        let reopened = makeModule(services: services, keyByte: 0x41, time: 1_000, root: root,
            clock: { clock.withLock { $0 } })
        let restored = await reopened.syncStatus()
        XCTAssertEqual(restored.phase, .failed(.network))
        let readsBefore = await cloud.accountReadCount()
        await reopened.resumeSync()
        let readsDuringBackoff = await cloud.accountReadCount()
        XCTAssertEqual(readsDuringBackoff, readsBefore)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await reopened.retrySync()
        let recovered = await reopened.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
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

    private static func publishFixture(_ content: ClipboardSyncContent, operationID: UUID = UUID(),
                                cloud: SyncTestCloud, keys: SyncTestKeys) async throws {
        let account = try await cloud.account()
        let descriptor = try await cloud.control(for: account)
        let control = try XCTUnwrap(descriptor)
        let loaded = await keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let upload = try ClipboardSyncCodec.seal(content, account: account, control: control, key: key, operationID: operationID)
        _ = try await cloud.commit(upload, for: account, control: control)
    }

    private func makeModule(
        services: ClipboardSyncServices, keyByte: UInt8, time: TimeInterval,
        root: URL? = nil, clock: (@Sendable () -> Date)? = nil,
        recognizer: any ClipboardHistoryVisionRecognizing = SyncTestRecognizer(),
        faultInjector: ClipboardHistoryFaultInjector = .init()
    ) -> ClipboardHistoryModule {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore(byte: keyByte),
            faultInjector: faultInjector,
            now: clock ?? { Date(timeIntervalSince1970: time) },
            visionRecognizer: recognizer,
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

    @MainActor
    private func makeSyncBitmap() throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 1, green: 0.4, blue: 0.1, alpha: 1)
        for y in 0..<16 { for x in 0..<32 { image.setColor(color, atX: x, y: y) } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}

private actor SyncTestRecognizer: ClipboardHistoryVisionRecognizing {
    private var calls = 0
    let results: [ClipboardHistoryDerivedJobKind: [String]]
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(results: [ClipboardHistoryDerivedJobKind: [String]] = [:], held: Bool = false) {
        self.results = results
        self.held = held
    }
    func recognize(_ kind: ClipboardHistoryDerivedJobKind, in bitmaps: [Data]) async -> [String] {
        calls += 1
        if held { await withCheckedContinuation { waiters.append($0) } }
        return results[kind] ?? []
    }
    func release() {
        held = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
    func callCount() -> Int { calls }
}

private extension ClipboardHistoryModule {
    /// Constructs the on-disk v14 fixture after real capture/edit operations.
    /// Assertions use the public module interface after the normal upgrade.
    func makeV14SyncFixtureForTesting() async throws {
        let pool = try await writableDatabase()
        try await pool.write { database in
            try database.execute(sql: "DROP TABLE clipboard_sync_version_selections")
            try database.execute(sql: "DROP TABLE clipboard_sync_versions")
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v18_clipboard_sync_versions'")
        }
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
    private var losesControlResponse = false
    private var controlAttempts: [UUID] = []
    private var accountFailureDelay: TimeInterval?
    private var damagesDownload = false
    private var reversesAllChanges = false
    private var reversesDelivery = false
    func reverseDelivery() { reversesDelivery = true }
    private var accountFault: ClipboardSyncServiceError?
    private var cancellations = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func account() throws -> ClipboardSyncAccount {
        reads += 1
        if let fault = accountFault {
            accountFault = nil
            throw fault
        }
        if let delay = accountFailureDelay {
            accountFailureDelay = nil
            throw ClipboardSyncServiceError.network(retryAfter: delay)
        }
        return currentAccount
    }
    func failNextAccountRead(retryAfter: TimeInterval) { accountFailureDelay = retryAfter }
    func failNextAccountRead(with fault: ClipboardSyncServiceError) { accountFault = fault }
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
        if losesControlResponse {
            losesControlResponse = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        return result
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) throws -> ClipboardSyncChanges {
        try checkAccount(account)
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let uploads = records[account.identifier] ?? []
        let page = reversesAllChanges ? uploads.reversed().map(\.record) : uploads.dropFirst(offset).map(\.record)
        return ClipboardSyncChanges(records: reversesDelivery ? Array(page.reversed()) : page,
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
        cancellations += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard shouldHoldCancellation else { return }
        shouldHoldCancellation = false
        await withCheckedContinuation {
            heldCancellation = $0
            cancellationObserver?.resume()
            cancellationObserver = nil
        }
    }
    func holdNextCancellation() { shouldHoldCancellation = true }
    func cancellationCount() -> Int { cancellations }
    func waitForCancellation(after previous: Int) async {
        guard cancellations == previous else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
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
    func replayAllChangesInReverseOrder() { reversesAllChanges = true }
    func failNextControlCreation() { failsControlCreation = true }
    func loseNextControlResponse() { losesControlResponse = true }
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

private actor SyncTestFaultKeys: ClipboardSyncKeyStoring {
    let backing: SyncTestKeys
    var fault: ClipboardSyncServiceError?
    var wrongKey: Bool
    private var shouldHoldLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var loadObserver: CheckedContinuation<Void, Never>?

    init(backing: SyncTestKeys, fault: ClipboardSyncServiceError?, wrongKey: Bool = false) {
        self.backing = backing
        self.fault = fault
        self.wrongKey = wrongKey
    }

    func recover() { fault = nil; wrongKey = false }
    func holdNextLoad() { shouldHoldLoad = true }
    func waitForHeldLoad() async {
        guard heldLoad == nil else { return }
        await withCheckedContinuation { loadObserver = $0 }
    }
    func releaseLoad() { heldLoad?.resume(); heldLoad = nil }

    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        if let fault { throw fault }
        if wrongKey { return Data(repeating: 0xFA, count: 32) }
        let value = await backing.load(account: account, keyID: keyID)
        if shouldHoldLoad {
            shouldHoldLoad = false
            await withCheckedContinuation {
                heldLoad = $0
                loadObserver?.resume()
                loadObserver = nil
            }
        }
        return value
    }

    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await backing.create(account: account, keyID: keyID, key: key)
    }
}
