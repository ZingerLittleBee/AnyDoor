import ClipboardHistory
import XCTest
@testable import AnyDoor

final class ClipboardHistoryKindTests: XCTestCase {
    /// The wall chips and the menu-bar history popover both resolve a display
    /// kind to its Content Facet through this one mapping, so every kind is
    /// pinned here to keep the two surfaces from drifting apart again.
    func testEveryKindResolvesToItsContentFacet() {
        let expected: [ClipboardHistoryKind: ClipboardHistoryFacet] = [
            .ocr: .ocr,
            .color: .color,
            .qrcode: .qrCode,
            .screenshot: .screenshot,
            .text: .text,
            .image: .image,
            .video: .video,
            .file: .file,
        ]
        XCTAssertEqual(expected.count, ClipboardHistoryKind.allCases.count)
        for kind in ClipboardHistoryKind.allCases {
            XCTAssertEqual(kind.contentFacet, expected[kind], "\(kind)")
        }
    }

    func testOCRKindNoLongerCollapsesIntoTheTextFacet() {
        XCTAssertEqual(ClipboardHistoryKind.ocr.contentFacet, .ocr)
        XCTAssertEqual(ClipboardHistoryKind.text.contentFacet, .text)
        XCTAssertNotEqual(
            ClipboardHistoryKind.ocr.contentFacet,
            ClipboardHistoryKind.text.contentFacet
        )
    }
}
