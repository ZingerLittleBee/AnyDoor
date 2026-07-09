import CoreGraphics
import XCTest
@testable import AnyDoor

final class CropGeometryTests: XCTestCase {
    private let imageBounds = CGRect(x: 0, y: 0, width: 100, height: 80)

    func testHandleHitTestCoversAllHandlesInsideOutsideAndToleranceEdges() {
        let rect = CGRect(x: 20, y: 15, width: 60, height: 40)

        for handle in CropHandle.allCases {
            XCTAssertEqual(
                CropGeometry.hitTest(point: CropGeometry.handleCenter(handle, in: rect), viewRect: rect, tolerance: 10),
                .handle(handle),
                "\(handle) should hit at its visual center"
            )
        }

        XCTAssertEqual(CropGeometry.hitTest(point: CGPoint(x: 50, y: 35), viewRect: rect, tolerance: 10), .inside)
        XCTAssertEqual(CropGeometry.hitTest(point: CGPoint(x: 0, y: 90), viewRect: rect, tolerance: 10), .outside)

        let top = CropGeometry.handleCenter(.top, in: rect)
        XCTAssertEqual(CropGeometry.hitTest(point: CGPoint(x: top.x, y: top.y - 13.5), viewRect: rect, tolerance: 10), .handle(.top))
        XCTAssertEqual(CropGeometry.hitTest(point: CGPoint(x: top.x, y: top.y - 15), viewRect: rect, tolerance: 10), .outside)
    }

    func testAspectSnapPreservesCenterAndTakesMaximumFit() {
        let snapped = CropGeometry.snapAspect(rect: CGRect(x: 10, y: 20, width: 40, height: 20), ratio: 1, in: imageBounds)
        assertRect(snapped, CGRect(x: 0, y: 0, width: 60, height: 60))
        XCTAssertEqual(snapped.midX, 30, accuracy: 0.001)
        XCTAssertEqual(snapped.midY, 30, accuracy: 0.001)
    }

    func testAspectSnapClampsToBoundsNearAnEdge() {
        let snapped = CropGeometry.snapAspect(rect: CGRect(x: 80, y: 30, width: 10, height: 10), ratio: 16 / 9, in: imageBounds)
        assertRect(snapped, CGRect(x: 70, y: 26.5625, width: 30, height: 16.875))
    }

    func testAspectRatioOrientationFlip() {
        XCTAssertEqual(CropAspectPreset.fourThree.ratio(imageBounds: imageBounds, flipped: false) ?? 0, 4 / 3, accuracy: 0.001)
        XCTAssertEqual(CropAspectPreset.fourThree.ratio(imageBounds: imageBounds, flipped: true) ?? 0, 3 / 4, accuracy: 0.001)
        XCTAssertEqual(CropAspectPreset.original.ratio(imageBounds: imageBounds, flipped: true) ?? 0, 100 / 80, accuracy: 0.001)
        XCTAssertFalse(CropAspectPreset.square.allowsOrientationFlip)
    }

    func testCornerResizeWithRatioKeepsAnchorAndRatio() {
        let resized = CropGeometry.resize(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            handle: .topLeft,
            to: CGPoint(x: -100, y: -100),
            in: imageBounds,
            aspectRatio: 1
        )

        assertRect(resized, CGRect(x: 10, y: 0, width: 50, height: 50))
        XCTAssertEqual(resized.maxX, 60, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, 50, accuracy: 0.001)
        XCTAssertEqual(resized.width / resized.height, 1, accuracy: 0.001)
    }

    func testCornerResizeWithRatioEnforcesMinimumWithoutFlipping() {
        let resized = CropGeometry.resize(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            handle: .topLeft,
            to: CGPoint(x: 58, y: 48),
            in: imageBounds,
            aspectRatio: 1
        )

        assertRect(resized, CGRect(x: 52, y: 42, width: 8, height: 8))
    }

    func testEdgeResizeWithRatioAdjustsOtherDimensionSymmetrically() {
        let resized = CropGeometry.resize(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            handle: .right,
            to: CGPoint(x: 80, y: 40),
            in: imageBounds,
            aspectRatio: 2
        )

        assertRect(resized, CGRect(x: 20, y: 20, width: 60, height: 30))
        XCTAssertEqual(resized.midY, 35, accuracy: 0.001)
    }

    func testTopEdgeResizeWithRatioClampsSymmetricWidth() {
        let resized = CropGeometry.resize(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            handle: .top,
            to: CGPoint(x: 40, y: 0),
            in: imageBounds,
            aspectRatio: 2
        )

        assertRect(resized, CGRect(x: 0, y: 10, width: 80, height: 40))
        XCTAssertEqual(resized.midX, 40, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, 50, accuracy: 0.001)
    }

    func testFreeformEdgeAndCornerResizeBasics() {
        let rect = CGRect(x: 20, y: 20, width: 40, height: 30)

        let right = CropGeometry.resize(rect: rect, handle: .right, to: CGPoint(x: 90, y: 30), in: imageBounds, aspectRatio: nil)
        assertRect(right, CGRect(x: 20, y: 20, width: 70, height: 30))

        let leftMin = CropGeometry.resize(rect: rect, handle: .left, to: CGPoint(x: 59, y: 30), in: imageBounds, aspectRatio: nil)
        assertRect(leftMin, CGRect(x: 52, y: 20, width: 8, height: 30))

        let topLeft = CropGeometry.resize(rect: rect, handle: .topLeft, to: CGPoint(x: 10, y: 5), in: imageBounds, aspectRatio: nil)
        assertRect(topLeft, CGRect(x: 10, y: 5, width: 50, height: 45))
    }

    func testMoveAndKeyboardNudgeClampToBounds() {
        let rect = CGRect(x: 60, y: 70, width: 30, height: 10)
        assertRect(CropGeometry.move(rect: rect, by: CGVector(dx: 20, dy: 20), in: imageBounds), CGRect(x: 70, y: 70, width: 30, height: 10))
        assertRect(CropGeometry.nudge(rect: rect, dx: -100, dy: -100, in: imageBounds), CGRect(x: 0, y: 0, width: 30, height: 10))
    }

    func testCommitClassification() {
        let initial = CGRect(x: 10, y: 10, width: 50, height: 40)
        XCTAssertEqual(CropGeometry.classifyCommit(initial: initial, current: initial, imageBounds: imageBounds), .noOp)
        XCTAssertEqual(CropGeometry.classifyCommit(initial: initial, current: imageBounds, imageBounds: imageBounds), .clear)
        XCTAssertEqual(
            CropGeometry.classifyCommit(initial: initial, current: CGRect(x: 5, y: 5, width: 30, height: 30), imageBounds: imageBounds),
            .set(CGRect(x: 5, y: 5, width: 30, height: 30))
        )
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
