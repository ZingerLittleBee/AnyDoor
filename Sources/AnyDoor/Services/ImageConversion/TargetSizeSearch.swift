import Foundation

/// Integer pixel dimensions of a decoded image or a resize candidate.
struct PixelDimensions: Hashable, Sendable {
    var width: Int
    var height: Int

    var longestEdge: Int { max(width, height) }
    var pixelCount: Int { width * height }

    /// Proportionally reduced dimensions with the given longest edge. Never
    /// upscales, always derives from `self` (the engine resamples from the
    /// original decoded image, not from a previous resized candidate), and
    /// clamps the short edge to at least 1 px.
    func scaled(toLongestEdge target: Int) -> PixelDimensions {
        guard target < longestEdge else { return self }
        let ratio = Double(target) / Double(longestEdge)
        if width >= height {
            return PixelDimensions(width: target, height: max(1, Int((Double(height) * ratio).rounded())))
        } else {
            return PixelDimensions(width: max(1, Int((Double(width) * ratio).rounded())), height: target)
        }
    }
}

/// One encode attempt the search asks the engine to measure: encode the
/// original image at these dimensions and this whole-percent quality, and
/// report the final candidate byte count (metadata policy included).
struct TargetSizeCandidateRequest: Hashable, Sendable {
    var quality: Int
    var dimensions: PixelDimensions
}

/// A measured candidate: the request plus its final byte count.
struct TargetSizeCandidate: Hashable, Sendable {
    var request: TargetSizeCandidateRequest
    var byteCount: Int64
}

/// Why a Best-Effort search stopped, so the inspector can offer the inline
/// Resize Fallback control only when enabling it could still help.
enum TargetSizeStopReason: Hashable, Sendable {
    /// Quality search hit the Quality Floor with resizing off, and enabling
    /// the Resize Fallback could still help (the image sits above the Pixel
    /// Floor).
    case qualityFloorReached
    /// Resizing cannot help further: it was exhausted (Pixel Floor, level
    /// cap, or attempt budget), or the image is already at or below the
    /// Pixel Floor.
    case pixelFloorReached
}

enum TargetSizeSearchResult: Hashable, Sendable {
    /// The highest-quality measured candidate within the Per-Output Limit at
    /// the pixel size selected by the documented ordering.
    case reached(TargetSizeCandidate)
    /// Nothing fit: the smallest measured candidate overall.
    case bestEffort(TargetSizeCandidate, reason: TargetSizeStopReason)
}

/// The bounded Target Size search over an injectable measurement step.
///
/// Pure policy: it decides which (quality, dimensions) candidates to measure
/// and which measured candidate wins, but performs no Image I/O itself. Image
/// I/O size monotonicity is treated as a hint — retention only ever compares
/// measured byte counts, so a non-monotonic encoder can mislead navigation but
/// never the selected result.
struct TargetSizeSearch {
    var targetBytes: Int64
    var qualityFloor: Int
    var originalDimensions: PixelDimensions
    var allowResize: Bool
    /// Total measure budget for this search. 16 is the structural maximum
    /// (2 original probes + 5 failed floor probes + 9 at the fitting level);
    /// the seventeenth policy attempt is the engine's pass-through.
    var attemptBudget: Int = TargetSizePolicy.maxTotalAttempts - 1

