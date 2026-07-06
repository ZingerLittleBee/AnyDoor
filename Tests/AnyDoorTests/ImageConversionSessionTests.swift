import CoreGraphics
import ImageIO
import XCTest
@testable import AnyDoor

final class ImageConversionSessionTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-image-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNGImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 16,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        return context.makeImage()!
    }

    private func writePNG(to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, makePNGImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func pngData() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, makePNGImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testConvertAllWritesOutputsBesideSourcesSkipsUnreadableFilesAndPreservesOriginal() async throws {
        let dir = try tempDirectory()
        let image = dir.appendingPathComponent("Photo.png")
        let garbage = dir.appendingPathComponent("Notes.txt")
        try writePNG(to: image)
        try Data("not an image".utf8).write(to: garbage)
        let original = try Data(contentsOf: image)

        let summary = await ImageConversionSession().convertAll(
            fileURLs: [image, garbage],
            target: .jpeg
        )

        let output = dir.appendingPathComponent("Photo.jpg")
        XCTAssertEqual(summary.converted, 1)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.outputURLs, [output])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: image), original)
    }

    func testConvertAllSuffixesRepeatedRunsWithoutOverwritingPriorOutput() async throws {
        let dir = try tempDirectory()
        let image = dir.appendingPathComponent("Photo.png")
        try writePNG(to: image)

        _ = await ImageConversionSession().convertAll(fileURLs: [image], target: .jpeg)
        let second = await ImageConversionSession().convertAll(fileURLs: [image], target: .jpeg)

        XCTAssertEqual(second.converted, 1)
        XCTAssertEqual(second.skipped, 0)
        XCTAssertEqual(second.outputURLs.map(\.lastPathComponent), ["Photo 2.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Photo.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Photo 2.jpg").path))
    }

    func testConvertAllWritesBitmapOutputsToInjectedDownloadsWithTimestampAndCollisionSuffix() async throws {
        let downloads = try tempDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_720_000_000) // 2024-07-03 09:46:40 UTC
        let bitmap = try pngData()

        let summary = await ImageConversionSession().convertAll(
            inputs: [.bitmap(bitmap), .bitmap(bitmap)],
            target: .jpeg,
            downloadsDirectory: downloads,
            calendar: calendar,
            now: date
        )

        XCTAssertEqual(summary.converted, 2)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(
            summary.outputURLs.map(\.lastPathComponent),
            ["Clipboard 2024-07-03 09.46.40.jpg", "Clipboard 2024-07-03 09.46.40 2.jpg"]
        )
        for url in summary.outputURLs {
            XCTAssertEqual(url.deletingLastPathComponent().path, downloads.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testConvertAllSkipsNonImageBitmapData() async throws {
        let downloads = try tempDirectory()

        let summary = await ImageConversionSession().convertAll(
            inputs: [.bitmap(Data("not an image".utf8))],
            target: .png,
            downloadsDirectory: downloads
        )

        XCTAssertEqual(summary.converted, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertTrue(summary.outputURLs.isEmpty)
    }

    func testConvertAllMixesFileAndBitmapSources() async throws {
        let dir = try tempDirectory()
        let downloads = try tempDirectory()
        let image = dir.appendingPathComponent("Photo.png")
        try writePNG(to: image)
        let bitmap = try pngData()

        let summary = await ImageConversionSession().convertAll(
            inputs: [.file(image), .bitmap(bitmap)],
            target: .jpeg,
            downloadsDirectory: downloads
        )

        XCTAssertEqual(summary.converted, 2)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Photo.jpg").path))
        XCTAssertEqual(
            summary.outputURLs.filter { $0.deletingLastPathComponent().path == downloads.path }.count,
            1
        )
    }
}
