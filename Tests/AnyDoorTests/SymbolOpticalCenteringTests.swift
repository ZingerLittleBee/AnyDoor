import XCTest
@testable import AnyDoor

@MainActor
final class SymbolOpticalCenteringTests: XCTestCase {
    func testTallAndWideSymbolsShrinkWhileSquareOnesKeepTheirSize() {
        func balanced(_ symbol: String) -> CGFloat {
            SymbolOpticalCentering.balancedPointSize(symbol: symbol, pointSize: 14, side: 13.5, maxSide: 16)
        }
        XCTAssertEqual(balanced("square.grid.3x3"), 14)
        XCTAssertLessThan(balanced("doc.on.clipboard"), 14)
        XCTAssertLessThan(balanced("rectangle.on.rectangle"), 14)
    }

    func testScaleNeverGrowsASymbol() {
        let scale = SymbolOpticalCentering.balancedScale(
            inkSize: CGSize(width: 8, height: 8), side: 13.5, maxSide: 16
        )
        XCTAssertEqual(scale, 1)
    }

    func testScaleGoesHalfwayTowardTheTargetArea() {
        // Matching a 16pt square's area to a 13.5pt one takes a 13.5 / 16
        // scale; halfway is its square root.
        let scale = SymbolOpticalCentering.balancedScale(
            inkSize: CGSize(width: 16, height: 16), side: 13.5, maxSide: 16
        )
        XCTAssertEqual(scale, (13.5 / 16).squareRoot(), accuracy: 0.0001)
    }

    func testScaleKeepsTheLongerEdgeWithinMaxSide() {
        let scale = SymbolOpticalCentering.balancedScale(
            inkSize: CGSize(width: 20, height: 10), side: 13.5, maxSide: 16
        )
        XCTAssertEqual(scale, 0.8, accuracy: 0.0001)
    }

    func testCenteringSitsBetweenTheInkBoxAndItsCenterOfMass() {
        // Both ink boxes are already centered at 14pt, so box centering alone
        // would leave them in place. The tray carries its ink low and is
        // lifted; the pin carries its ink high in the head and is lowered.
        XCTAssertLessThan(SymbolOpticalCentering.correction(symbol: "tray.and.arrow.down", pointSize: 14).height, 0)
        XCTAssertGreaterThan(SymbolOpticalCentering.correction(symbol: "pin", pointSize: 14).height, 0)
    }
}