    func run(
        measure: (TargetSizeCandidateRequest) throws -> Int64
    ) rethrows -> TargetSizeSearchResult {
        precondition(targetBytes > 0)
        precondition(qualityFloor >= 1 && qualityFloor < 100)
        precondition(attemptBudget >= 1)

        var attemptsUsed = 0
        var smallest: TargetSizeCandidate?

        func fits(_ candidate: TargetSizeCandidate) -> Bool {
            candidate.byteCount <= targetBytes
        }

        // Equal byte counts prefer more pixels, then higher quality.
        func recordSmallest(_ candidate: TargetSizeCandidate) {
            guard let current = smallest else {
                smallest = candidate
                return
            }
            if candidate.byteCount < current.byteCount {
                smallest = candidate
            } else if candidate.byteCount == current.byteCount {
                let candidatePixels = candidate.request.dimensions.pixelCount
                let currentPixels = current.request.dimensions.pixelCount
                if candidatePixels > currentPixels
                    || (candidatePixels == currentPixels
                        && candidate.request.quality > current.request.quality) {
                    smallest = candidate
                }
            }
        }

        func probe(quality: Int, dimensions: PixelDimensions) throws -> TargetSizeCandidate {
            attemptsUsed += 1
            let request = TargetSizeCandidateRequest(quality: quality, dimensions: dimensions)
            let candidate = TargetSizeCandidate(request: request, byteCount: try measure(request))
            recordSmallest(candidate)
            return candidate
        }

        func budgetRemaining() -> Bool { attemptsUsed < attemptBudget }

        func bestEffort() -> TargetSizeSearchResult {
            // At least one probe always precedes this point. Report
            // `qualityFloorReached` (which the inspector maps to the inline
            // enable-resize hint) only when turning resize on could actually
            // change the outcome: an image already at or below the Pixel
            // Floor would miss identically.
            let resizeCouldHelp = !allowResize
                && originalDimensions.longestEdge > TargetSizePolicy.pixelFloorLongestEdge
            return .bestEffort(
                smallest!,
                reason: resizeCouldHelp ? .qualityFloorReached : .pixelFloorReached
            )
        }

        // Bounded whole-percent search maximizing measured quality at one
        // pixel size. `lowerFits` is a known qualifier at this size; the
        // upper boundary (quality 100) may or may not have been probed yet.
        func qualitySearch(
            at dimensions: PixelDimensions,
            lowerFits: TargetSizeCandidate,
            upperBoundProbed: Bool,
            probesUsedAtSize: Int
        ) throws -> TargetSizeCandidate {
            var bestQualifier = lowerFits
            var lo = lowerFits.request.quality
            var hi = 100
            var probesAtSize = probesUsedAtSize

            if !upperBoundProbed {
                guard probesAtSize < TargetSizePolicy.maxQualityProbesPerSize, budgetRemaining() else {
                    return bestQualifier
                }
                let top = try probe(quality: 100, dimensions: dimensions)
                probesAtSize += 1
                if fits(top) { return top }
            }

            while hi - lo > 1,
                  probesAtSize < TargetSizePolicy.maxQualityProbesPerSize,
                  budgetRemaining() {
                let mid = (lo + hi) / 2
                let candidate = try probe(quality: mid, dimensions: dimensions)
                probesAtSize += 1
                if fits(candidate) {
                    lo = mid
                    if candidate.request.quality > bestQualifier.request.quality {
                        bestQualifier = candidate
                    }
                } else {
                    hi = mid
                }
            }
            return bestQualifier
        }

        // 1. Quality 100 at original dimensions: return if it already fits.
        let top = try probe(quality: 100, dimensions: originalDimensions)
        if fits(top) { return .reached(top) }
        guard budgetRemaining() else { return bestEffort() }

        // 2. The Quality Floor at original dimensions.
        let floorCandidate = try probe(quality: qualityFloor, dimensions: originalDimensions)
        if fits(floorCandidate) {
            // 3. Original dimensions can fit: maximize quality here and never
            // consider smaller sizes.
            return .reached(try qualitySearch(
                at: originalDimensions,
                lowerFits: floorCandidate,
                upperBoundProbed: true,
                probesUsedAtSize: 2
            ))
        }

        // 4. The floor is oversized at original dimensions.
        guard allowResize,
              originalDimensions.longestEdge > TargetSizePolicy.pixelFloorLongestEdge else {
            return bestEffort()
        }

        // 5. Resize Fallback: shrink toward the Pixel Floor, probing only the
        // Quality Floor per level; the first fitting level gets the bounded
        // quality search and no smaller level is explored afterward.
        var level = 0
        var currentEdge = originalDimensions.longestEdge
        var lastFloorBytes = floorCandidate.byteCount
        while level < TargetSizePolicy.maxResizeLevels, budgetRemaining() {
            let nextEdge = TargetSizePolicy.nextLongestEdge(
                currentLongestEdge: currentEdge,
                candidateBytes: lastFloorBytes,
                targetBytes: targetBytes
            )
            guard nextEdge < currentEdge else { break }
            let dimensions = originalDimensions.scaled(toLongestEdge: nextEdge)
            level += 1
            currentEdge = nextEdge

            let levelFloor = try probe(quality: qualityFloor, dimensions: dimensions)
            if fits(levelFloor) {
                return .reached(try qualitySearch(
                    at: dimensions,
                    lowerFits: levelFloor,
                    upperBoundProbed: false,
                    probesUsedAtSize: 1
                ))
            }
            lastFloorBytes = levelFloor.byteCount
            if nextEdge <= TargetSizePolicy.pixelFloorLongestEdge { break }
        }
        return bestEffort()
    }
}
