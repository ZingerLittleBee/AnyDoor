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
        XCTAssertEqual(summary.outputs.map(\.inputIndex), [0])
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
        XCTAssertEqual(summary.outputs.map(\.inputIndex), [0, 1])
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

    func testOutputsRetainTheirInputIndicesWhenEarlierItemsAreSkipped() async throws {
        let downloads = try tempDirectory()
        let bitmap = try pngData()

        let summary = await ImageConversionSession().convertAll(
            inputs: [.bitmap(Data("not an image".utf8)), .bitmap(bitmap)],
            target: .jpeg,
            downloadsDirectory: downloads
        )

        XCTAssertEqual(summary.converted, 1)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.outputs.map(\.inputIndex), [1])
    }

    func testCancellationStopsBeforeCompletingTheRemainingBatch() async throws {
        let downloads = try tempDirectory()
        let bitmap = try pngData()
        let inputs = [ImageConversionInput](repeating: .bitmap(bitmap), count: 100)

        let task = Task {
            await ImageConversionSession().convertAll(
                inputs: inputs,
                target: .jpeg,
                downloadsDirectory: downloads
            )
        }
        task.cancel()
        let summary = await task.value

        XCTAssertLessThan(summary.converted, inputs.count)
        XCTAssertEqual(summary.converted, summary.outputs.count)
    }

    /// A noisy image (rather than a flat fill) so JPEG's lossy quantization
    /// produces a measurable size difference between low and high quality.
    private func makeNoisyImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<bytes.count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func writeNoisyPNG(to url: URL, width: Int = 128, height: Int = 128) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, makeNoisyImage(width: width, height: height), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    func testLowerJPEGQualityProducesSmallerOutputThroughSessionSeam() async throws {
        let lowDir = try tempDirectory()
        let highDir = try tempDirectory()
        let lowSource = lowDir.appendingPathComponent("Photo.png")
        let highSource = highDir.appendingPathComponent("Photo.png")
        try writeNoisyPNG(to: lowSource)
        try writeNoisyPNG(to: highSource)

        let low = await ImageConversionSession().convertAll(
            inputs: [.file(lowSource)],
            target: .jpeg,
            quality: 0.10,
            downloadsDirectory: lowDir
        )
        let high = await ImageConversionSession().convertAll(
            inputs: [.file(highSource)],
            target: .jpeg,
            quality: 0.95,
            downloadsDirectory: highDir
        )

        let lowOutput = try XCTUnwrap(low.outputURLs.first)
        let highOutput = try XCTUnwrap(high.outputURLs.first)
        XCTAssertLessThan(try fileSize(lowOutput), try fileSize(highOutput))
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
