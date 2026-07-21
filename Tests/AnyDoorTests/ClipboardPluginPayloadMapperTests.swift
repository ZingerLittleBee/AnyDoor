import PluginInterface
import XCTest
@testable import AnyDoor

/// Behavioral tests for `ClipboardPluginPayloadMapper` — the Core's pure
/// mapping from a clipboard-history entry's fields to the neutral payload
/// handed to Native Plugins. Which payloads expose an action is each plugin's
/// policy; the mapper only describes the entry.
final class ClipboardPluginPayloadMapperTests: XCTestCase {

    private let historyDirectory = URL(fileURLWithPath: "/tmp/history")

    private func fileEntry(_ name: String, dir: String = "/tmp") -> ClipboardFileEntry {
        ClipboardFileEntry(storedName: nil, originalName: name, originalPath: "\(dir)/\(name)")
    }

    private func payload(
        kind: ClipboardHistoryKind?,
        fileName: String? = nil,
        files: [ClipboardFileEntry] = []
    ) -> PluginClipboardPayload? {
        ClipboardPluginPayloadMapper.payload(
            kind: kind,
            fileName: fileName,
            previewTitle: "Shot",
            files: files,
            historyDirectory: historyDirectory
        )
    }

    func testBitmapKindsMapToStoredBitmapPayload() {
        for kind in [ClipboardHistoryKind.screenshot, .image] {
            XCTAssertEqual(
                payload(kind: kind, fileName: "abc.png"),
                .bitmap(
                    fileURL: historyDirectory.appendingPathComponent("abc.png"),
                    displayName: "Shot"
                ),
                "\(kind) should map to its stored bitmap"
            )
        }
    }

    func testBitmapKindWithoutStoredFileNameKeepsNilURL() {
        XCTAssertEqual(
            payload(kind: .screenshot),
            .bitmap(fileURL: nil, displayName: "Shot")
        )
    }

    func testFileKindMapsOriginalPathsInOrder() {
        XCTAssertEqual(
            payload(kind: .file, files: [fileEntry("notes.txt"), fileEntry("photo.webp")]),
            .files([
                URL(fileURLWithPath: "/tmp/notes.txt"),
                URL(fileURLWithPath: "/tmp/photo.webp"),
            ]),
            "all files travel, in stored order — image filtering is plugin policy"
        )
    }

    func testOtherKindsHaveNoPayload() {
        for kind in [ClipboardHistoryKind.text, .ocr, .color, .qrcode] {
            XCTAssertNil(payload(kind: kind), "\(kind) should contribute no plugin payload")
        }
        XCTAssertNil(payload(kind: nil))
    }
}
