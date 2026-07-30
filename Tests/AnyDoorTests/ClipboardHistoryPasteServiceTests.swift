import AppKit
import ClipboardHistory
import XCTest

@testable import AnyDoor

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

    func testMaterializationErrorsKeepExactUnavailableCounts() {
        let id = ClipboardHistoryEntryID(UUID())

        XCTAssertEqual(
            ClipboardHistoryActionFailure(
                ClipboardHistoryModuleError.fileReferencesUnavailable(
                    id,
                    count: 3
                )
            ),
            .fileReferencesUnavailable(count: 3)
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
                ownedCount: 2,
                unavailableCount: 4
            )
        )
    }
}
