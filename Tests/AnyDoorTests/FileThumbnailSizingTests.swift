import CoreGraphics
import XCTest
@testable import PluginSupport

final class FileThumbnailSizingTests: XCTestCase {
    private let target = CGSize(width: 460, height: 400)

    func testLandscapeBudgetUsesTargetHeightAndSourceAspectRatio() {
        let budget = FileThumbnailSizing.maxPixel(
            sourcePixelSize: CGSize(width: 1600, height: 900),
            filling: target
        )

        XCTAssertEqual(budget, 712)
    }

    func testUltrawideBudgetGrowsBeyondFixedThumbnailSize() {
        let budget = FileThumbnailSizing.maxPixel(
            sourcePixelSize: CGSize(width: 3200, height: 900),
            filling: target
        )

        XCTAssertEqual(budget, 1423)
    }

    func testTallBudgetUsesTargetWidthAndSourceAspectRatio() {
        let budget = FileThumbnailSizing.maxPixel(
            sourcePixelSize: CGSize(width: 900, height: 3200),
            filling: target
        )

        XCTAssertEqual(budget, 1636)
    }

    func testPathologicalAspectRatioIsCapped() {
        let budget = FileThumbnailSizing.maxPixel(
            sourcePixelSize: CGSize(width: 100_000, height: 100),
            filling: target
        )

        XCTAssertEqual(budget, FileThumbnailSizing.maximumFillMaxPixel)
    }

    func testMissingSourceMetadataFallsBackToTargetLongEdge() {
        let budget = FileThumbnailSizing.maxPixel(
            sourcePixelSize: nil,
            filling: target
        )

        XCTAssertEqual(budget, 460)
    }
}
