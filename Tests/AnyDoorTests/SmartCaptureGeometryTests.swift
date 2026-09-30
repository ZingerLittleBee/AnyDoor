import CoreGraphics
import XCTest
@testable import AnyDoor

final class SmartCaptureGeometryTests: XCTestCase {
    func testPrimaryDisplayAXFrameBecomesLocalAppKitPoints() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ax = CGRect(x: 100, y: 200, width: 300, height: 150)
        XCTAssertEqual(SelectionGeometry.localRect(fromCG: ax, screenFrame: display, flipHeight: 1080),
                       CGRect(x: 100, y: 730, width: 300, height: 150))
    }

    func testDisplayLeftOfPrimaryPreservesNegativeGlobalOrigin() {
        let display = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let ax = CGRect(x: -1340, y: 380, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.localRect(fromCG: ax, screenFrame: display, flipHeight: 1080),
                       CGRect(x: 100, y: 700, width: 200, height: 100))
        XCTAssertEqual(SelectionGeometry.cgGlobalRect(fromAppKit: display, flipHeight: 1080),
                       CGRect(x: -1440, y: 280, width: 1440, height: 900))
    }

    func testDisplayAbovePrimaryUsesPrimaryFlipAndNegativeAXY() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 200, y: 1080, width: 1280, height: 800)
        let flip = SelectionGeometry.globalFlipHeight(screenFrames: [above, primary], fallback: 0)
        let ax = CGRect(x: 250, y: -700, width: 200, height: 100)
        let local = SelectionGeometry.localRect(fromCG: ax, screenFrame: above, flipHeight: flip)
        XCTAssertEqual(local, CGRect(x: 50, y: 600, width: 200, height: 100))
        XCTAssertEqual(SelectionGeometry.appKitGlobalRect(fromCG: ax, flipHeight: flip),
                       local.offsetBy(dx: above.minX, dy: above.minY))
        XCTAssertEqual(SelectionGeometry.cgGlobalRect(fromAppKit: above, flipHeight: flip),
                       CGRect(x: 200, y: -800, width: 1280, height: 800))
    }

    func testRetinaScalingIsAppliedOnlyWhenCroppingFrozenImage() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let rect = CGRect(x: 50, y: 600, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.pixelRect(fromLocal: rect, bounds: bounds, backingScale: 2),
                       CGRect(x: 100, y: 200, width: 400, height: 200))
        XCTAssertEqual(SelectionGeometry.pixelRect(fromLocal: rect, bounds: bounds, backingScale: 1),
                       CGRect(x: 50, y: 100, width: 200, height: 100))
    }

    func testPartiallyOffDisplayRegionIsClippedBeforePixelConversion() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let clipped = CGRect(x: -20, y: 750, width: 100, height: 100).intersection(bounds)
        XCTAssertEqual(SelectionGeometry.pixelRect(fromLocal: clipped, bounds: bounds, backingScale: 2),
                       CGRect(x: 0, y: 0, width: 160, height: 100))
    }

    func testCoordinateConversionRoundTripsAcrossMixedDisplayOrigins() {
        for frame in [CGRect(x: -1000, y: -500, width: 800, height: 600),
                      CGRect(x: 120, y: 1080, width: 1280, height: 800)] {
            let cg = SelectionGeometry.cgGlobalRect(fromAppKit: frame, flipHeight: 1080)
            XCTAssertEqual(SelectionGeometry.appKitGlobalRect(fromCG: cg, flipHeight: 1080), frame)
        }
    }
}
