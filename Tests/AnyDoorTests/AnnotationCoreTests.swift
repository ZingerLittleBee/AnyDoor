import XCTest
import CoreGraphics
@testable import AnyDoor

final class AnnotationCoreTests: XCTestCase {

    // MARK: - Model / style

    func testRGBAWithAlpha() {
        let c = RGBAColor.red.withAlpha(0.4)
        XCTAssertEqual(c.r, RGBAColor.red.r)
        XCTAssertEqual(c.a, 0.4)
    }

    func testPaletteHasSwatches() {
        XCTAssertGreaterThanOrEqual(RGBAColor.palette.count, 5)
    }

    func testToolClassification() {
        XCTAssertTrue(AnnotationTool.rectangle.isRectDrag)
        XCTAssertTrue(AnnotationTool.crop.isRectDrag)
        XCTAssertTrue(AnnotationTool.arrow.isTwoPoint)
        XCTAssertTrue(AnnotationTool.freehand.isPath)
        XCTAssertFalse(AnnotationTool.text.isPath)
    }

    // MARK: - Geometry

    func testArrowHeadForHorizontalArrow() {
        let (l, r) = AnnotationGeometry.arrowHead(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), length: 10, spread: .pi / 6
        )
        // Barbs sit behind the tip, symmetric about the shaft (y = 0).
        XCTAssertEqual(l.x, 100 - 10 * cos(-CGFloat.pi / 6), accuracy: 0.001)
        XCTAssertEqual(l.y, -10 * sin(-CGFloat.pi / 6), accuracy: 0.001)
        XCTAssertEqual(r.x, l.x, accuracy: 0.001)
        XCTAssertEqual(r.y, -l.y, accuracy: 0.001)
        XCTAssertLessThan(l.x, 100) // behind the tip
    }

    func testCounterCircleRect() {
        let rect = AnnotationGeometry.counterCircleRect(center: CGPoint(x: 50, y: 60), radius: 14)
        XCTAssertEqual(rect, CGRect(x: 36, y: 46, width: 28, height: 28))
    }

    func testClampCropNormalizesAndClamps() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Reversed drag direction + overshoot.
        let r = AnnotationGeometry.clampCrop(CGRect(x: 90, y: 90, width: -120, height: -40), to: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 50, width: 90, height: 40))
    }

    func testDistanceToSegment() {
        let d = AnnotationGeometry.distance(from: CGPoint(x: 50, y: 10), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        XCTAssertEqual(d, 10, accuracy: 0.001)
    }

    func testViewToImageWithFullRegionIsIdentity() {
        let shown = CGRect(x: 0, y: 0, width: 100, height: 80)
        let fitted = CGRect(x: 0, y: 0, width: 100, height: 80)
        XCTAssertEqual(AnnotationGeometry.viewToImage(CGPoint(x: 25, y: 40), fitted: fitted, shownRect: shown),
                       CGPoint(x: 25, y: 40))
    }

    func testViewToImageWithCroppedRegionOffsetsAndScales() {
        // Canvas zoomed 2x to show the (20,10,40,30) region of the full image.
        let shown = CGRect(x: 20, y: 10, width: 40, height: 30)
        let fitted = CGRect(x: 0, y: 0, width: 80, height: 60)
        XCTAssertEqual(AnnotationGeometry.viewToImage(CGPoint(x: 0, y: 0), fitted: fitted, shownRect: shown),
                       CGPoint(x: 20, y: 10))
        XCTAssertEqual(AnnotationGeometry.viewToImage(CGPoint(x: 80, y: 60), fitted: fitted, shownRect: shown),
                       CGPoint(x: 60, y: 40))
    }

    func testImageToViewRectWithCroppedRegion() {
        let shown = CGRect(x: 20, y: 10, width: 40, height: 30)
        let fitted = CGRect(x: 0, y: 0, width: 80, height: 60)
        let r = AnnotationGeometry.imageToViewRect(CGRect(x: 30, y: 20, width: 10, height: 5),
                                                   fitted: fitted, shownRect: shown)
        XCTAssertEqual(r, CGRect(x: 20, y: 20, width: 20, height: 10))
    }

    func testHitTestLineAndRect() {
        let line = AnnotationElement(kind: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 4), element: line, tolerance: 8))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 40), element: line, tolerance: 8))

        let rect = AnnotationElement(kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 40)))
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 30, y: 30), element: rect))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 200, y: 200), element: rect))
    }

    // MARK: - Document (MainActor)

    @MainActor
    private func makeDoc(_ w: Int = 100, _ h: Int = 80) -> AnnotationDocument {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return AnnotationDocument(baseImage: ctx.makeImage()!)
    }

    @MainActor
    func testAddPushesUndoAndUndoRedoRestore() {
        let doc = makeDoc()
        XCTAssertFalse(doc.canUndo)
        doc.add(AnnotationElement(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10))))
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertTrue(doc.canUndo)

        doc.undo()
        XCTAssertEqual(doc.elements.count, 0)
        XCTAssertTrue(doc.canRedo)

        doc.redo()
        XCTAssertEqual(doc.elements.count, 1)
    }

    @MainActor
    func testCounterIncrementsAndUndoRestoresCounter() {
        let doc = makeDoc()
        doc.addCounter(at: CGPoint(x: 10, y: 10), style: .default)
        doc.addCounter(at: CGPoint(x: 20, y: 20), style: .default)
        XCTAssertEqual(doc.nextCounter, 3)
        if case let .counter(n, _) = doc.elements.last?.kind { XCTAssertEqual(n, 2) } else { XCTFail("expected counter") }

        doc.undo()
        XCTAssertEqual(doc.nextCounter, 2)
        XCTAssertEqual(doc.elements.count, 1)
    }

    @MainActor
    func testCropSetAndClear() {
        let doc = makeDoc(100, 100)
        doc.setCrop(CGRect(x: 10, y: 10, width: 200, height: 50)) // overshoots width
        XCTAssertEqual(doc.cropRect, CGRect(x: 10, y: 10, width: 90, height: 50))
        doc.clearCrop()
        XCTAssertNil(doc.cropRect)
        doc.undo() // restores the crop
        XCTAssertEqual(doc.cropRect, CGRect(x: 10, y: 10, width: 90, height: 50))
    }

    @MainActor
    func testCropUndoRestoresUncropped() {
        let doc = makeDoc(100, 100)
        XCTAssertNil(doc.cropRect)
        doc.setCrop(CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertEqual(doc.cropRect, CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertTrue(doc.canUndo)
        doc.undo() // undoing the first crop returns to the full, uncropped image
        XCTAssertNil(doc.cropRect)
    }

    @MainActor
    func testRemoveById() {
        let doc = makeDoc()
        let id = doc.add(AnnotationElement(kind: .ellipse(CGRect(x: 0, y: 0, width: 5, height: 5))))
        doc.add(AnnotationElement(kind: .rectangle(CGRect(x: 1, y: 1, width: 5, height: 5))))
        doc.remove(id: id)
        XCTAssertEqual(doc.elements.count, 1)
        if case .rectangle = doc.elements.first?.kind {} else { XCTFail("wrong element remained") }
    }

    @MainActor
    func testUpdateLastKindDoesNotPushUndo() {
        let doc = makeDoc()
        doc.add(AnnotationElement(kind: .rectangle(CGRect(x: 0, y: 0, width: 1, height: 1))))
        let undoDepthBefore = doc.canUndo
        doc.updateLastKind(.rectangle(CGRect(x: 0, y: 0, width: 50, height: 50)))
        // Still a single undo step (the add), and the geometry updated.
        XCTAssertTrue(undoDepthBefore)
        doc.undo()
        XCTAssertEqual(doc.elements.count, 0) // one undo removes the whole add+drag
    }
}
