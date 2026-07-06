import XCTest
@testable import AnyDoor

final class ImageConversionNamingTests: XCTestCase {
    func testOutputURLUsesSourceBasenameAndTargetExtension() {
        let source = URL(fileURLWithPath: "/tmp/Photo.webp")

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { _ in false }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo.jpg")
        XCTAssertEqual(output.deletingLastPathComponent().path, "/tmp")
    }

    func testOutputURLSuffixesOnCollision() {
        let source = URL(fileURLWithPath: "/tmp/Photo.webp")
        let taken: Set<String> = ["Photo.jpg", "Photo 2.jpg"]

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { taken.contains($0.lastPathComponent) }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo 3.jpg")
    }

    func testOutputURLNeverOverwritesSourceWhenTargetExtensionMatches() {
        let source = URL(fileURLWithPath: "/tmp/Photo.jpg")

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { $0 == source }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo 2.jpg")
    }

    func testBitmapBaseNameUsesClipboardPrefixAndTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_720_000_000) // 2024-07-03 09:46:40 UTC

        let base = ImageConversionNaming.bitmapBaseName(timestamp: date, calendar: calendar)

        XCTAssertEqual(base, "Clipboard 2024-07-03 09.46.40")
    }

    func testBitmapOutputURLUsesDownloadsDirectoryAndTargetExtension() {
        let downloads = URL(fileURLWithPath: "/tmp/Downloads")

        let output = ImageConversionNaming.outputURL(
            forBitmapInDownloads: downloads,
            baseName: "Clipboard 2024-07-03 09.46.40",
            target: .png,
            exists: { _ in false }
        )

        XCTAssertEqual(output.lastPathComponent, "Clipboard 2024-07-03 09.46.40.png")
        XCTAssertEqual(output.deletingLastPathComponent().path, "/tmp/Downloads")
    }

    func testBitmapOutputURLSuffixesOnCollision() {
        let downloads = URL(fileURLWithPath: "/tmp/Downloads")
        let taken: Set<String> = ["Clip.png", "Clip 2.png"]

        let output = ImageConversionNaming.outputURL(
            forBitmapInDownloads: downloads,
            baseName: "Clip",
            target: .png,
            exists: { taken.contains($0.lastPathComponent) }
        )

        XCTAssertEqual(output.lastPathComponent, "Clip 3.png")
    }
}
