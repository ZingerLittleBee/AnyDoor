import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
    }

    func testRecordTextReloadsNewestFirstForKindOnly() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)

        await store.recordText(kind: .ocr, text: "first")
        now = Date(timeIntervalSinceReferenceDate: 200)
        await store.recordText(kind: .qrcode, text: "qr")
        now = Date(timeIntervalSinceReferenceDate: 300)
        await store.recordText(kind: .ocr, text: "second\nline")

        await store.reload(kind: .ocr)
        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["second\nline", "first"])
        XCTAssertEqual(store.items(for: .ocr).first?.previewTitle, "second")
    }

    func testRecordColorStoresColorHexAndNoText() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)

        await store.recordColor(hex: "#ffcc00")
        await store.reload(kind: .color)

        let item = try XCTUnwrap(store.items(for: .color).first)
        XCTAssertEqual(item.colorHex, "#FFCC00")
        XCTAssertNil(item.text)
        XCTAssertEqual(item.previewTitle, "#FFCC00")
    }

    func testPruneDeletesExpiredAndOverflowRows() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 3)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        for index in 0..<5 {
            context.insert(ClipboardHistoryItem(kind: .ocr, text: "\(index)", previewTitle: "\(index)", createdAt: now.addingTimeInterval(TimeInterval(index))))
        }
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)
        await store.reload(kind: .ocr)

        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["4", "3", "2"])
    }

    func testNonForcedPruneIsThrottled() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, pruneThrottle: 60)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()

        await store.pruneExpiredAndOverflow(force: false)
        now = now.addingTimeInterval(10)
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired2", previewTitle: "expired2", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()
        await store.pruneExpiredAndOverflow(force: false)

        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertTrue(rows.contains { $0.text == "expired2" })
    }

    func testRecordScreenshotStoresPngFileAndMetadata() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(
            now: { Date(timeIntervalSinceReferenceDate: 100) },
            historyDirectory: directory
        )
        store.bootstrap(modelContainer: container)

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        await store.recordScreenshotFromPasteboard()
        await store.reload(kind: .screenshot)

        let item = try XCTUnwrap(store.items(for: .screenshot).first)
        let fileName = try XCTUnwrap(item.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
        // Screenshots persist an empty previewTitle; the displayed label is
        // resolved via L(item.historyKind.titleKey) at render time so a
        // language switch updates the row without rewriting the store.
        XCTAssertEqual(item.previewTitle, "")
        XCTAssertEqual(item.historyKind, .screenshot)

        try? FileManager.default.removeItem(at: directory)
    }

    func testCopyTextAndColorBackToPasteboard() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        let textItem = ClipboardHistoryItem(kind: .ocr, text: "hello", previewTitle: "hello")
        try await store.copyToPasteboard(textItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

        let colorItem = ClipboardHistoryItem(kind: .color, colorHex: "#FFCC00", previewTitle: "#FFCC00")
        try await store.copyToPasteboard(colorItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#FFCC00")

        try? FileManager.default.removeItem(at: directory)
    }

    func testClearAllResetsCacheEvenWhenNoRows() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        // Populate the cache via the public API, then wipe rows out-of-band so
        // clearAll() runs against an empty store with a stale cache present.
        await store.recordText(kind: .ocr, text: "stale")
        XCTAssertFalse(store.items(for: .ocr).isEmpty)

        let context = container.mainContext
        for item in try context.fetch(FetchDescriptor<ClipboardHistoryItem>()) {
            context.delete(item)
        }
        try context.save()

        await store.clearAll()

        for kind in ClipboardHistoryKind.allCases {
            XCTAssertTrue(store.items(for: kind).isEmpty)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testClearAllDeletesRowsAndScreenshotFiles() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .screenshot, fileName: "shot.png", previewTitle: "截图"))
        try context.save()

        await store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClipboardHistoryItem>()).isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordCapturedTextStoresPlainAndRich() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)

        await store.record(
            .text(plain: "hello\nworld", rich: Data([0x09]), richType: "public.rtf"),
            source: ClipboardSource(bundleID: "com.apple.Safari", appName: "Safari")
        )
        await store.reload(kind: .text)

        let item = try XCTUnwrap(store.items(for: .text).first)
        XCTAssertEqual(item.text, "hello\nworld")
        XCTAssertEqual(item.previewTitle, "hello")
        XCTAssertEqual(item.richType, "public.rtf")
        XCTAssertEqual(item.sourceAppName, "Safari")
    }

    func testRecordCapturedImageStoresPng() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) }, historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        await store.record(.image(png: Data([0x89, 0x50, 0x4E, 0x47])), source: nil)
        await store.reload(kind: .image)

        let item = try XCTUnwrap(store.items(for: .image).first)
        let fileName = try XCTUnwrap(item.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordCapturedFileCopiesIntoStorage() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) }, historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        let src = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        await store.record(.files(urls: [src]), source: nil)
        await store.reload(kind: .file)

        let item = try XCTUnwrap(store.items(for: .file).first)
        let entry = try XCTUnwrap(item.files.first)
        XCTAssertEqual(entry.originalName, src.lastPathComponent)
        XCTAssertFalse(item.isReferenceOnly)
        let stored = try XCTUnwrap(entry.storedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(stored).path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordCapturedFileOverSizeLimitIsReferenceOnly() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(
            now: { Date(timeIntervalSinceReferenceDate: 100) },
            historyDirectory: directory,
            maxCopiedFileBytes: 4
        )
        store.bootstrap(modelContainer: container)

        let src = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).txt")
        try Data(repeating: 0x41, count: 64).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        await store.record(.files(urls: [src]), source: nil)
        await store.reload(kind: .file)

        let item = try XCTUnwrap(store.items(for: .file).first)
        XCTAssertTrue(item.isReferenceOnly)
        XCTAssertNil(item.files.first?.storedName)
        XCTAssertEqual(item.files.first?.originalPath, src.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testNewKindsAndFieldsPersist() throws {
        let item = ClipboardHistoryItem(
            kind: .text,
            text: "hello",
            previewTitle: "hello",
            richData: Data([0x01, 0x02]),
            richType: "public.rtf",
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            isFavorite: true
        )
        XCTAssertEqual(item.historyKind, .text)
        XCTAssertEqual(item.richType, "public.rtf")
        XCTAssertEqual(item.sourceAppName, "Safari")
        XCTAssertTrue(item.isFavorite)
        XCTAssertEqual(ClipboardHistoryKind.file.titleKey, .clipboardKindFile)
    }

    func testTimelineFiltersByCategoryAndSearch() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)

        await store.record(.text(plain: "apple pie", rich: nil, richType: nil), source: nil)
        now = Date(timeIntervalSinceReferenceDate: 200)
        await store.record(.text(plain: "banana bread", rich: nil, richType: nil), source: nil)
        now = Date(timeIntervalSinceReferenceDate: 300)
        await store.recordColor(hex: "#ABCDEF")

        // All → newest first across kinds.
        let all = store.timeline(category: nil, query: "")
        XCTAssertEqual(all.map(\.previewTitle), ["#ABCDEF", "banana bread", "apple pie"])

        // Category filter.
        let onlyText = store.timeline(category: .text, query: "")
        XCTAssertEqual(onlyText.map(\.previewTitle), ["banana bread", "apple pie"])

        // Case-insensitive search over preview/text.
        let search = store.timeline(category: nil, query: "APPLE")
        XCTAssertEqual(search.map(\.previewTitle), ["apple pie"])
    }

    func testToggleFavoriteAndDelete() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        await store.record(.text(plain: "keep me", rich: nil, richType: nil), source: nil)

        let item = try XCTUnwrap(store.timeline(category: nil, query: "").first)
        await store.toggleFavorite(item)
        XCTAssertTrue(try XCTUnwrap(store.timeline(category: nil, query: "").first).isFavorite)

        await store.delete(item)
        XCTAssertTrue(store.timeline(category: nil, query: "").isEmpty)
    }

    func testDeleteRemovesOnDiskPayloadAfterSave() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) }, historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        await store.record(.image(png: Data([0x89, 0x50, 0x4E, 0x47])), source: nil)
        let item = try XCTUnwrap(store.timeline(category: nil, query: "").first)
        let fileName = try XCTUnwrap(item.fileName)
        let fileURL = directory.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await store.delete(item)

        // The row is gone and its on-disk payload is removed after the save.
        XCTAssertTrue(store.timeline(category: nil, query: "").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testPruneRemovesOverflowPayloadFiles() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 1, historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        await store.record(.image(png: Data([0x89, 0x50, 0x4E, 0x47])), source: nil)
        let oldest = try XCTUnwrap(store.items(for: .image).first)
        let oldestFile = directory.appendingPathComponent(try XCTUnwrap(oldest.fileName))

        now = Date(timeIntervalSinceReferenceDate: 200)
        await store.record(.image(png: Data([0x89, 0x50, 0x4E, 0x47])), source: nil)

        await store.pruneExpiredAndOverflow(force: true)

        // The overflowed row's PNG is removed after the prune save.
        XCTAssertEqual(store.items(for: .image).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testPruneExemptsFavorites() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 1)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        // Two text rows; the OLDER one is favorited and must survive the overflow trim.
        context.insert(ClipboardHistoryItem(kind: .text, text: "old", previewTitle: "old", createdAt: now.addingTimeInterval(1), isFavorite: true))
        context.insert(ClipboardHistoryItem(kind: .text, text: "new", previewTitle: "new", createdAt: now.addingTimeInterval(2)))
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)
        let titles = Set(store.timeline(category: .text, query: "").map(\.previewTitle))
        XCTAssertTrue(titles.contains("old"))   // favorite survived
        XCTAssertTrue(titles.contains("new"))
    }

    func testUnlimitedRetentionKeepsOldRows() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxAge: .infinity)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .text, text: "ancient", previewTitle: "ancient", createdAt: now.addingTimeInterval(-3650 * 86_400)))
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)
        XCTAssertEqual(store.timeline(category: .text, query: "").map(\.previewTitle), ["ancient"])
    }

    func testPastePayloadPlainVsRich() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorPaste-\(UUID().uuidString)"))

        let rich = NSAttributedString(string: "styled")
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length)))
        let item = ClipboardHistoryItem(kind: .text, text: "styled", previewTitle: "styled",
                                        richData: rtf, richType: NSPasteboard.PasteboardType.rtf.rawValue)

        ClipboardPasteService.writePayload(for: item, asPlainText: false, to: pb, historyDirectory: nil)
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        XCTAssertEqual(pb.string(forType: .string), "styled")

        ClipboardPasteService.writePayload(for: item, asPlainText: true, to: pb, historyDirectory: nil)
        XCTAssertNil(pb.data(forType: .rtf))   // plain mode drops rich payload
        XCTAssertEqual(pb.string(forType: .string), "styled")
    }

    func testUpdateTextRewritesPreviewAndClearsRichPayload() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let created = Date(timeIntervalSinceReferenceDate: 50)
        let item = ClipboardHistoryItem(
            kind: .text,
            text: "old text",
            previewTitle: "old text",
            createdAt: created,
            richData: Data([0x01]),
            richType: "public.rtf"
        )
        container.mainContext.insert(item)
        try container.mainContext.save()

        await store.updateText(item, newText: "new first line\nsecond line")

        XCTAssertEqual(item.text, "new first line\nsecond line")
        XCTAssertEqual(item.previewTitle, "new first line")
        XCTAssertNotNil(item.previewSubtitle)
        // The stale rich payload would win on paste and resurrect the pre-edit
        // content, so editing must clear it.
        XCTAssertNil(item.richData)
        XCTAssertNil(item.richType)
        // The card keeps its position in the wall.
        XCTAssertEqual(item.createdAt, created)
        // The per-kind cache reflects the edit.
        XCTAssertEqual(store.items(for: .text).map(\.text), ["new first line\nsecond line"])
    }

    func testUpdateTextIgnoresWhitespaceOnlyText() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let item = ClipboardHistoryItem(kind: .text, text: "keep me", previewTitle: "keep me")
        container.mainContext.insert(item)
        try container.mainContext.save()

        await store.updateText(item, newText: "   \n\t")

        XCTAssertEqual(item.text, "keep me")
        XCTAssertEqual(item.previewTitle, "keep me")
    }

    func testTextBearingKinds() {
        XCTAssertTrue(ClipboardHistoryKind.text.isTextBearing)
        XCTAssertTrue(ClipboardHistoryKind.ocr.isTextBearing)
        XCTAssertTrue(ClipboardHistoryKind.qrcode.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.color.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.image.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.screenshot.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.file.isTextBearing)
    }

    func testToggleTagAddsAndRemoves() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let item = ClipboardHistoryItem(kind: .text, text: "a", previewTitle: "a")
        container.mainContext.insert(item)
        try container.mainContext.save()

        await store.toggleTag(item, tagID: "t1")
        XCTAssertEqual(item.tagIDs, ["t1"])
        await store.toggleTag(item, tagID: "t1")
        XCTAssertEqual(item.tagIDs, [])
    }

    func testPruneExemptsTaggedItems() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 2)
        store.bootstrap(modelContainer: container)
        let context = container.mainContext

        let oldTagged = ClipboardHistoryItem(kind: .ocr, text: "oldTagged", previewTitle: "oldTagged",
                                             createdAt: now.addingTimeInterval(-8 * 86_400))
        oldTagged.tagIDs = ["t1"]
        context.insert(oldTagged)
        // Overflow pressure: 4 fresh rows with a 2-per-kind cap.
        for index in 0..<4 {
            let row = ClipboardHistoryItem(kind: .ocr, text: "\(index)", previewTitle: "\(index)",
                                           createdAt: now.addingTimeInterval(TimeInterval(index)))
            if index == 0 { row.tagIDs = ["t1"] }   // oldest fresh row, tagged
            context.insert(row)
        }
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)

        let survivors = try context.fetch(FetchDescriptor<ClipboardHistoryItem>()).map(\.text)
        XCTAssertEqual(survivors.count, 4)               // oldTagged + 0 + the 2-per-kind cap (3, 2)
        XCTAssertTrue(survivors.contains("oldTagged"))   // age-exempt
        XCTAssertTrue(survivors.contains("0"))           // overflow-exempt
        XCTAssertFalse(survivors.contains("1"))          // untagged overflow goes
    }

    func testRemoveTagFromAllItemsRestoresPrunability() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let expired = ClipboardHistoryItem(kind: .text, text: "expired", previewTitle: "expired",
                                           createdAt: now.addingTimeInterval(-8 * 86_400))
        expired.tagIDs = ["t1"]
        context.insert(expired)
        try context.save()

        await store.removeTagFromAllItems("t1")
        XCTAssertEqual(expired.tagIDs, [])
        await store.pruneExpiredAndOverflow(force: true)
        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertTrue(rows.isEmpty)
    }

    func testCleanUpUnknownTagsDropsStaleIDsOnly() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let item = ClipboardHistoryItem(kind: .text, text: "a", previewTitle: "a")
        item.tagIDs = ["alive", "ghost"]
        context.insert(item)
        try context.save()

        await store.cleanUpUnknownTags(validIDs: ["alive"])
        XCTAssertEqual(item.tagIDs, ["alive"])
    }

    func testTimelineKeepsOldTaggedItems() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let oldTagged = ClipboardHistoryItem(kind: .text, text: "oldTagged", previewTitle: "oldTagged",
                                             createdAt: now.addingTimeInterval(-8 * 86_400))
        oldTagged.tagIDs = ["t1"]
        context.insert(oldTagged)
        let oldPlain = ClipboardHistoryItem(kind: .text, text: "oldPlain", previewTitle: "oldPlain",
                                            createdAt: now.addingTimeInterval(-8 * 86_400))
        context.insert(oldPlain)
        try context.save()

        let titles = store.timeline(category: nil, query: "").map(\.previewTitle)
        XCTAssertTrue(titles.contains("oldTagged"))
        XCTAssertFalse(titles.contains("oldPlain"))
    }
}
