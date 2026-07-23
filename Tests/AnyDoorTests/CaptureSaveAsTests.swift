import AppKit
import CoreGraphics
import ImageCodec
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AnyDoor

/// Covers the pure, testable seams of the screenshot "Save As" path: the
/// extension -> format resolution policy, the `UTType` accessor that widens the
/// save panel, and the transcode-on-write helper (encode fully in memory,
/// atomic write, nothing left behind on failure). Save As is a Core feature:
/// it depends only on the shared `ImageCodec` target, never on the Image
/// Conversion plugin module, so it behaves identically whether or not that
/// plugin is installed. The `NSSavePanel` itself is GUI-manual.
final class CaptureSaveAsTests: XCTestCase {
    // MARK: - Extension -> format resolution

    func testSaveExtensionResolvesJpegAliases() {
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("jpg"), .jpeg)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("jpeg"), .jpeg)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("JPG"), .jpeg)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("JPEG"), .jpeg)
    }

    func testSaveExtensionIsCaseInsensitiveForWhitelistFormats() {
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("PNG"), .png)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("Heic"), .heic)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("pdf"), .pdf)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("tiff"), .tiff)
    }

    func testUnknownExtensionFallsBackToPNG() {
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("webp"), .png)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension(""), .png)
        XCTAssertEqual(ImageConversionFormat.forSaveExtension("txt"), .png)
    }

    // MARK: - UTType accessor (widens the save panel's allowed content types)

    func testUTTypeMatchesWhitelistIdentifiers() {
        XCTAssertEqual(ImageConversionFormat.png.utType, .png)
        XCTAssertEqual(ImageConversionFormat.jpeg.utType, .jpeg)
        XCTAssertEqual(ImageConversionFormat.pdf.utType, .pdf)
    }

    // MARK: - Transcode-on-write

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-saveas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNGData(width: Int = 16, height: Int = 16) throws -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testTranscodeWritesRequestedFormat() throws {
        let png = try makePNGData()
        let output = try makeTempDirectory().appendingPathComponent("shot.jpg")

        try CaptureCoordinator.transcode(png: png, to: output, format: .jpeg, quality: 0.85)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, ImageConversionFormat.jpeg.typeIdentifier)
    }

    func testTranscodeFailureLeavesNoFile() throws {
        let garbage = Data("not a real image".utf8)
        let output = try makeTempDirectory().appendingPathComponent("shot.jpg")

        XCTAssertThrowsError(
            try CaptureCoordinator.transcode(png: garbage, to: output, format: .jpeg, quality: 0.85)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTranscodeFailureDoesNotClobberExistingDestination() throws {
        let garbage = Data("not a real image".utf8)
        let output = try makeTempDirectory().appendingPathComponent("existing.jpg")
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: output)

        XCTAssertThrowsError(
            try CaptureCoordinator.transcode(png: garbage, to: output, format: .jpeg, quality: 0.85)
        )
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }
}
