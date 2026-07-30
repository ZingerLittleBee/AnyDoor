import ClipboardHistory
import PluginInterface
import XCTest

@testable import AnyDoor

final class ClipboardPluginPayloadMapperTests: XCTestCase {
    func testBitmapDataMapsToNeutralInMemoryPayload() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .data(typeIdentifier: "public.png", data)
                    ]
                )
            ]
        )

        XCTAssertEqual(
            ClipboardPluginPayloadMapper.payload(
                from: materialization,
                displayName: "Shot"
            ),
            .bitmap(data: data, displayName: "Shot")
        )
    }

    func testFilesMapCurrentURLsInItemAndRepresentationOrder() {
        let first = file("/tmp/notes.txt")
        let second = file("/tmp/photo.webp")
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [.file(first)]
                ),
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: "ignored"
                        ),
                        .file(second),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            ClipboardPluginPayloadMapper.payload(
                from: materialization,
                displayName: "Files"
            ),
            .files([first.currentURL, second.currentURL])
        )
    }

    func testTextOnlyMaterializationHasNoPluginPayload() {
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: "hello"
                        )
                    ]
                )
            ]
        )

        XCTAssertNil(
            ClipboardPluginPayloadMapper.payload(
                from: materialization,
                displayName: "Text"
            )
        )
    }

    private func file(
        _ path: String
    ) -> ClipboardHistoryMaterializedFileReference {
        ClipboardHistoryMaterializedFileReference(
            capturedPath: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            currentURL: URL(fileURLWithPath: path)
        )
    }
}
