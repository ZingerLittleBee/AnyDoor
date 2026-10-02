import AppKit
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPasteServiceTests: XCTestCase {
    func testWritePreservesItemAndRepresentationOrder() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryPasteServiceTests.order")
        )
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                        .data(typeIdentifier: "public.rtf", Data([0x01, 0x02])),
                    ]
                ),
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "public.html", value: "<b>second</b>"),
                        .data(typeIdentifier: "public.png", Data([0x89, 0x50])),
                    ]
                ),
            ]
        )

        try ClipboardHistoryPasteService.write(materialization, to: pasteboard)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Array(items[0].types.map(\.rawValue).prefix(2)),
            ["public.utf8-plain-text", "public.rtf"]
        )
        XCTAssertEqual(
            Array(items[1].types.map(\.rawValue).prefix(2)),
            ["public.html", "public.png"]
        )
        XCTAssertEqual(
            items[0].string(forType: .init("public.utf8-plain-text")),
            "first"
        )
        XCTAssertEqual(
            items[1].data(forType: .init("public.png")),
            Data([0x89, 0x50])
        )
    }

    func testInvalidMaterializationDoesNotClearExistingPasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryPasteServiceTests.atomic")
        )
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "", value: "invalid")
                    ]
                )
            ]
        )

        XCTAssertThrowsError(
            try ClipboardHistoryPasteService.write(
                materialization,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testCopyEntryWritesItemsAndRepresentationsInOrder() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                            .data(typeIdentifier: "public.rtf", Data([0x01, 0x02])),
                        ]
                    ),
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "public.html", value: "<b>second</b>"),
                            .data(typeIdentifier: "public.png", Data([0x89, 0x50])),
                        ]
                    ),
                ]
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(
            requests,
            [ClipboardHistoryMaterializationRequest(entryID: id, purpose: .normalPaste)]
        )
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Array(items[0].types.map(\.rawValue).prefix(2)),
            ["public.utf8-plain-text", "public.rtf"]
        )
        XCTAssertEqual(
            Array(items[1].types.map(\.rawValue).prefix(2)),
            ["public.html", "public.png"]
        )
        XCTAssertEqual(
            items[0].string(forType: .init("public.utf8-plain-text")),
            "first"
        )
        XCTAssertEqual(
            items[1].data(forType: .init("public.png")),
            Data([0x89, 0x50])
        )
    }

    /// The wall reads `actionFailure` right after the copy returns to decide
    /// on the restore flow, so the failure has to be both carried and kept.
    func testCopyEntryReportsMaterializationFailureWithoutTouchingPasteboard()
        async
    {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let id = ClipboardHistoryEntryID(UUID())
        let presentation = makePresentation { _ in
            throw ClipboardHistoryModuleError.fileCollectionRequiresRestore(
                id,
                ownedCount: 2,
                unavailableCount: 1
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        let failure = ClipboardHistoryActionFailure.fileCollectionRequiresRestore(
            entryID: id,
            ownedCount: 2,
            unavailableCount: 1
        )
        XCTAssertEqual(outcome, .materializationFailed(failure))
        XCTAssertEqual(presentation.actionFailure, failure)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testCopyEntryReportsWriteFailureWithoutTouchingPasteboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let presentation = makePresentation { _ in
            ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "", value: "invalid")
                        ]
                    )
                ]
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .pasteboardWriteFailed)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    /// Every copy materializes again instead of reusing a cached value.
    func testCopyEntryMaterializesAfreshForEveryCopy() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return textMaterialization("copied")
        }

        let first = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )
        let second = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(first, .copied)
        XCTAssertEqual(second, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(
            presentation.cachedMaterialization(for: id, purpose: .normalPaste)
        )
    }

    func testCopyEntryForwardsPlainTextPurpose() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return textMaterialization("plain")
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            purpose: .plainTextPaste,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(
            requests,
            [ClipboardHistoryMaterializationRequest(entryID: id, purpose: .plainTextPaste)]
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
    }

    /// A copy from history is a suppressed self-write, not a new capture, so
    /// the real monitor must not record it.
    func testCopyEntryIsSuppressedFromClipboardMonitor() async throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-CopyEntry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: storeRoot
                .appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x43, count: 32)
        )
        // copyEntry writes through the process-wide funnel, which AppDelegate
        // points at the live module; point it at this one instead.
        let previousFunnel = ClipboardSelfWrites.current
        ClipboardSelfWrites.configure(module.pasteboardSelfWrites)
        defer { ClipboardSelfWrites.configure(previousFunnel) }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)
        let presentation = makePresentation { _ in
            textMaterialization("copied")
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied")
        await monitor.observeForTesting()
        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        try await module.closeStoreForTesting()
    }

    func testMaterializationErrorsKeepExactUnavailableCounts() {
        let id = ClipboardHistoryEntryID(UUID())

        XCTAssertEqual(
            ClipboardHistoryActionFailure(
                ClipboardHistoryModuleError.fileReferencesUnavailable(
                    id,
                    count: 3
                )
            ),
            .fileReferencesUnavailable(entryID: id, count: 3)
        )
        XCTAssertEqual(
            ClipboardHistoryActionFailure(
                ClipboardHistoryModuleError.fileCollectionRequiresRestore(
                    id,
                    ownedCount: 2,
                    unavailableCount: 4
                )
            ),
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 2,
                unavailableCount: 4
            )
        )
    }

    func testUnavailablePayloadSaysSoInsteadOfAGenericCopyFailure() {
        // A migrated entry whose owned copy was already gone can never paste.
        // "复制失败" alone invites the user to keep retrying it.
        let notice = ClipboardHistoryActionFailureNotice(.payloadUnavailable)

        XCTAssertEqual(notice.titleKey, .clipboardToastPayloadUnavailable)
        XCTAssertTrue(notice.details.isEmpty)
        XCTAssertNotEqual(
            notice.titleKey,
            .clipboardToastCopyFailed
        )
    }

    func testActionFailureNoticePresentsOwnedAndUnavailableCountsSeparately() {
        let id = ClipboardHistoryEntryID(UUID())
        let notice = ClipboardHistoryActionFailureNotice(
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 2,
                unavailableCount: 4
            )
        )

        XCTAssertEqual(notice.titleKey, .clipboardToastCopyFailed)
        XCTAssertEqual(
            notice.details,
            [
                .legacyOwned(count: 2),
                .unavailable(count: 4),
            ]
        )
        let message = notice.message
        XCTAssertTrue(
            message.contains(L(.clipboardToastLegacyOwnedCount, 2))
        )
        XCTAssertTrue(
            message.contains(L(.clipboardToastUnavailableCount, 4))
        )
    }

    /// A private pasteboard that already holds "keep", so a failed copy can be
    /// shown to have left it alone. The caller releases it.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "ClipboardHistoryPasteServiceTests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        return pasteboard
    }

    private func makePresentation(
        materialize: @escaping @Sendable (
            ClipboardHistoryMaterializationRequest
        ) async throws -> ClipboardHistoryMaterialization
    ) -> ClipboardHistoryPresentationModel {
        ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in
                    ClipboardHistoryPage(
                        entries: [],
                        nextCursor: nil,
                        cursorDisposition: .initial
                    )
                },
                apply: { _ in .notFound },
                materialize: materialize,
                tagDefinitions: { [] }
            )
        )
    }
}

private func textMaterialization(
    _ value: String
) -> ClipboardHistoryMaterialization {
    ClipboardHistoryMaterialization(
        items: [
            ClipboardHistoryMaterializedItem(
                representations: [
                    .text(typeIdentifier: "public.utf8-plain-text", value: value)
                ]
            )
        ]
    )
}

private actor MaterializationRequestRecorder {
    private(set) var requests: [ClipboardHistoryMaterializationRequest] = []

    func record(_ request: ClipboardHistoryMaterializationRequest) {
        requests.append(request)
    }
}
