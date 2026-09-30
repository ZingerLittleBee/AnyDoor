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

    func testResizeRegionsAreEightInsideZonesWithCornersFirst() {
        let bounds = CGRect(x: -40, y: 20, width: 300, height: 200)
        let expected: [(SelectionHandle, CGRect)] = [
            (.topLeft, CGRect(x: -40, y: 212, width: 8, height: 8)),
            (.topRight, CGRect(x: 252, y: 212, width: 8, height: 8)),
            (.bottomRight, CGRect(x: 252, y: 20, width: 8, height: 8)),
            (.bottomLeft, CGRect(x: -40, y: 20, width: 8, height: 8)),
            (.top, CGRect(x: -32, y: 212, width: 284, height: 8)),
            (.right, CGRect(x: 252, y: 28, width: 8, height: 184)),
            (.bottom, CGRect(x: -32, y: 20, width: 284, height: 8)),
            (.left, CGRect(x: -40, y: 28, width: 8, height: 184)),
        ]
        let regions = PinnedImageLayout.resizeRegions(in: bounds)

        XCTAssertEqual(regions.map { $0.0 }, expected.map { $0.0 })
        XCTAssertEqual(regions.map { $0.1 }, expected.map { $0.1 })
        for (index, region) in regions.enumerated() {
            XCTAssertTrue(bounds.contains(region.1))
            for other in regions.dropFirst(index + 1) {
                XCTAssertTrue(region.1.intersection(other.1).isEmpty)
            }
        }
    }

    func testInsideResizeBorderIsCompletelyCoveredWithoutBodyOverlap() {
        let bounds = CGRect(x: -180, y: -100, width: 180, height: 100)
        let interior = bounds.insetBy(dx: 8, dy: 8)
        let regions = PinnedImageLayout.resizeRegions(in: bounds)

        for x in 0..<180 {
            for y in 0..<100 {
                let point = CGPoint(x: bounds.minX + CGFloat(x) + 0.5, y: bounds.minY + CGFloat(y) + 0.5)
                let hits = regions.filter { $0.1.contains(point) }
                XCTAssertEqual(hits.count, interior.contains(point) ? 0 : 1, "Point: \(point)")
            }
        }
    }

    func testResizeHitTestingFindsAllCornersAndTheFullConnectingEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let cases: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: 0, y: 199)),
            (.topRight, CGPoint(x: 299, y: 199)),
            (.bottomRight, CGPoint(x: 299, y: 0)),
            (.bottomLeft, CGPoint(x: 0, y: 0)),
            (.top, CGPoint(x: 8, y: 199)),
            (.top, CGPoint(x: 291, y: 192)),
            (.right, CGPoint(x: 292, y: 8)),
            (.right, CGPoint(x: 299, y: 191)),
            (.bottom, CGPoint(x: 8, y: 0)),
            (.bottom, CGPoint(x: 291, y: 7)),
            (.left, CGPoint(x: 0, y: 8)),
            (.left, CGPoint(x: 7, y: 191)),
        ]

        for (handle, point) in cases {
            XCTAssertEqual(PinnedImageLayout.resizeHandle(at: point, in: bounds), handle, "Point: \(point)")
        }
    }

    func testBodyAndOutsidePointsAreNotResizeHandles() {
        let bounds = CGRect(x: -300, y: 400, width: 300, height: 200)
        let points = [
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.minX + 8, y: bounds.minY + 8),
            CGPoint(x: bounds.maxX - 8.1, y: bounds.maxY - 8.1),
            CGPoint(x: bounds.minX - 0.1, y: bounds.midY),
            CGPoint(x: bounds.maxX + 0.1, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.minY - 0.1),
            CGPoint(x: bounds.midX, y: bounds.maxY + 0.1),
            CGPoint(x: bounds.minX - 1, y: bounds.minY - 1),
        ]

        for point in points {
            XCTAssertNil(PinnedImageLayout.resizeHandle(at: point, in: bounds), "Point: \(point)")
        }
        XCTAssertTrue(PinnedImageLayout.resizeRegions(in: .zero).isEmpty)
        XCTAssertNil(PinnedImageLayout.resizeHandle(at: .zero, in: .zero))
    }

    func testAllEightHandlesResizeIndependentlyInYUpCoordinates() {
        let initialFrame = CGRect(x: 100, y: 200, width: 300, height: 200)
        let delta = CGSize(width: 40, height: 30)
        let cases: [(SelectionHandle, CGRect)] = [
            (.topLeft, CGRect(x: 140, y: 200, width: 260, height: 230)),
            (.top, CGRect(x: 100, y: 200, width: 300, height: 230)),
            (.topRight, CGRect(x: 100, y: 200, width: 340, height: 230)),
            (.right, CGRect(x: 100, y: 200, width: 340, height: 200)),
            (.bottomRight, CGRect(x: 100, y: 230, width: 340, height: 170)),
            (.bottom, CGRect(x: 100, y: 230, width: 300, height: 170)),
            (.bottomLeft, CGRect(x: 140, y: 230, width: 260, height: 170)),
            (.left, CGRect(x: 140, y: 200, width: 260, height: 200)),
        ]

        for (handle, expected) in cases {
            XCTAssertEqual(PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: delta), expected, "Handle: \(handle)")
        }
    }

    func testEveryHandleStopsAtTheMinimumWhenDraggedAcrossItsAnchor() {
        let initialFrame = CGRect(x: 100, y: 200, width: 300, height: 200)
        let cases: [(SelectionHandle, CGSize, CGRect)] = [
            (.topLeft, CGSize(width: 10_000, height: -10_000), CGRect(x: 220, y: 200, width: 180, height: 100)),
            (.top, CGSize(width: 10_000, height: -10_000), CGRect(x: 100, y: 200, width: 300, height: 100)),
            (.topRight, CGSize(width: -10_000, height: -10_000), CGRect(x: 100, y: 200, width: 180, height: 100)),
            (.right, CGSize(width: -10_000, height: -10_000), CGRect(x: 100, y: 200, width: 180, height: 200)),
            (.bottomRight, CGSize(width: -10_000, height: 10_000), CGRect(x: 100, y: 300, width: 180, height: 100)),
            (.bottom, CGSize(width: 10_000, height: 10_000), CGRect(x: 100, y: 300, width: 300, height: 100)),
            (.bottomLeft, CGSize(width: 10_000, height: 10_000), CGRect(x: 220, y: 300, width: 180, height: 100)),
            (.left, CGSize(width: 10_000, height: 10_000), CGRect(x: 220, y: 200, width: 180, height: 200)),
        ]

        for (handle, delta, expected) in cases {
            let result = PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: delta)
            XCTAssertEqual(result, expected, "Handle: \(handle)")
            XCTAssertGreaterThanOrEqual(result.width, PinnedImageLayout.minimumSize.width)
            XCTAssertGreaterThanOrEqual(result.height, PinnedImageLayout.minimumSize.height)
        }
    }

    func testMinimumSizeFrameDoesNotMoveWhenShrinkingPastItsAnchors() {
        let frame = CGRect(origin: CGPoint(x: -1800, y: -900), size: PinnedImageLayout.minimumSize)
        let cases: [(SelectionHandle, CGSize)] = [
            (.topLeft, CGSize(width: 10_000, height: -10_000)),
            (.top, CGSize(width: 0, height: -10_000)),
            (.topRight, CGSize(width: -10_000, height: -10_000)),
            (.right, CGSize(width: -10_000, height: 0)),
            (.bottomRight, CGSize(width: -10_000, height: 10_000)),
            (.bottom, CGSize(width: 0, height: 10_000)),
            (.bottomLeft, CGSize(width: 10_000, height: 10_000)),
            (.left, CGSize(width: 10_000, height: 0)),
        ]

        for (handle, delta) in cases {
            XCTAssertEqual(PinnedImageLayout.resizedFrame(frame, handle: handle, delta: delta), frame, "Handle: \(handle)")
        }
    }

    func testResizeCanExceedTheInitialDisplaySizeWithoutPreservingAspectRatio() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 200)
        XCTAssertEqual(
            PinnedImageLayout.resizedFrame(frame, handle: .topRight, delta: CGSize(width: 900, height: 10)),
            CGRect(x: 100, y: 200, width: 1200, height: 210)
        )
    }

    func testOppositeEdgesRemainAnchoredForExpansionAndClampedShrinking() {
        let initialFrame = CGRect(x: -900, y: -250, width: 300, height: 200)
        let deltas = [CGSize(width: 90, height: 70), CGSize(width: -90, height: -70), CGSize(width: 10_000, height: -10_000)]

        for handle in SelectionHandle.allCases {
            for delta in deltas {
                let result = PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: delta)
                switch handle {
                case .topLeft, .left, .bottomLeft:
                    XCTAssertEqual(result.maxX, initialFrame.maxX)
                case .topRight, .right, .bottomRight:
                    XCTAssertEqual(result.minX, initialFrame.minX)
                case .top, .bottom:
                    XCTAssertEqual(result.minX, initialFrame.minX)
                    XCTAssertEqual(result.maxX, initialFrame.maxX)
                }
                switch handle {
                case .topLeft, .top, .topRight:
                    XCTAssertEqual(result.minY, initialFrame.minY)
                case .bottomLeft, .bottom, .bottomRight:
                    XCTAssertEqual(result.maxY, initialFrame.maxY)
                case .left, .right:
                    XCTAssertEqual(result.minY, initialFrame.minY)
                    XCTAssertEqual(result.maxY, initialFrame.maxY)
                }
            }
        }
    }

    func testRepeatedDragUpdatesUseTheOriginalFrameAndTotalDelta() {
        let initialFrame = CGRect(x: 100, y: 200, width: 300, height: 200)
        let firstDelta = CGSize(width: 40, height: 30)

        for handle in SelectionHandle.allCases {
            let first = PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: firstDelta)
            _ = PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: CGSize(width: 10_000, height: -10_000))
            XCTAssertEqual(PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: firstDelta), first)
            XCTAssertEqual(PinnedImageLayout.resizedFrame(initialFrame, handle: handle, delta: .zero), initialFrame)
        }
        XCTAssertEqual(
            PinnedImageLayout.resizedFrame(initialFrame, handle: .bottomLeft, delta: CGSize(width: 60, height: 50)),
            CGRect(x: 160, y: 250, width: 240, height: 150)
        )
    }

    func testResizeAndHitTestingTranslateAcrossNegativeAndMultipleDisplayCoordinates() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 200)
        let delta = CGSize(width: -70, height: 90)
        let offsets = [CGPoint(x: -1920, y: -1080), CGPoint(x: 2560, y: 1440), CGPoint(x: -3840, y: 2160)]

        for offset in offsets {
            let translatedFrame = frame.offsetBy(dx: offset.x, dy: offset.y)
            for handle in SelectionHandle.allCases {
                let resized = PinnedImageLayout.resizedFrame(frame, handle: handle, delta: delta)
                XCTAssertEqual(
                    PinnedImageLayout.resizedFrame(translatedFrame, handle: handle, delta: delta),
                    resized.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
            for (handle, region) in PinnedImageLayout.resizeRegions(in: translatedFrame) {
                XCTAssertEqual(
                    PinnedImageLayout.resizeHandle(at: CGPoint(x: region.midX, y: region.midY), in: translatedFrame),
                    handle
                )
            }
        }
    }

    func testToolbarIsFixedSizeAndTwelvePointsFromTheTopRight() {
        let frames = [
            CGRect(x: 0, y: 0, width: 360, height: 240),
            CGRect(x: -1900, y: -900, width: 300, height: 200),
            CGRect(x: 2700, y: 1500, width: 500, height: 700),
        ]
        XCTAssertEqual(PinnedImageLayout.toolbarSize, CGSize(width: 156, height: 32))
        XCTAssertEqual(PinnedImageLayout.toolbarInset, 12)

        for frame in frames {
            let toolbar = PinnedImageLayout.toolbarFrame(for: frame)
            XCTAssertEqual(toolbar.size, CGSize(width: 156, height: 32))
            XCTAssertEqual(frame.maxX - toolbar.maxX, 12)
            XCTAssertEqual(frame.maxY - toolbar.maxY, 12)
            XCTAssertTrue(frame.contains(toolbar))
        }
    }

    func testToolbarFitsInsideMinimumImageAndLeavesResizeBorderClear() {
        let frame = CGRect(origin: CGPoint(x: -180, y: -100), size: PinnedImageLayout.minimumSize)
        let toolbar = PinnedImageLayout.toolbarFrame(for: frame)

        XCTAssertEqual(toolbar, CGRect(x: -168, y: -44, width: 156, height: 32))
        XCTAssertTrue(frame.contains(toolbar))
        for (_, region) in PinnedImageLayout.resizeRegions(in: frame) {
            XCTAssertTrue(toolbar.intersection(region).isEmpty)
        }
    }
}
