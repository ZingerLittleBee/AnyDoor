import CoreGraphics
import ImageIO
import XCTest
@testable import AnyDoor

final class ImageConverterTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-image-converter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImage(width: Int, height: Int, color: CGColor) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func write(_ image: CGImage, to url: URL, typeIdentifier: String = "public.png") throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeAnimatedGIF(_ images: [CGImage], to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            "com.compuserve.gif" as CFString,
            images.count,
            nil
        ))
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgb(_ image: CGImage, x: Int = 0, y: Int = 0) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func testGarbageInputThrows() throws {
        let dir = try tempDirectory()
        let input = dir.appendingPathComponent("not-image.dat")
        let output = dir.appendingPathComponent("not-image.png")
        try Data("not an image".utf8).write(to: input)

        XCTAssertThrowsError(
            try ImageConverter().convertFile(at: input, to: output, format: .png)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testAnimatedGIFConvertsFirstFrameOnly() throws {
        let dir = try tempDirectory()
        let input = dir.appendingPathComponent("animated.gif")
        let output = dir.appendingPathComponent("animated.png")
        let red = makeImage(width: 8, height: 8, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = makeImage(width: 8, height: 8, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try writeAnimatedGIF([red, blue], to: input)

        try ImageConverter().convertFile(at: input, to: output, format: .png)

        let pixel = rgb(try decode(output))
        XCTAssertGreaterThan(pixel.r, 200)
        XCTAssertLessThan(pixel.g, 40)
        XCTAssertLessThan(pixel.b, 40)
    }

    func testICOOutputDownscalesTo256PixelCeiling() throws {
        guard ImageConversionFormat.availableTargets().contains(.ico) else {
            throw XCTSkip("ICO encoder unavailable on this system")
        }
        let dir = try tempDirectory()
        let input = dir.appendingPathComponent("large.png")
        let output = dir.appendingPathComponent("large.ico")
        try write(
            makeImage(width: 640, height: 320, color: CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)),
            to: input
        )

        try ImageConverter().convertFile(at: input, to: output, format: .ico)

        let decoded = try decode(output)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 256)
    }

    func testPDFOutputIsSinglePage() throws {
        guard ImageConversionFormat.availableTargets().contains(.pdf) else {
            throw XCTSkip("PDF encoder unavailable on this system")
        }
        let dir = try tempDirectory()
        let input = dir.appendingPathComponent("source.png")
        let output = dir.appendingPathComponent("source.pdf")
        try write(
            makeImage(width: 80, height: 60, color: CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)),
            to: input
        )

        try ImageConverter().convertFile(at: input, to: output, format: .pdf)

        let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
    }
}
