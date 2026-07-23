import CoreGraphics
import ImageCodec
import ImageIO
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class ImageIOCandidateEncoderTests: XCTestCase {

    // MARK: - Fixtures

    /// A gradient with enough detail that JPEG quality meaningfully changes
    /// encoded size.
    private func makeGradientImage(width: Int = 256, height: Int = 192, alpha: CGFloat = 1.0) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for x in 0..<width {
            for y in stride(from: 0, to: height, by: 4) {
                context.setFillColor(CGColor(
                    red: CGFloat(x % 251) / 251.0,
                    green: CGFloat((x &* y) % 241) / 241.0,
                    blue: CGFloat((x &+ y) % 239) / 239.0,
                    alpha: alpha
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 4))
            }
        }
        return context.makeImage()!
    }

    /// Encode an image with GPS, capture-detail EXIF, TIFF device fields, and
    /// an orientation tag — the ancillary payload Target Size must strip.
    private func makeSourceData(
        _ image: CGImage,
        format: ImageConversionFormat,
        withAncillaryMetadata: Bool,
        orientation: UInt32? = nil
    ) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, format.typeIdentifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [:]
        if withAncillaryMetadata {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLongitude: 121.4737,
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:10 12:00:00",
                kCGImagePropertyExifLensModel: "Test Lens 1.4",
                kCGImagePropertyExifUserComment: "secret comment",
            ]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "TestCam",
                kCGImagePropertyTIFFModel: "TestCam X100",
            ]
        }
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - Metadata policy

    func test_reencode_stripsAncillaryMetadataByConstruction() throws {
        let source = makeSourceData(makeGradientImage(), format: .jpeg, withAncillaryMetadata: true)
        // Prove the fixture actually contains the ancillary payload.
        XCTAssertFalse(CandidateAuditor.audit(source).ancillaryMetadataAbsent)

        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        let output = try encoder.encode(.init(
            format: .jpeg,
            quality: 85,
            dimensions: encoder.originalDimensions,
            transparencyBackgroundHex: nil
        ))

        let report = CandidateAuditor.audit(output)
        XCTAssertTrue(report.decodable)
        XCTAssertTrue(report.ancillaryMetadataAbsent, "GPS/EXIF capture/TIFF device fields must be gone")
        XCTAssertEqual(report.pixelDimensions, PixelDimensions(width: 256, height: 192))
    }

    func test_metadataPolicyRejectsGenericCommentsXMPAndEmbeddedThumbnails() {
        let commentedProperties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFImageDescription: "private workflow note",
            ],
        ]

        XCTAssertFalse(TargetMetadataPolicy.ancillaryMetadataAbsent(in: commentedProperties))
        XCTAssertFalse(TargetMetadataPolicy.ancillaryMetadataAbsent(
            in: [:],
            hasForbiddenMetadataTags: true
        ))
        XCTAssertFalse(TargetMetadataPolicy.ancillaryMetadataAbsent(
            in: [:],
            hasEmbeddedThumbnails: true
        ))

        let xmp = CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
            xmp,
            "http://ns.adobe.com/xap/1.0/" as CFString,
            "xmp" as CFString,
            &registrationError
        ))
        XCTAssertNil(registrationError)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp,
            nil,
            "xmp:Label" as CFString,
            "private label" as CFString
        ))
        XCTAssertTrue(TargetMetadataPolicy.metadataContainsAncillaryTags(xmp))
    }

    func test_reencode_preservesOrientation() throws {
        let source = makeSourceData(
            makeGradientImage(), format: .jpeg, withAncillaryMetadata: true, orientation: 6
        )
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        let output = try encoder.encode(.init(
            format: .jpeg,
            quality: 85,
            dimensions: encoder.originalDimensions,
            transparencyBackgroundHex: nil
        ))

        XCTAssertEqual(CandidateAuditor.audit(output).orientation, 6,
                       "orientation is display-critical and must survive the strip")
    }

    func test_reencode_preservesTheIntendedColorProfile() throws {
        let source = makeSourceData(makeGradientImage(), format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        let spec = ImageIOCandidateEncoder.EncodeSpec(
            format: .jpeg,
            quality: 85,
            dimensions: PixelDimensions(width: 128, height: 96),
            transparencyBackgroundHex: nil
        )

        let output = try encoder.encode(spec)
        let report = CandidateAuditor.audit(output)

        XCTAssertTrue(ImageColorProfileSignature.matches(
            expected: encoder.intendedColorProfile(for: spec),
            actual: report.colorProfile
        ))
    }

    // MARK: - Quality and resize

    func test_lowerQualityProducesSmallerBytes() throws {
        let source = makeSourceData(makeGradientImage(), format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        let dims = encoder.originalDimensions

        let high = try encoder.encode(.init(format: .jpeg, quality: 100, dimensions: dims, transparencyBackgroundHex: nil))
        let low = try encoder.encode(.init(format: .jpeg, quality: 40, dimensions: dims, transparencyBackgroundHex: nil))
        XCTAssertLessThan(low.count, high.count)
    }

    func test_resizeRendersRequestedDimensions() throws {
        let source = makeSourceData(makeGradientImage(), format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        let target = PixelDimensions(width: 128, height: 96)

        let output = try encoder.encode(.init(
            format: .jpeg, quality: 85, dimensions: target, transparencyBackgroundHex: nil
        ))
        XCTAssertEqual(CandidateAuditor.audit(output).pixelDimensions, target)
    }

    // MARK: - Transparency compositing

    func test_jpegCompositesExplicitBackground_notImplicitWhite() throws {
        // Fully transparent source: every output pixel must be the chosen
        // magenta, proving we composite ourselves rather than letting Image
        // I/O default to white.
        let transparent = makeGradientImage(width: 32, height: 32, alpha: 0.0)
        let source = makeSourceData(transparent, format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))

        let output = try encoder.encode(.init(
            format: .jpeg,
            quality: 100,
            dimensions: encoder.originalDimensions,
            transparencyBackgroundHex: "#FF00FF"
        ))

        let decoded = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(output as CFData, nil)!, 0, nil
        )!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 225, "red channel must be near 255")
        XCTAssertLessThan(pixel[1], 30, "green channel must be near 0")
        XCTAssertGreaterThan(pixel[2], 225, "blue channel must be near 255")
    }

    func test_heicPreservesAlphaWhenRuntimeSupportsIt() throws {
        try XCTSkipUnless(
            ImageConversionFormat.availableTargets().contains(.heic)
                && ImageIOCapabilityCache.targetPreservesAlpha(.heic),
            "runtime lacks HEIC alpha support"
        )
        let translucent = makeGradientImage(width: 32, height: 32, alpha: 0.5)
        let source = makeSourceData(translucent, format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))

        let output = try encoder.encode(.init(
            format: .heic,
            quality: 90,
            dimensions: encoder.originalDimensions,
            transparencyBackgroundHex: nil
        ))
        XCTAssertTrue(CandidateAuditor.audit(output).hasAlpha)
    }

    // MARK: - Pass-through

    func test_jpegPassThrough_stripsGPSAndKeepsPixels() throws {
        let source = makeSourceData(makeGradientImage(), format: .jpeg, withAncillaryMetadata: true)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))

        let rewritten = try XCTUnwrap(
            encoder.losslessPassThrough(as: .jpeg),
            "JPEG is expected to support the lossless metadata rewrite"
        )
        let report = CandidateAuditor.audit(rewritten)
        XCTAssertTrue(report.decodable)
        XCTAssertEqual(report.pixelDimensions, PixelDimensions(width: 256, height: 192))
        XCTAssertTrue(report.ancillaryMetadataAbsent)
        XCTAssertEqual(report.orientation, encoder.orientation ?? 1)
        XCTAssertTrue(ImageColorProfileSignature.matches(
            expected: encoder.sourceColorProfile,
            actual: report.colorProfile
        ))
        XCTAssertEqual(report.hasAlpha, encoder.sourceHasAlpha)
    }

    func test_passThrough_requiresMatchingSourceFormat() throws {
        let source = makeSourceData(makeGradientImage(), format: .png, withAncillaryMetadata: false)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        XCTAssertNil(encoder.losslessPassThrough(as: .jpeg),
                     "pass-through is defined only for same-format sources")
    }

    func test_avifPassThrough_neverCrashes_auditDecides() throws {
        try XCTSkipUnless(
            ImageConversionFormat.availableTargets().contains(.avif),
            "runtime lacks an AVIF encoder"
        )
        let source = makeSourceData(makeGradientImage(), format: .avif, withAncillaryMetadata: true)
        let encoder = try ImageIOCandidateEncoder(input: .bitmap(source))
        // Current probes show AVIF may reject the rewrite; either outcome is
        // acceptable as long as a non-nil result is judged by the audit.
        if let rewritten = encoder.losslessPassThrough(as: .avif) {
            _ = CandidateAuditor.audit(rewritten)
        }
    }

    // MARK: - Color parsing

    func test_hexColorParsing() {
        XCTAssertNotNil(ImageIOCandidateEncoder.color(fromHex: "#FFFFFF"))
        XCTAssertNotNil(ImageIOCandidateEncoder.color(fromHex: "#00ff88"))
        XCTAssertNil(ImageIOCandidateEncoder.color(fromHex: "FFFFFF"))
        XCTAssertNil(ImageIOCandidateEncoder.color(fromHex: "#FFF"))
        XCTAssertNil(ImageIOCandidateEncoder.color(fromHex: "#GGHHII"))
    }

    func test_undecodableInputThrows() {
        XCTAssertThrowsError(try ImageIOCandidateEncoder(input: .bitmap(Data("junk".utf8))))
    }
}
