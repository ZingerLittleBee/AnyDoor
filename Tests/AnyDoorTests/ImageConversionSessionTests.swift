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

    private func writePNG(to url: URL) throws {
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
        let image = context.makeImage()!

        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
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
}
