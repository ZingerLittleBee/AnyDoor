import Foundation

/// Pure vertical-stitch logic for scrolling capture. Operates on per-row
/// fingerprints (`RowSig`) rather than pixels so the alignment math is fully
/// unit-testable without real images. The engine turns each captured frame into
/// `[RowSig]`, asks `detectOverlap` how far the content scrolled, then composites
/// the newly revealed rows. No AppKit, no I/O.
enum ScrollStitch {
    /// A compact fingerprint of one pixel row. Exact integer scrolling preserves
    /// a row's pixels, so identical rows produce identical signatures.
    typealias RowSig = UInt64

    struct OverlapResult: Equatable {
        /// Rows of new content revealed at the bottom of `cur` (how far the
        /// content shifted up). `0` ⇒ the frame didn't move ⇒ bottom reached.
        let delta: Int
        let matchRatio: Double
        /// Overlapping rows shared with `prev` (`H - delta`).
        let overlap: Int
    }

    /// How far `cur` scrolled past `prev`. Both are top-to-bottom row
    /// fingerprints of equal length `H`. Tries every shift `d` in
    /// `0 ... (H - minOverlap)`, aligning `cur[0 ..< H-d]` with `prev[d ..< H]`,
    /// and keeps the best by `(ratio desc, |d - expected| asc, d desc)`. Returns
    /// `nil` when no alignment meets `minMatchRatio`, when the lengths differ, or
    /// when `prev` is a single uniform band (no reliable anchor).
    static func detectOverlap(prev: [RowSig], cur: [RowSig],
                              minOverlap: Int, minMatchRatio: Double,
                              expected: Int?) -> OverlapResult? {
        let h = prev.count
        guard h > 0, cur.count == h, minOverlap >= 1, minOverlap <= h else { return nil }
        // A fully uniform previous frame can align at any offset — refuse to guess.
        if prev.allSatisfy({ $0 == prev[0] }) { return nil }

        var best: (delta: Int, ratio: Double)?
        let maxDelta = h - minOverlap
        for d in 0...maxDelta {
            let overlap = h - d
            var matches = 0
            var i = 0
            while i < overlap {
                if cur[i] == prev[d + i] { matches += 1 }
                i += 1
            }
            let ratio = Double(matches) / Double(overlap)
            guard ratio >= minMatchRatio else { continue }
            if let b = best {
                if Self.isBetter(candidate: (d, ratio), than: b, expected: expected) {
                    best = (d, ratio)
                }
            } else {
                best = (d, ratio)
            }
        }
        guard let b = best else { return nil }
        return OverlapResult(delta: b.delta, matchRatio: b.ratio, overlap: h - b.delta)
    }

    private static func isBetter(candidate c: (delta: Int, ratio: Double),
                                 than b: (delta: Int, ratio: Double),
                                 expected: Int?) -> Bool {
        if abs(c.ratio - b.ratio) > 1e-9 { return c.ratio > b.ratio }
        if let e = expected {
            let dc = abs(c.delta - e), db = abs(b.delta - e)
            if dc != db { return dc < db }
        }
        return c.delta > b.delta
    }
}

/// Tunable constants and the (pure) stop decision for the scroll loop.
struct ScrollCapturePolicy {
    /// Wheel "lines" posted per scroll step. Small enough that consecutive frames
    /// always overlap comfortably.
    var scrollLines: Int = 6
    /// Delay after a scroll before grabbing, so the content has rendered.
    var settleMillis: Int = 320
    /// Hard cap on captured frames (runaway guard).
    var maxFrames: Int = 60
    /// Stitched height is capped at `viewportHeight * maxTotalHeightFactor`.
    var maxTotalHeightFactor: Int = 40
    /// Minimum required overlap, as a fraction of the viewport height.
    var minOverlapRatio: Double = 0.25
    /// Minimum fraction of overlapping rows that must match to accept an alignment.
    var minMatchRatio: Double = 0.9
    /// Consecutive no-progress frames (delta 0 / unmatched) before stopping.
    var stableStopCount: Int = 2

    /// Required overlap in rows for a viewport of `viewportHeight` pixels.
    func minOverlapRows(viewportHeight: Int) -> Int {
        max(1, Int((Double(viewportHeight) * minOverlapRatio).rounded()))
    }

    /// Whether the loop should stop before capturing another frame.
    func shouldStop(frameIndex: Int, delta: Int, totalHeight: Int,
                    viewportHeight: Int, noProgressStreak: Int) -> Bool {
        if frameIndex >= maxFrames { return true }
        if totalHeight >= viewportHeight * maxTotalHeightFactor { return true }
        if noProgressStreak >= stableStopCount { return true }
        return false
    }
}
