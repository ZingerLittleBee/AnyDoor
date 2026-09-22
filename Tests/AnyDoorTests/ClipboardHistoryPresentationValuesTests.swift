import ClipboardHistory
import Foundation
import XCTest
@testable import AnyDoor

final class ClipboardHistoryPresentationValuesTests: XCTestCase {
    func testVideoFileDisplaysAsVideoWithoutLosingItsFileFacet() {
        let entry = makeEntry(facets: [.file, .video])
        XCTAssertEqual(entry.presentationFacet, .video)
        XCTAssertEqual(entry.presentationTitleKey, .clipboardKindVideo)
        XCTAssertTrue(entry.facets.contains(.file))
        XCTAssertFalse(ClipboardHistoryKind.video.isTextBearing)
    }

    func testOrdinaryFilesAndImageFilesKeepTheirPresentation() {
        XCTAssertEqual(makeEntry(facets: [.file]).presentationTitleKey, .clipboardKindFile)
        XCTAssertEqual(makeEntry(facets: [.file, .image]).presentationFacet, .image)
        XCTAssertEqual(
            makeEntry(facets: [.file, .image, .screenshot]).presentationFacet,
            .screenshot
        )
    }

    func testOCREntryPresentsAsOCRWhilePlainTextStillPresentsAsText() {
        let ocr = makeEntry(facets: [.text, .ocr])
        XCTAssertEqual(ocr.presentationFacet, .ocr)
        XCTAssertEqual(ocr.presentationTitleKey, .clipboardKindOcr)
        XCTAssertTrue(ocr.facets.contains(.text))
        XCTAssertTrue(ClipboardHistoryKind.ocr.isTextBearing)

        let text = makeEntry(facets: [.text])
        XCTAssertEqual(text.presentationFacet, .text)
        XCTAssertEqual(text.presentationTitleKey, .clipboardKindText)

        // Link and Email entries keep the Text label exactly as before.
        XCTAssertEqual(
            makeEntry(facets: [.text, .link]).presentationTitleKey,
            .clipboardKindText
        )
        XCTAssertEqual(
            makeEntry(facets: [.text, .email, .link]).presentationTitleKey,
            .clipboardKindText
        )
    }

    func testVideoMaterializationRetainsOriginalFileURLForPreviewAndPaste() {
        let url = URL(fileURLWithPath: "/Users/example/Movies/Clip.mov")
        let materialization = ClipboardHistoryMaterialization(items: [
            ClipboardHistoryMaterializedItem(representations: [
                .file(ClipboardHistoryMaterializedFileReference(
                    capturedPath: url.path,
                    displayName: url.lastPathComponent,
                    currentURL: url
                ))
            ])
        ])
        XCTAssertEqual(materialization.fileURLs, [url])
        XCTAssertNil(materialization.exactTexts)
        XCTAssertNil(materialization.firstBitmapData)
    }

    private func makeEntry(facets: Set<ClipboardHistoryFacet>) -> ClipboardHistoryEntry {
        ClipboardHistoryEntry(
            id: ClipboardHistoryEntryID(UUID()),
            capturedAt: Date(timeIntervalSince1970: 0),
            previewText: "Clip.mov",
            facets: facets,
            isFavorite: false,
            source: .unknown
        )
    }
}
