import XCTest
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import AnyDoor

/// `@MainActor` because the helper composites with AppKit (`NSImage.lockFocus`),
/// which must run on the main thread.
@MainActor
final class BarcodeRecognizerTests: XCTestCase {

    /// Generates one QR code per payload and composites them vertically on a
    /// white canvas, first payload at the top. Returns the rasterized CGImage.
    private func renderImage(payloads: [String]) throws -> CGImage {
        let cellSize: CGFloat = 200
        let padding: CGFloat = 40
        let width: CGFloat = cellSize + padding * 2
        let height = padding * 2 + cellSize * CGFloat(max(payloads.count, 1))
            + padding * CGFloat(max(payloads.count - 1, 0))
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let context = CIContext()
        for (index, payload) in payloads.enumerated() {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else {
                throw XCTSkip("failed to generate QR image for \(payload)")
            }
            // Scale up from the filter's native 1-module-per-pixel output.
            let scale = cellSize / output.extent.width
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
                throw XCTSkip("failed to rasterize QR image for \(payload)")
            }
            // AppKit origin is bottom-left; draw the first payload near the top.
            let y = height - padding - cellSize * CGFloat(index + 1)
                - padding * CGFloat(index)
            let drawRect = NSRect(x: padding, y: y, width: cellSize, height: cellSize)
            NSGraphicsContext.current?.cgContext.draw(cg, in: drawRect)
        }
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("failed to rasterize the test image")
        }
        return cgImage
    }

    func testDecodesSingleQRCode() async throws {
        let payload = "https://example.com/anydoor"
        let image = try renderImage(payloads: [payload])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result, [payload])
    }

    func testReturnsCodesTopToBottom() async throws {
        let top = "FIRST"
        let bottom = "SECOND"
        let image = try renderImage(payloads: [top, bottom])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result.count, 2, "expected two payloads; got: \(result)")
        XCTAssertEqual(result.first, top)
        XCTAssertEqual(result.last, bottom)
    }

    func testBlankImageReturnsEmpty() async throws {
        let image = try renderImage(payloads: [])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result, [])
    }
}
