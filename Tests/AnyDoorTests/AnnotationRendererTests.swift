import XCTest
import CoreGraphics
@testable import AnyDoor

@MainActor
final class AnnotationRendererTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testRenderEmptyMatchesBaseSize() {
        let doc = AnnotationDocument(baseImage: makeImage(120, 90))
        let out = AnnotationRenderer.render(doc)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 120)
        XCTAssertEqual(out?.height, 90)
    }

    func testRenderWithCropChangesSize() {
        let doc = AnnotationDocument(baseImage: makeImage(120, 90))
        doc.setCrop(CGRect(x: 10, y: 10, width: 40, height: 30))
        let out = AnnotationRenderer.render(doc)
        XCTAssertEqual(out?.width, 40)
        XCTAssertEqual(out?.height, 30)
    }

    func testRenderEachElementKindSucceeds() {
        let doc = AnnotationDocument(baseImage: makeImage())
        doc.add(AnnotationElement(kind: .arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 40))))
        doc.add(AnnotationElement(kind: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 50, y: 50))))
        doc.add(AnnotationElement(kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 20))))
        doc.add(AnnotationElement(kind: .ellipse(CGRect(x: 10, y: 10, width: 30, height: 30))))
        doc.add(AnnotationElement(kind: .freehand([CGPoint(x: 1, y: 1), CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 5)])))
        doc.add(AnnotationElement(kind: .highlighter([CGPoint(x: 2, y: 2), CGPoint(x: 40, y: 40)])))
        doc.add(AnnotationElement(kind: .text("Hi", origin: CGPoint(x: 8, y: 8))))
        doc.add(AnnotationElement(kind: .redaction(CGRect(x: 20, y: 20, width: 25, height: 12))))
        doc.add(AnnotationElement(kind: .blur(CGRect(x: 30, y: 30, width: 40, height: 30))))
        doc.add(AnnotationElement(kind: .pixelate(CGRect(x: 5, y: 40, width: 40, height: 30))))
        doc.addCounter(at: CGPoint(x: 70, y: 50), style: .default)

        let out = AnnotationRenderer.render(doc)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 120)
        XCTAssertEqual(out?.height, 90)
    }

    func testRenderImageReturnsNSImage() {
        let doc = AnnotationDocument(baseImage: makeImage())
        XCTAssertNotNil(AnnotationRenderer.renderImage(doc))
    }

    // MARK: - Orientation

    /// Builds an RGBA8 image with four distinctly colored quadrants where row 0 is
    /// the visual TOP, so a render round-trip reveals any vertical flip / mirror.
    /// TL=red, TR=green, BL=blue, BR=yellow.
    private func quadrantImage(_ w: Int = 80, _ h: Int = 60) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let top = y < h / 2
                let left = x < w / 2
                let rgb: (UInt8, UInt8, UInt8)
                switch (top, left) {
                case (true, true): rgb = (255, 0, 0)
                case (true, false): rgb = (0, 255, 0)
                case (false, true): rgb = (0, 0, 255)
                case (false, false): rgb = (255, 255, 0)
                }
                bytes[i] = rgb.0; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.2; bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Reads RGB at (x, y) from a CGImage's raw data; row 0 is the top.
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let data = img.dataProvider!.data!
        let ptr = CFDataGetBytePtr(data)!
        let i = y * img.bytesPerRow + x * (img.bitsPerPixel / 8)
        return (Int(ptr[i]), Int(ptr[i + 1]), Int(ptr[i + 2]))
    }

    func testRendererPreservesOrientation() {
        let doc = AnnotationDocument(baseImage: quadrantImage(80, 60))
        let out = AnnotationRenderer.render(doc, applyCrop: false)!

        let tl = pixel(out, 20, 15)  // expect red
        let tr = pixel(out, 60, 15)  // expect green
        let bl = pixel(out, 20, 45)  // expect blue
        let br = pixel(out, 60, 45)  // expect yellow

        XCTAssertTrue(tl.r > 200 && tl.g < 80 && tl.b < 80, "top-left should be red, got \(tl)")
        XCTAssertTrue(tr.g > 200 && tr.r < 80 && tr.b < 80, "top-right should be green, got \(tr)")
        XCTAssertTrue(bl.b > 200 && bl.r < 80 && bl.g < 80, "bottom-left should be blue, got \(bl)")
        XCTAssertTrue(br.r > 200 && br.g > 200 && br.b < 80, "bottom-right should be yellow, got \(br)")
    }

    func testElementsDrawInTopLeftSpace() {
        let doc = AnnotationDocument(baseImage: quadrantImage(80, 60))
        // Black redaction over the TOP-LEFT quadrant in top-left image coords.
        doc.add(AnnotationElement(kind: .redaction(CGRect(x: 0, y: 0, width: 40, height: 30))))
        let out = AnnotationRenderer.render(doc, applyCrop: false)!

        let tl = pixel(out, 20, 15)  // covered by redaction -> black
        let br = pixel(out, 60, 45)  // untouched -> yellow

        XCTAssertTrue(tl.r < 40 && tl.g < 40 && tl.b < 40, "top-left should be redacted black, got \(tl)")
        XCTAssertTrue(br.r > 200 && br.g > 200 && br.b < 80, "bottom-right should stay yellow, got \(br)")
    }

    func testCropExportsTheTopLeftRegion() {
        let doc = AnnotationDocument(baseImage: quadrantImage(80, 60))
        doc.setCrop(CGRect(x: 0, y: 0, width: 40, height: 30))  // top-left quadrant, top-left coords
        let out = AnnotationRenderer.render(doc)!  // applyCrop defaults to true

        XCTAssertEqual(out.width, 40)
        XCTAssertEqual(out.height, 30)
        let center = pixel(out, 20, 15)
        XCTAssertTrue(center.r > 200 && center.g < 80 && center.b < 80,
                      "cropping the top-left rect should keep the red quadrant, got \(center)")
    }
}
