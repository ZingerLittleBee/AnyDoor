import CoreGraphics

/// Running scrolling-capture stitch state, factored out of the old auto-loop so it
/// is unit-testable. The first frame seeds the stitch; later frames are aligned
/// against the previous one via `ScrollStitch.detectOverlap` in both directions —
/// scrolling down appends the newly revealed bottom rows, scrolling up prepends the
/// new top rows — so the page stitches top-to-bottom whichever way the user scrolls.
/// Pixel space (top-left rows), display scale agnostic.
@MainActor
final class ScrollStitchAccumulator {
    private let policy: ScrollCapturePolicy
    private var slices: [(image: CGImage, height: Int)] = []
    private var prevSig: [ScrollStitch.RowSig] = []
    private var viewportPx = 0
    private var minOverlap = 0
    private var lastDelta: Int?

    init(policy: ScrollCapturePolicy = ScrollCapturePolicy()) { self.policy = policy }

    var sliceCount: Int { slices.count }
    var totalHeight: Int { slices.reduce(0) { $0 + $1.height } }

    /// Ingest a freshly grabbed viewport frame. Returns true when rows were appended.
    @discardableResult
    func ingest(_ frame: CGImage) -> Bool {
        guard let sig = ScrollCaptureEngine.rowSignatures(of: frame) else { return false }
        if slices.isEmpty {
            slices = [(frame, frame.height)]
            prevSig = sig
            viewportPx = frame.height
            minOverlap = min(policy.minOverlapRows(viewportHeight: viewportPx), viewportPx)
            return true
        }
        // The viewport is fixed but the user may scroll either way, so detect both
        // directions. `detectOverlap(prev:cur:)` reports how far `cur` scrolled *up*
        // relative to `prev` (new content at the bottom); swapping the arguments
        // reports the *downward* scroll (new content at the top). Append for the
        // former, prepend for the latter, so the page stays top-to-bottom.
        let down = ScrollStitch.detectOverlap(prev: prevSig, cur: sig,
                                              minOverlap: minOverlap,
                                              minMatchRatio: policy.minMatchRatio,
                                              expected: lastDelta)
        let up = ScrollStitch.detectOverlap(prev: sig, cur: prevSig,
                                            minOverlap: minOverlap,
                                            minMatchRatio: policy.minMatchRatio,
                                            expected: lastDelta)
        let downHit = (down?.delta ?? 0) > 0 ? down : nil
        let upHit = (up?.delta ?? 0) > 0 ? up : nil

        // Prefer the stronger match; a tie keeps the (more common) downward case.
        let appendBottom: Bool
        switch (downHit, upHit) {
        case let (.some(d), .some(u)): appendBottom = d.matchRatio >= u.matchRatio
        case (.some, .none): appendBottom = true
        case (.none, .some): appendBottom = false
        case (.none, .none): return false
        }

        if appendBottom, let d = downHit {
            // New content revealed at the bottom of `frame` → append below.
            let rect = CGRect(x: 0, y: frame.height - d.delta, width: frame.width, height: d.delta)
            guard let slice = frame.cropping(to: rect) else { return false }
            slices.append((slice, d.delta))
            prevSig = sig
            lastDelta = d.delta
            return true
        }
        if let u = upHit {
            // New content revealed at the top of `frame` → prepend above.
            let rect = CGRect(x: 0, y: 0, width: frame.width, height: u.delta)
            guard let slice = frame.cropping(to: rect) else { return false }
            slices.insert((slice, u.delta), at: 0)
            prevSig = sig
            lastDelta = u.delta
            return true
        }
        return false
    }

    /// The stitched image so far (nil before the first frame).
    func composite() -> CGImage? { ScrollCaptureEngine.composite(slices: slices) }

    /// True once the stitch has hit the runaway memory guards (captured-frame
    /// count or total-height cap from `ScrollCapturePolicy`). The interactive
    /// session stops grabbing and delivers what it has, bounding the stitched
    /// CGImage / slice array that were otherwise unbounded. The policy's
    /// no-progress stop is intentionally NOT applied here: in interactive capture
    /// the user may pause scrolling without meaning to end the session.
    func hasReachedCaptureLimit() -> Bool {
        if sliceCount >= policy.maxFrames { return true }
        if viewportPx > 0, totalHeight >= viewportPx * policy.maxTotalHeightFactor { return true }
        return false
    }
}
