import Foundation

/// The bounded Target Size search for formats without an encoder quality knob
/// (PNG): the only lever is pixel dimensions, so the search maximizes the
/// longest edge whose losslessly encoded bytes stay within the target.
///
/// Resizing is inherent to this strategy — it runs regardless of the Resize
/// Fallback preference, which only gates the *optional* fallback of the
/// quality-search formats. Pure policy like `TargetSizeSearch`: encoded-size
/// monotonicity in pixel count is a navigation hint, never a retention rule.
struct TargetSizeResizeSearch {
    var targetBytes: Int64
    var originalDimensions: PixelDimensions
    /// Total measure budget: 1 original probe + 1 floor probe + the bisection.
    var attemptBudget: Int = TargetSizePolicy.maxResizeOnlyAttempts

    func run(
        measure: (TargetSizeCandidateRequest) throws -> Int64
    ) rethrows -> TargetSizeSearchResult {
        precondition(targetBytes > 0)
        precondition(attemptBudget >= 1)

        var attemptsUsed = 0
        var smallest: TargetSizeCandidate?

        func fits(_ candidate: TargetSizeCandidate) -> Bool {
            candidate.byteCount <= targetBytes
        }

        // Equal byte counts prefer more pixels.
        func recordSmallest(_ candidate: TargetSizeCandidate) {
            guard let current = smallest else {
                smallest = candidate
                return
            }
            if candidate.byteCount < current.byteCount
                || (candidate.byteCount == current.byteCount
                    && candidate.request.dimensions.pixelCount > current.request.dimensions.pixelCount) {
                smallest = candidate
            }
        }

        func probe(longestEdge: Int) throws -> TargetSizeCandidate {
            attemptsUsed += 1
            let request = TargetSizeCandidateRequest(
                quality: TargetSizePolicy.losslessQuality,
                dimensions: originalDimensions.scaled(toLongestEdge: longestEdge)
            )
            let candidate = TargetSizeCandidate(request: request, byteCount: try measure(request))
            recordSmallest(candidate)
            return candidate
        }

        // 1. Original dimensions: return if the re-encode already fits.
        let top = try probe(longestEdge: originalDimensions.longestEdge)
        if fits(top) { return .reached(top) }

        // 2. At or below the Pixel Floor nothing smaller may be produced.
        let floorEdge = TargetSizePolicy.pixelFloorLongestEdge
        guard originalDimensions.longestEdge > floorEdge, attemptsUsed < attemptBudget else {
            return .bestEffort(smallest!, reason: .pixelFloorReached)
        }

        // 3. The Pixel Floor bounds what resizing can reach.
        let floorCandidate = try probe(longestEdge: floorEdge)
        guard fits(floorCandidate) else {
            return .bestEffort(smallest!, reason: .pixelFloorReached)
        }

        // 4. Bisect the longest edge, maximizing measured fitting pixels.
        var bestQualifier = floorCandidate
        var lo = floorEdge
        var hi = originalDimensions.longestEdge
        while hi - lo > 1, attemptsUsed < attemptBudget {
            let mid = (lo + hi) / 2
            let candidate = try probe(longestEdge: mid)
            if fits(candidate) {
                lo = mid
                if candidate.request.dimensions.pixelCount
                    > bestQualifier.request.dimensions.pixelCount {
                    bestQualifier = candidate
                }
            } else {
                hi = mid
            }
        }
        return .reached(bestQualifier)
    }
}
