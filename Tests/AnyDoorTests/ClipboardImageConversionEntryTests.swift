import XCTest
@testable import AnyDoor

/// Behavioral tests for `ClipboardImageConversionEntry` — the pure policy
/// deciding which clipboard-history entries expose the image-conversion action
/// and which of a file entry's files are images.
final class ClipboardImageConversionEntryTests: XCTestCase {

    private func fileEntry(_ name: String, dir: String = "/tmp") -> ClipboardFileEntry {
        ClipboardFileEntry(storedName: nil, originalName: name, originalPath: "\(dir)/\(name)")
    }

    // MARK: - Bitmap-backed kinds

    func testScreenshotAndImageKindsAreConvertible() {
        XCTAssertTrue(ClipboardImageConversionEntry.isConvertible(kind: .screenshot, files: []))
        XCTAssertTrue(ClipboardImageConversionEntry.isConvertible(kind: .image, files: []))
    }

    // MARK: - Non-convertible kinds

    func testTextColorQrcodeOcrAreNeverConvertible() {
        for kind in [ClipboardHistoryKind.text, .color, .qrcode, .ocr] {
            XCTAssertFalse(ClipboardImageConversionEntry.isConvertible(kind: kind, files: []),
                           "\(kind) should not be convertible")
        }
        XCTAssertFalse(ClipboardImageConversionEntry.isConvertible(kind: nil, files: []))
    }

    // MARK: - File kind

    func testFileKindConvertibleWhenAnyImageFilePresent() {
        let files = [fileEntry("photo.webp"), fileEntry("notes.txt")]
        XCTAssertTrue(ClipboardImageConversionEntry.isConvertible(kind: .file, files: files))
    }

    func testFileKindNotConvertibleWithoutImageFiles() {
        let files = [fileEntry("notes.txt"), fileEntry("archive.zip")]
        XCTAssertFalse(ClipboardImageConversionEntry.isConvertible(kind: .file, files: files))
    }

    func testImageFileURLsKeepsOnlyImagesInOrder() {
        let files = [fileEntry("notes.txt"), fileEntry("photo.webp"), fileEntry("shot.png")]
        let urls = ClipboardImageConversionEntry.imageFileURLs(from: files)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["photo.webp", "shot.png"])
        XCTAssertEqual(urls.map(\.path), ["/tmp/photo.webp", "/tmp/shot.png"])
    }
}
