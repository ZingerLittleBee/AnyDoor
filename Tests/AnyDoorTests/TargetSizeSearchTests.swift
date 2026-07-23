import ImageCodec
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class TargetSizeSearchTests: XCTestCase {

    // MARK: - Helpers

    /// Records every request the search measures and answers from a model.
    private final class Recorder {
        private(set) var requests: [TargetSizeCandidateRequest] = []
        let model: (TargetSizeCandidateRequest) -> Int64

        init(_ model: @escaping (TargetSizeCandidateRequest) -> Int64) {
            self.model = model
        }

        func measure(_ request: TargetSizeCandidateRequest) -> Int64 {
            requests.append(request)
            return model(request)
        }
    }

    private func makeSearch(
        targetBytes: Int64,
        qualityFloor: Int = 40,
        original: PixelDimensions = PixelDimensions(width: 4000, height: 3000)
    ) -> TargetSizeSearch {
        TargetSizeSearch(
            targetBytes: targetBytes,
            qualityFloor: qualityFloor,
            originalDimensions: original
        )
    }

    // MARK: - Policy constants

    func test_policy_qualityFloors() {
        XCTAssertEqual(TargetSizePolicy.qualityFloor(for: .jpeg), 40)
        XCTAssertEqual(TargetSizePolicy.qualityFloor(for: .heic), 45)
        XCTAssertEqual(TargetSizePolicy.qualityFloor(for: .avif), 45)
        for format in [ImageConversionFormat.png, .tiff, .gif, .bmp, .pdf, .ico] {
            XCTAssertNil(TargetSizePolicy.qualityFloor(for: format), "\(format) must not offer Target Size")
        }
    }

    func test_policy_nextLongestEdge_clampsScaleAndPixelFloor() {
        // Ratio far below 0.25² → lower clamp 0.25 applies.
        XCTAssertEqual(
            TargetSizePolicy.nextLongestEdge(currentLongestEdge: 4000, candidateBytes: 1_000_000, targetBytes: 1_000),
            1000
        )
        // Ratio near 1 → upper clamp 0.90 applies.
        XCTAssertEqual(
            TargetSizePolicy.nextLongestEdge(currentLongestEdge: 4000, candidateBytes: 1_000_001, targetBytes: 1_000_000),
            3600
        )
        // Never below the Pixel Floor.
        XCTAssertEqual(
            TargetSizePolicy.nextLongestEdge(currentLongestEdge: 700, candidateBytes: 1_000_000, targetBytes: 1_000),
            640
        )
        // Exact math: sqrt(0.25) * 0.95 = 0.475 → floor(2000 * 0.475) = 950.
        XCTAssertEqual(
            TargetSizePolicy.nextLongestEdge(currentLongestEdge: 2000, candidateBytes: 4_000_000, targetBytes: 1_000_000),
            950
        )
    }

    func test_pixelDimensions_scaled_preservesAspectAndNeverUpscalesOrZeroes() {
        let landscape = PixelDimensions(width: 4000, height: 3000)
        XCTAssertEqual(landscape.scaled(toLongestEdge: 2000), PixelDimensions(width: 2000, height: 1500))

        let portrait = PixelDimensions(width: 3000, height: 4000)
        XCTAssertEqual(portrait.scaled(toLongestEdge: 2000), PixelDimensions(width: 1500, height: 2000))

        // Requesting a larger edge returns the original unchanged.
        XCTAssertEqual(landscape.scaled(toLongestEdge: 8000), landscape)

        // An extreme panorama never produces a zero short edge.
        let panorama = PixelDimensions(width: 10_000, height: 3)
        let scaled = panorama.scaled(toLongestEdge: 640)
        XCTAssertEqual(scaled.width, 640)
        XCTAssertGreaterThanOrEqual(scaled.height, 1)
    }

    // MARK: - Search: original dimensions

    func test_quality100Fits_returnsImmediately_singleAttempt() {
        let recorder = Recorder { _ in 500_000 }
        let result = makeSearch(targetBytes: 1_000_000).run(measure: recorder.measure)

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].quality, 100)
        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        XCTAssertEqual(candidate.request.quality, 100)
        XCTAssertEqual(candidate.byteCount, 500_000)
    }

    func test_binarySearch_findsHighestFittingQuality_withinPerSizeCap() {
        // Monotone model: bytes = quality * 10_000, target 550_000 → q55 is
        // the highest whole percent that fits.
        let recorder = Recorder { Int64($0.quality) * 10_000 }
        let result = makeSearch(targetBytes: 550_000).run(measure: recorder.measure)

        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        XCTAssertEqual(candidate.request.quality, 55)
        XCTAssertEqual(candidate.byteCount, 550_000)
        XCTAssertLessThanOrEqual(recorder.requests.count, TargetSizePolicy.maxQualityProbesPerSize)
        // Original dimensions only — no resize requests in quality search.
        XCTAssertTrue(recorder.requests.allSatisfy { $0.dimensions == PixelDimensions(width: 4000, height: 3000) })
    }

    func test_floorFits_resultIsHighestMeasuredQualifier() {
        // Whatever navigation does, the returned candidate must be the
        // highest-quality *measured* request that fit.
        let recorder = Recorder { Int64($0.quality) * 10_000 }
        let result = makeSearch(targetBytes: 730_000).run(measure: recorder.measure)

        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        let fittingProbes = recorder.requests.map(\.quality).filter { Int64($0) * 10_000 <= 730_000 }
        XCTAssertEqual(candidate.request.quality, fittingProbes.max())
    }

    func test_nonMonotonicModel_neverReturnsOversizedCandidate() {
        // A dip: q62 encodes *larger* than q70 — monotonicity is a hint, not
        // a contract. The selected candidate must still be a measured fit.
        let recorder = Recorder { request in
            switch request.quality {
            case 62: return 990_000
            case 70: return 940_000
            case 100: return 5_000_000
            default: return Int64(request.quality) * 10_000
            }
        }
        let result = makeSearch(targetBytes: 950_000).run(measure: recorder.measure)

        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        XCTAssertLessThanOrEqual(candidate.byteCount, 950_000)
        let bestMeasuredFit = recorder.requests
            .filter { recorder.model($0) <= 950_000 }
            .map(\.quality)
            .max()
        XCTAssertEqual(candidate.request.quality, bestMeasuredFit)
    }

    // MARK: - Search: best effort

    func test_originalAtPixelFloor_noResizeProbes_bestEffort() {
        // No smaller size may be produced for an image already at the Pixel
        // Floor: exactly the two original-dimension probes run.
        let original = PixelDimensions(width: 640, height: 480)
        let recorder = Recorder { _ in 99_000_000 }
        let result = makeSearch(targetBytes: 1_000, original: original).run(measure: recorder.measure)

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.dimensions == original })
        guard case .bestEffort = result else { return XCTFail("expected bestEffort") }
    }

    // MARK: - Search: Resize Fallback (always on)

    func test_floorOversized_firstFittingLevelGetsQualitySearch() {
        // Bytes scale with pixel area; the original floor misses the target
        // but the first resized level fits, so quality is maximized there.
        let original = PixelDimensions(width: 4000, height: 3000)
        let recorder = Recorder { request in
            let area = Double(request.dimensions.pixelCount)
            let qualityFactor = Double(request.quality) / 100.0
            return Int64(area * qualityFactor * 0.5)
        }
        // Original floor candidate measures 2.4 MB, so the target must sit
        // below it to force one resize level.
        let target: Int64 = 2_000_000
        let result = makeSearch(targetBytes: target, original: original)
            .run(measure: recorder.measure)

        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        XCTAssertLessThanOrEqual(candidate.byteCount, target)
        XCTAssertLessThan(candidate.request.dimensions.longestEdge, original.longestEdge)
        // The winning level's requests must all share one pixel size and the
        // result must be its highest measured fitting quality.
        let atWinningSize = recorder.requests.filter { $0.dimensions == candidate.request.dimensions }
        let bestFitAtSize = atWinningSize
            .filter { recorder.model($0) <= target }
            .map(\.quality)
            .max()
        XCTAssertEqual(candidate.request.quality, bestFitAtSize)
        XCTAssertLessThanOrEqual(atWinningSize.count, TargetSizePolicy.maxQualityProbesPerSize)
    }

    func test_levelEdgesFollowPolicyMath_andDeriveFromOriginal() {
        let original = PixelDimensions(width: 4000, height: 3000)
        let recorder = Recorder { _ in 99_000_000 }
        _ = makeSearch(targetBytes: 1_000, original: original)
            .run(measure: recorder.measure)

        // Replay the policy math over the recorded floor probes.
        var expectedEdge = original.longestEdge
        for request in recorder.requests.dropFirst(2) {
            expectedEdge = TargetSizePolicy.nextLongestEdge(
                currentLongestEdge: expectedEdge,
                candidateBytes: 99_000_000,
                targetBytes: 1_000
            )
            XCTAssertEqual(request.dimensions, original.scaled(toLongestEdge: expectedEdge))
            XCTAssertEqual(request.quality, 40)
        }
    }

    func test_unattainable_stopsAtPixelFloor_withinBudget() {
        let original = PixelDimensions(width: 8000, height: 6000)
        let recorder = Recorder { _ in 99_000_000 }
        let result = makeSearch(targetBytes: 1_000, original: original)
            .run(measure: recorder.measure)

        guard case .bestEffort = result else { return XCTFail("expected bestEffort") }
        XCTAssertLessThanOrEqual(recorder.requests.count, TargetSizePolicy.maxTotalAttempts - 1)
        // The lower clamp shrinks 0.25× per level, so the Pixel Floor is
        // reached and the loop must stop there rather than exploring further.
        let smallestRequested = recorder.requests.map(\.dimensions.longestEdge).min()
        XCTAssertEqual(smallestRequested, TargetSizePolicy.pixelFloorLongestEdge)
        let resizeProbes = recorder.requests.dropFirst(2)
        XCTAssertLessThanOrEqual(Set(resizeProbes.map(\.dimensions)).count, TargetSizePolicy.maxResizeLevels)
    }

    // MARK: - Budget and tie-breaks

    func test_attemptBudget_neverExceeded_acrossScenarios() {
        for target: Int64 in [1_000, 550_000, 10_000_000] {
            let recorder = Recorder { request in
                Int64(Double(request.dimensions.pixelCount) * Double(request.quality) / 100.0)
            }
            _ = makeSearch(targetBytes: target).run(measure: recorder.measure)
            XCTAssertLessThanOrEqual(recorder.requests.count, TargetSizePolicy.maxTotalAttempts - 1)
        }
    }

    func test_budgetExhaustedAfterFloorFit_stillReached() {
        var search = makeSearch(targetBytes: 550_000)
        search.attemptBudget = 2
        let recorder = Recorder { Int64($0.quality) * 10_000 }
        let result = search.run(measure: recorder.measure)

        XCTAssertEqual(recorder.requests.count, 2)
        // A qualifier exists, so an exhausted budget is still target success.
        guard case .reached(let candidate) = result else { return XCTFail("expected reached") }
        XCTAssertEqual(candidate.request.quality, 40)
    }

    func test_equalByteCounts_bestEffortPrefersMorePixels_thenHigherQuality() {
        // Every candidate measures identically: the retained smallest must be
        // the very first probe (original dimensions, quality 100), which has
        // the most pixels and the highest quality.
        let original = PixelDimensions(width: 4000, height: 3000)
        let recorder = Recorder { _ in 42_000_000 }
        let result = makeSearch(targetBytes: 1_000, original: original)
            .run(measure: recorder.measure)

        guard case .bestEffort(let candidate) = result else { return XCTFail("expected bestEffort") }
        XCTAssertEqual(candidate.request.dimensions, original)
        XCTAssertEqual(candidate.request.quality, 100)
    }
}
