import Foundation

/// Versioned compression policy for Target Size mode (V1).
///
/// These constants are part of the configuration fingerprint: lowering a
/// Quality Floor or changing candidate ordering requires a documented visual
/// review and a `version` bump so cached candidates cannot be reused across
/// policy changes.
enum TargetSizePolicy {
    /// V2: same-format in/out with per-format strategies (quality search for
    /// lossy formats, resize-only search for PNG).
    static let version = 2

    /// Lowest encoder quality (whole percent) the bounded search may request
    /// at one pixel size. `nil` for formats whose strategy has no quality knob.
    static func qualityFloor(for format: ImageConversionFormat) -> Int? {
        switch format {
        case .jpeg, .webp: return 40
        case .heic, .avif: return 45
        case .png, .tiff, .gif, .bmp, .pdf, .ico: return nil
        }
    }

    /// Nominal quality recorded for candidates of lossless per-level encodes
    /// (the PNG resize-only strategy); the encoder ignores it.
    static let losslessQuality = 100

    /// Total measure budget for one resize-only search: an original probe, a
    /// floor probe, and up to six bisection steps.
    static let maxResizeOnlyAttempts = 8

    /// Minimum longest-edge dimension Resize Fallback may produce.
    static let pixelFloorLongestEdge = 640

    /// At most this many encode probes at one searched pixel size,
    /// including that size's floor/boundary probes.
    static let maxQualityProbesPerSize = 9

    /// At most this many reduced pixel sizes below the original.
    static let maxResizeLevels = 6

    /// Total finalize/copy attempts for one item, including an optional
    /// same-format pass-through. The search itself never needs more than 16;
    /// the seventeenth is the pass-through attempt owned by the engine.
    static let maxTotalAttempts = 17

    /// Safety margin applied to the byte-ratio scale estimate so a level
    /// slightly overshoots downward instead of landing just above the target.
    static let resizeHeadroom = 0.95

    /// Per-step scale clamp: one resize level keeps between 25% and 90% of
    /// the current longest edge, so a step is never uselessly small and never
    /// overshoots to a tiny size in one jump.
    static let scaleClampRange = 0.25...0.90

    /// Debounce before generating an exact preview for the selected item.
    static let previewDebounce: TimeInterval = 0.3

    /// The next longest edge Resize Fallback should try, derived from how far
    /// the current floor candidate overshoots the target. Encoded bytes scale
    /// roughly with pixel area, hence the square root of the byte ratio.
    /// The result is clamped to the Pixel Floor.
    static func nextLongestEdge(
        currentLongestEdge: Int,
        candidateBytes: Int64,
        targetBytes: Int64
    ) -> Int {
        let raw = (Double(targetBytes) / Double(candidateBytes)).squareRoot() * resizeHeadroom
        let scale = min(max(raw, scaleClampRange.lowerBound), scaleClampRange.upperBound)
        let scaled = Int((Double(currentLongestEdge) * scale).rounded(.down))
        return max(pixelFloorLongestEdge, scaled)
    }
}
