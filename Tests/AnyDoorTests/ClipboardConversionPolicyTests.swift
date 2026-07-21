import PluginInterface
import XCTest
@testable import ImageConversionPlugin

/// Behavioral tests for `ClipboardConversionPolicy` — the plugin's pure policy
/// deciding which clipboard payloads expose the convert-image action, which of
/// a file payload's URLs are images, and how a payload loads into basket items.
final class ClipboardConversionPolicyTests: XCTestCase {

    private func url(_ name: String, dir: String = "/tmp") -> URL {
        URL(fileURLWithPath: "\(dir)/\(name)")
    }

    // MARK: - Exposure

    func testBitmapPayloadsAreAlwaysConvertible() {
        XCTAssertTrue(ClipboardConversionPolicy.isConvertible(
            .bitmap(fileURL: url("shot.png"), displayName: "Shot")
        ))
        // A missing stored file only fails at load time; the menu still offers
        // the action and the commit reports the failure.
        XCTAssertTrue(ClipboardConversionPolicy.isConvertible(
            .bitmap(fileURL: nil, displayName: "Shot")
        ))
    }

    func testFilePayloadConvertibleOnlyWithAnImageFile() {
        XCTAssertTrue(ClipboardConversionPolicy.isConvertible(
            .files([url("photo.webp"), url("notes.txt")])
        ))
        XCTAssertFalse(ClipboardConversionPolicy.isConvertible(
            .files([url("notes.txt"), url("archive.zip")])
        ))
        XCTAssertFalse(ClipboardConversionPolicy.isConvertible(.files([])))
    }

    func testImageFileURLsKeepsOnlyImagesInOrder() {
        let urls = ClipboardConversionPolicy.imageFileURLs(
            from: [url("notes.txt"), url("photo.webp"), url("shot.png")]
        )
        XCTAssertEqual(urls.map(\.lastPathComponent), ["photo.webp", "shot.png"])
        XCTAssertEqual(urls.map(\.path), ["/tmp/photo.webp", "/tmp/shot.png"])
    }

    // MARK: - Loading

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardConversionPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testBitmapPayloadLoadsStoredBitmap() throws {
        let dir = try makeTempDirectory()
        let stored = dir.appendingPathComponent("stored.png")
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        try data.write(to: stored)

        let items = try XCTUnwrap(ClipboardConversionPolicy.basketItems(
            for: .bitmap(fileURL: stored, displayName: "Shot")
        ))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].payload, .bitmap(data))
        XCTAssertEqual(items[0].displayName, "Shot")
    }

    func testBitmapPayloadWithMissingStoredFileLoadsNothing() {
        XCTAssertNil(ClipboardConversionPolicy.basketItems(
            for: .bitmap(fileURL: nil, displayName: "Shot")
        ))
        XCTAssertNil(ClipboardConversionPolicy.basketItems(
            for: .bitmap(fileURL: url("gone.png", dir: "/nonexistent"), displayName: "Shot")
        ))
    }

    func testFilePayloadKeepsOnlySurvivingImageFiles() throws {
        let dir = try makeTempDirectory()
        let photo = dir.appendingPathComponent("photo.png")
        let notes = dir.appendingPathComponent("notes.txt")
        try Data([0x01]).write(to: photo)
        try Data([0x02]).write(to: notes)
        let gone = dir.appendingPathComponent("gone.webp")

        let items = try XCTUnwrap(ClipboardConversionPolicy.basketItems(
            for: .files([photo, notes, gone])
        ))
        XCTAssertEqual(items, [.file(photo)])
    }

    func testFilePayloadWithNoSurvivingImageLoadsNothing() throws {
        let dir = try makeTempDirectory()
        let notes = dir.appendingPathComponent("notes.txt")
        try Data([0x02]).write(to: notes)

        XCTAssertNil(ClipboardConversionPolicy.basketItems(
            for: .files([notes, dir.appendingPathComponent("gone.png")])
        ))
    }
}
