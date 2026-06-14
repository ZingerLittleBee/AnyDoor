import XCTest
@testable import AnyDoor

final class ScrollStitcherTests: XCTestCase {
    typealias Sig = ScrollStitch.RowSig

    // A distinctive (non-uniform) row sequence so alignment is unambiguous.
    private func distinct(_ n: Int, from start: Sig = 1) -> [Sig] {
        (0..<n).map { Sig($0) &+ start }
    }

    // MARK: - detectOverlap

    func testExactScrollDetectsDelta() {
        // prev = rows 1...100; cur scrolled up by 10 = rows 11...110.
        let prev = distinct(100, from: 1)
        let cur = distinct(100, from: 11)
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 20, minMatchRatio: 0.9, expected: nil)
        XCTAssertEqual(r?.delta, 10)
        XCTAssertEqual(r?.overlap, 90)
        XCTAssertEqual(r?.matchRatio ?? 0, 1.0, accuracy: 0.0001)
    }

    func testNoScrollGivesZeroDelta() {
        let prev = distinct(50)
        let cur = distinct(50)
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 10, minMatchRatio: 0.9, expected: nil)
        XCTAssertEqual(r?.delta, 0) // identical frame ⇒ no new content ⇒ bottom reached
    }

    func testToleratesSmallMismatch() {
        // Scroll by 5, but corrupt 3 of the 95 overlapping rows (≈ 3%).
        let prev = distinct(100, from: 1)
        var cur = distinct(100, from: 6)
        cur[2] = 99999; cur[40] = 99998; cur[80] = 99997
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 20, minMatchRatio: 0.9, expected: nil)
        XCTAssertEqual(r?.delta, 5)
        XCTAssertGreaterThan(r?.matchRatio ?? 0, 0.9)
    }

    func testNoOverlapReturnsNil() {
        let prev = distinct(60, from: 1)
        let cur = distinct(60, from: 10_000) // entirely different content
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 20, minMatchRatio: 0.9, expected: nil)
        XCTAssertNil(r)
    }

    func testFullyUniformReturnsNil() {
        let prev = [Sig](repeating: 7, count: 50)
        let cur = [Sig](repeating: 7, count: 50)
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 10, minMatchRatio: 0.9, expected: 8)
        XCTAssertNil(r) // no reliable anchor in a uniform band
    }

    func testExpectedBreaksTieInUniformBand() {
        // Top half uniform, bottom half distinctive. Two shifts both match the
        // uniform part, but only one matches the distinctive part — that one wins
        // regardless, and `expected` nudges among the genuinely ambiguous ties.
        var prev = [Sig](repeating: 7, count: 40)
        var cur = [Sig](repeating: 7, count: 40)
        for i in 20..<40 { prev[i] = Sig(1000 + i) }      // distinctive band in prev
        for i in 12..<32 { cur[i] = Sig(1000 + (i + 8)) } // same band shifted up by 8
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 10, minMatchRatio: 0.9, expected: 8)
        XCTAssertEqual(r?.delta, 8)
    }

    func testMinOverlapEnforced() {
        // A 30-row frame scrolled by 25 leaves only 5 overlapping rows; with
        // minOverlap 10 that alignment is rejected ⇒ nil.
        let prev = distinct(30, from: 1)
        let cur = distinct(30, from: 26)
        let r = ScrollStitch.detectOverlap(prev: prev, cur: cur,
                                           minOverlap: 10, minMatchRatio: 0.9, expected: nil)
        XCTAssertNil(r)
    }

    func testLengthMismatchReturnsNil() {
        let r = ScrollStitch.detectOverlap(prev: distinct(40), cur: distinct(50),
                                           minOverlap: 10, minMatchRatio: 0.9, expected: nil)
        XCTAssertNil(r)
    }

    // MARK: - ScrollCapturePolicy.shouldStop

    func testStopsOnNoProgressStreak() {
        let p = ScrollCapturePolicy()
        // streak reaching stableStopCount stops.
        XCTAssertTrue(p.shouldStop(frameIndex: 5, delta: 0, totalHeight: 2000,
                                   viewportHeight: 800, noProgressStreak: p.stableStopCount))
        XCTAssertFalse(p.shouldStop(frameIndex: 5, delta: 0, totalHeight: 2000,
                                    viewportHeight: 800, noProgressStreak: p.stableStopCount - 1))
    }

    func testStopsOnHeightCap() {
        let p = ScrollCapturePolicy()
        let cap = 800 * p.maxTotalHeightFactor
        XCTAssertTrue(p.shouldStop(frameIndex: 3, delta: 50, totalHeight: cap,
                                   viewportHeight: 800, noProgressStreak: 0))
        XCTAssertFalse(p.shouldStop(frameIndex: 3, delta: 50, totalHeight: cap - 1,
                                    viewportHeight: 800, noProgressStreak: 0))
    }

    func testStopsOnFrameCap() {
        let p = ScrollCapturePolicy()
        XCTAssertTrue(p.shouldStop(frameIndex: p.maxFrames, delta: 50, totalHeight: 1000,
                                   viewportHeight: 800, noProgressStreak: 0))
        XCTAssertFalse(p.shouldStop(frameIndex: p.maxFrames - 1, delta: 50, totalHeight: 1000,
                                    viewportHeight: 800, noProgressStreak: 0))
    }

    func testContinuesWhenMakingProgress() {
        let p = ScrollCapturePolicy()
        XCTAssertFalse(p.shouldStop(frameIndex: 2, delta: 40, totalHeight: 1200,
                                    viewportHeight: 800, noProgressStreak: 0))
    }

    func testMinOverlapRowsFromViewport() {
        let p = ScrollCapturePolicy()
        // viewport 800 rows, minOverlapRatio default ⇒ rounded row count.
        XCTAssertEqual(p.minOverlapRows(viewportHeight: 800),
                       Int((800.0 * p.minOverlapRatio).rounded()))
    }
}
