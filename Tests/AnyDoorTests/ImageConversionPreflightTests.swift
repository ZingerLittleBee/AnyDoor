import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class ImageConversionPreflightTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Fixtures

    private func makeImage(width: Int = 64, height: Int = 48, alpha: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func encode(_ images: [CGImage], as format: ImageConversionFormat) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, format.typeIdentifier as CFString, images.count, nil
        )!
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func writeTemp(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Preflight

    func test_pngWithAlpha_toJPEG_requiresTransparencyBackground() throws {
        let url = try writeTemp(encode([makeImage(alpha: 0.5)], as: .png), name: "alpha.png")
        let result = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .file(url), target: .jpeg)

        let preflight = try XCTUnwrap(try? result.get())
        XCTAssertEqual(preflight.dimensions, PixelDimensions(width: 64, height: 48))
        XCTAssertEqual(preflight.frameCount, 1)
        XCTAssertFalse(preflight.firstFrameOnly)
        XCTAssertTrue(preflight.hasAlpha)
        XCTAssertTrue(preflight.requiresTransparencyBackground, "JPEG can never keep alpha")
        XCTAssertEqual(preflight.sourceByteCount.map(Int.init), encode([makeImage(alpha: 0.5)], as: .png).count)
    }

    func test_opaqueJPEG_toPNG_noBackgroundNeeded() throws {
        let url = try writeTemp(encode([makeImage(alpha: 1.0)], as: .jpeg), name: "opaque.jpg")
        let result = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .file(url), target: .png)

        let preflight = try XCTUnwrap(try? result.get())
        XCTAssertFalse(preflight.hasAlpha)
        XCTAssertFalse(preflight.requiresTransparencyBackground)
        XCTAssertFalse(preflight.hasHDRGainMap)
    }

    func test_multiFrameGIF_rejectedInTargetSize_firstFrameOnlyInQuality() throws {
        let frames = [makeImage(alpha: 1.0), makeImage(alpha: 1.0)]
        let url = try writeTemp(encode(frames, as: .gif), name: "animated.gif")

        // Target Size contract: reject before any preview or output.
        let targetSize = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .file(url), target: .jpeg)
        guard case .failure(.multiImageUnsupported) = targetSize else {
            return XCTFail("expected multiImageUnsupported, got \(targetSize)")
        }

        // Quality contract: accept with the first-frame-only notice.
        let quality = ImageIOSourceInspector(rejectsMultiImage: false)
            .preflight(input: .file(url), target: .png)
        let preflight = try XCTUnwrap(try? quality.get())
        XCTAssertEqual(preflight.frameCount, 2)
        XCTAssertTrue(preflight.firstFrameOnly)
    }

    func test_pdfFile_rejectedInBothModes() throws {
        let pdfData = makePDFData()
        let url = try writeTemp(pdfData, name: "document.pdf")

        for rejects in [true, false] {
            let result = ImageIOSourceInspector(rejectsMultiImage: rejects)
                .preflight(input: .file(url), target: .jpeg)
            guard case .failure(.pdfInput) = result else {
                return XCTFail("expected pdfInput (rejectsMultiImage: \(rejects)), got \(result)")
            }
        }
    }

    func test_missingFile_and_garbageData() throws {
        let missing = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .file(tempDirectory.appendingPathComponent("nope.png")), target: .jpeg)
        guard case .failure(.sourceMissing) = missing else {
            return XCTFail("expected sourceMissing, got \(missing)")
        }

        let garbageURL = try writeTemp(Data("not an image".utf8), name: "garbage.png")
        let garbageFile = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .file(garbageURL), target: .jpeg)
        guard case .failure(.undecodable) = garbageFile else {
            return XCTFail("expected undecodable, got \(garbageFile)")
        }

        let garbageBitmap = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .bitmap(Data("still not an image".utf8)), target: .jpeg)
        guard case .failure(.undecodable) = garbageBitmap else {
            return XCTFail("expected undecodable, got \(garbageBitmap)")
        }
    }

    func test_bitmapInput_carriesByteCountAndDimensions() throws {
        let data = encode([makeImage(width: 100, height: 80, alpha: 1.0)], as: .png)
        let result = ImageIOSourceInspector(rejectsMultiImage: true)
            .preflight(input: .bitmap(data), target: .jpeg)

        let preflight = try XCTUnwrap(try? result.get())
        XCTAssertEqual(preflight.dimensions, PixelDimensions(width: 100, height: 80))
        XCTAssertEqual(preflight.sourceByteCount, Int64(data.count))
    }

    private func makePDFData() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Capability cache

    func test_alphaCapability_staticFormats() {
        XCTAssertFalse(ImageIOCapabilityCache.targetPreservesAlpha(.jpeg))
        XCTAssertFalse(ImageIOCapabilityCache.targetPreservesAlpha(.bmp))
        XCTAssertTrue(ImageIOCapabilityCache.targetPreservesAlpha(.png))
        XCTAssertTrue(ImageIOCapabilityCache.targetPreservesAlpha(.tiff))
    }

    func test_alphaCapability_probeIsDeterministicAndSurvivesInvalidation() {
        for format in [ImageConversionFormat.heic, .avif]
        where ImageConversionFormat.availableTargets().contains(format) {
            let first = ImageIOCapabilityCache.targetPreservesAlpha(format)
            XCTAssertEqual(ImageIOCapabilityCache.targetPreservesAlpha(format), first)
            ImageIOCapabilityCache.invalidate()
            XCTAssertEqual(
                ImageIOCapabilityCache.targetPreservesAlpha(format), first,
                "\(format) probe must be stable on one runtime"
            )
        }
    }

    // MARK: - Source fingerprint

    func test_fileFingerprint_stableForUnchangedFile() throws {
        let url = try writeTemp(encode([makeImage(alpha: 1.0)], as: .png), name: "stable.png")
        let first = try SourceFingerprint.forFile(at: url)
        let second = try SourceFingerprint.forFile(at: url)
        XCTAssertEqual(first, second)
    }

    func test_fileFingerprint_changesWhenContentChanges() throws {
        let url = try writeTemp(Data("v1 content".utf8), name: "mutating.bin")
        let before = try SourceFingerprint.forFile(at: url)
        try Data("v2 content!".utf8).write(to: url)
        let after = try SourceFingerprint.forFile(at: url)
        XCTAssertNotEqual(before.contentDigest, after.contentDigest)
    }

    func test_fileFingerprint_distinguishesIdenticalContentAtDifferentPaths() throws {
        let content = Data("same bytes".utf8)
        let a = try SourceFingerprint.forFile(at: writeTemp(content, name: "a.bin"))
        let b = try SourceFingerprint.forFile(at: writeTemp(content, name: "b.bin"))
        XCTAssertEqual(a.contentDigest, b.contentDigest)
        XCTAssertNotEqual(a, b, "origin path/identity must differ")
    }

    func test_fileFingerprint_missingFileThrows() {
        XCTAssertThrowsError(
            try SourceFingerprint.forFile(at: tempDirectory.appendingPathComponent("gone.png"))
        )
    }

    func test_bitmapFingerprint_keyedByBasketIDAndContent() {
        let data = Data("bitmap bytes".utf8)
        let id = UUID()
        XCTAssertEqual(
            SourceFingerprint.forBitmap(data, basketItemID: id),
            SourceFingerprint.forBitmap(data, basketItemID: id)
        )
        XCTAssertNotEqual(
            SourceFingerprint.forBitmap(data, basketItemID: id),
            SourceFingerprint.forBitmap(data, basketItemID: UUID())
        )
        XCTAssertNotEqual(
            SourceFingerprint.forBitmap(data, basketItemID: id).contentDigest,
            SourceFingerprint.forBitmap(Data("other".utf8), basketItemID: id).contentDigest
        )
    }

    func test_streamedDigest_matchesOneShotDigest() throws {
        // Larger than one 1 MiB chunk so the loop actually streams.
        let big = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let url = try writeTemp(big, name: "big.bin")
        let streamed = try SourceFingerprint.streamedSHA256(of: url)
        let oneShot = SourceFingerprint.forBitmap(big, basketItemID: UUID()).contentDigest
        XCTAssertEqual(streamed, oneShot)
    }
}
