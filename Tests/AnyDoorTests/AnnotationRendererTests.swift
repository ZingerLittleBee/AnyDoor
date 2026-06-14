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
}
