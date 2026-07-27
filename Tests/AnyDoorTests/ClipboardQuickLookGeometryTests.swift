import CoreGraphics
import XCTest
@testable import AnyDoor

final class ClipboardQuickLookGeometryTests: XCTestCase {
    private let visibleSize = CGSize(width: 1200, height: 1000)

    func testSmallSquareMeetsMinimumWithoutChangingAspectRatio() {
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: CGSize(width: 100, height: 100),
            backingScale: 2,
            visibleSize: visibleSize
        )

        XCTAssertEqual(size, CGSize(width: 240, height: 240))
    }

    func testTallImagePreservesAspectRatioWhenMinimumWidthCannotFit() {
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: CGSize(width: 100, height: 1000),
            backingScale: 2,
            visibleSize: visibleSize
        )

        XCTAssertEqual(size, CGSize(width: 70, height: 700))
        XCTAssertEqual(size.width / size.height, 0.1, accuracy: 0.001)
    }

    func testLargeImageShrinksUniformlyToScreenBudget() {
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: CGSize(width: 2400, height: 1200),
            backingScale: 2,
            visibleSize: visibleSize
        )

        XCTAssertEqual(size, CGSize(width: 720, height: 360))
    }

    func testDocumentUsesGenericScreenRelativeSize() {
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: nil,
            backingScale: 2,
            visibleSize: visibleSize
        )

        XCTAssertEqual(size, CGSize(width: 720, height: 600))
    }
}
