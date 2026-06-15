import CoreGraphics

/// Running scrolling-capture stitch state, factored out of the old auto-loop so it
/// is unit-testable. The first frame seeds the stitch; later frames are aligned
/// against the previous one via `ScrollStitch.detectOverlap`, appending only the
/// newly revealed bottom rows. Pixel space (top-left rows), display scale agnostic.
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
        guard let m = ScrollStitch.detectOverlap(prev: prevSig, cur: sig,
                                                 minOverlap: minOverlap,
                                                 minMatchRatio: policy.minMatchRatio,
                                                 expected: lastDelta),
              m.delta > 0 else { return false }
        let rect = CGRect(x: 0, y: frame.height - m.delta, width: frame.width, height: m.delta)
        guard let slice = frame.cropping(to: rect) else { return false }
        slices.append((slice, m.delta))
        prevSig = sig
        lastDelta = m.delta
        return true
    }

    /// The stitched image so far (nil before the first frame).
    func composite() -> CGImage? { ScrollCaptureEngine.composite(slices: slices) }
}
