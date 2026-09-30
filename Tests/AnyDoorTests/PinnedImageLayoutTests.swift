import XCTest
@testable import AnyDoor

final class PinnedImageLayoutTests: XCTestCase {
    func testLandscapeImageStartsAtCappedAspectRatio() {
        XCTAssertEqual(
            PinnedImageLayout.initialSize(for: CGSize(width: 1200, height: 800)),
            CGSize(width: 360, height: 240)
        )
    }

    func testPortraitImageCapsItsHeightToo() {
        XCTAssertEqual(
            PinnedImageLayout.initialSize(for: CGSize(width: 800, height: 1200)),
            CGSize(width: 240, height: 360)
        )
    }

    func testSmallImageIsNotUpscaledWhenControlsAlreadyFit() {
        let size = CGSize(width: 240, height: 160)
        XCTAssertEqual(PinnedImageLayout.initialSize(for: size), size)
    }

    func testTinyImageGetsRoomForTheControls() {
        XCTAssertEqual(
            PinnedImageLayout.initialSize(for: CGSize(width: 20, height: 10)),
            PinnedImageLayout.minimumSize
        )
    }

    func testVeryWideAndTallCapturesGetLetterboxingInsteadOfUnusableControls() {
        XCTAssertEqual(
            PinnedImageLayout.initialSize(for: CGSize(width: 4000, height: 10)),
            CGSize(width: 360, height: 100)
        )
        XCTAssertEqual(
            PinnedImageLayout.initialSize(for: CGSize(width: 10, height: 4000)),
            CGSize(width: 180, height: 360)
        )
    }

    func testInvalidImageSizesUseASafeMinimum() {
        let invalid: [CGSize] = [
            .zero,
            CGSize(width: -1, height: 100),
            CGSize(width: 100, height: 0),
            CGSize(width: CGFloat.nan, height: 100),
            CGSize(width: 100, height: CGFloat.infinity),
        ]
        for size in invalid {
            XCTAssertEqual(PinnedImageLayout.initialSize(for: size), PinnedImageLayout.minimumSize)
        }
    }
}
