import XCTest
@testable import AnyDoor

final class TargetSizeResizeSearchTests: XCTestCase {
    private let original = PixelDimensions(width: 1_600, height: 1_200)

    /// Byte model proportional to pixel area, so fits are monotonic in edge.
    private func areaBytes(scale bytesPerPixel: Double) -> (TargetSizeCandidateRequest) -> Int64 {
        { request in
            Int64((Double(request.dimensions.pixelCount) * bytesPerPixel).rounded())
        }
    }

    func test_originalFits_returnsImmediately() throws {
        var probes = 0
        let search = TargetSizeResizeSearch(targetBytes: 10_000_000, originalDimensions: original)
        let result = try search.run { request in
            probes += 1
            return self.areaBytes(scale: 1.0)(request)
        }
        guard case .reached(let candidate) = result else {
            return XCTFail("expected reached")
        }
        XCTAssertEqual(candidate.request.dimensions, original)
        XCTAssertEqual(probes, 1, "a fitting original needs no further probes")
    }

    func test_floorUnfit_missesWithTheFloorProbe() throws {
        // Even the 640px floor is oversized.
        let search = TargetSizeResizeSearch(targetBytes: 1_000, originalDimensions: original)
        let result = try search.run(measure: areaBytes(scale: 1.0))
        guard case .bestEffort(let smallest) = result else {
            return XCTFail("expected bestEffort")
        }
        XCTAssertEqual(
            smallest.request.dimensions.longestEdge,
            TargetSizePolicy.pixelFloorLongestEdge,
            "the smallest candidate is the floor probe"
        )
    }

    func test_originalAtOrBelowFloor_missesWithoutResizeProbes() throws {
        var probes = 0
        let small = PixelDimensions(width: 320, height: 240)
        let search = TargetSizeResizeSearch(targetBytes: 1_000, originalDimensions: small)
        let result = try search.run { request in
            probes += 1
            return self.areaBytes(scale: 1.0)(request)
        }
        guard case .bestEffort = result else {
            return XCTFail("expected bestEffort")
        }
        XCTAssertEqual(probes, 1, "below the floor only the original may be probed")
    }

    func test_bisection_maximizesFittingEdgeWithinBudget() throws {
        // 1 byte per pixel, target 600_000: fitting edges satisfy
        // edge * (edge * 0.75) <= 600_000 → edge <= 894.
        let search = TargetSizeResizeSearch(targetBytes: 600_000, originalDimensions: original)
        let result = try search.run(measure: areaBytes(scale: 1.0))
        guard case .reached(let candidate) = result else {
            return XCTFail("expected reached")
        }
        XCTAssertLessThanOrEqual(candidate.byteCount, 600_000)
        XCTAssertGreaterThanOrEqual(candidate.request.dimensions.longestEdge, 640)
        XCTAssertGreaterThan(
            candidate.request.dimensions.longestEdge, 800,
            "the bisection must climb well above the floor toward the true boundary"
        )
        XCTAssertLessThanOrEqual(candidate.request.dimensions.longestEdge, 894)
    }

    func test_attemptBudget_isNeverExceeded() throws {
        var probes = 0
        let search = TargetSizeResizeSearch(targetBytes: 600_000, originalDimensions: original)
        _ = try search.run { request in
            probes += 1
            return self.areaBytes(scale: 1.0)(request)
        }
        XCTAssertLessThanOrEqual(probes, TargetSizePolicy.maxResizeOnlyAttempts)
    }

    func test_candidatesCarryTheLosslessQualityMarker() throws {
        let search = TargetSizeResizeSearch(targetBytes: 600_000, originalDimensions: original)
        let result = try search.run(measure: areaBytes(scale: 1.0))
        guard case .reached(let candidate) = result else {
            return XCTFail("expected reached")
        }
        XCTAssertEqual(candidate.request.quality, TargetSizePolicy.losslessQuality)
    }
}
