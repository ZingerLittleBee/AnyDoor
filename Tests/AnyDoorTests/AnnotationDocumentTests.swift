import XCTest
import CoreGraphics
@testable import AnyDoor

@MainActor
final class AnnotationDocumentTests: XCTestCase {

    private func makeImage(_ w: Int = 40, _ h: Int = 30) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func rect(_ x: CGFloat) -> AnnotationElement {
        AnnotationElement(kind: .rectangle(CGRect(x: x, y: x, width: 5, height: 5)))
    }

    /// Cancelling an in-progress gesture with `rollback()` must leave the document
    /// fully unchanged — including a redo stack that an earlier `undo()` built.
    /// Regression for the bug where `checkpoint()` cleared redo and `rollback()`
    /// never restored it, so a stray select-click silently destroyed redo history.
    func testRollbackPreservesRedoStack() {
        let doc = AnnotationDocument(baseImage: makeImage())
        doc.add(rect(1))
        doc.add(rect(2))
        XCTAssertEqual(doc.elements.count, 2)

        doc.undo()                       // -> 1 element; redo now holds the 2-element state
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertTrue(doc.canRedo)

        // A gesture that opens then immediately cancels (e.g. a select-click that
        // never moves): the document is identical afterwards.
        doc.beginEdit()
        doc.rollback()

        XCTAssertEqual(doc.elements.count, 1, "rollback should leave the document unchanged")
        XCTAssertTrue(doc.canRedo, "rollback must not destroy the existing redo stack")

        doc.redo()
        XCTAssertEqual(doc.elements.count, 2, "redo should restore the previously-undone element")
    }

    /// Guard: committing a genuine new action after an undo must STILL clear redo
    /// (the fix must not over-restore redo on normal mutations).
    func testNewActionAfterUndoStillClearsRedo() {
        let doc = AnnotationDocument(baseImage: makeImage())
        doc.add(rect(1))
        doc.add(rect(2))
        doc.undo()
        XCTAssertTrue(doc.canRedo)

        doc.add(rect(3))                 // a committed new element, not a cancelled gesture
        XCTAssertFalse(doc.canRedo, "committing a new action after undo must clear redo")
    }

    /// Guard: rollback after a fresh checkpoint with no prior redo leaves redo empty.
    func testRollbackWithoutPriorRedoLeavesRedoEmpty() {
        let doc = AnnotationDocument(baseImage: makeImage())
        doc.add(rect(1))
        doc.beginEdit()
        doc.rollback()

        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertFalse(doc.canRedo)
    }

    /// exportImage() must flush any pending inline text (the canvas registers a
    /// commit hook) before rendering, so text typed but not Return-committed —
    /// e.g. the user clicks Copy/Save/Pin/Done — is not silently dropped.
    func testExportImageFlushesPendingTextFirst() {
        let model = AnnotationEditorModel(image: makeImage())
        var flushed = false
        model.commitPendingText = { flushed = true }

        _ = model.exportImage()

        XCTAssertTrue(flushed, "exportImage must invoke the pending-text commit hook before rendering")
    }
}
