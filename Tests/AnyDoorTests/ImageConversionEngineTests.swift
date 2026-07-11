import CoreGraphics
import ImageIO
import XCTest
@testable import AnyDoor

final class ImageConversionEngineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Fixtures

    private func makeGradientImage(width: Int = 320, height: Int = 240) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for x in 0..<width {
            for y in stride(from: 0, to: height, by: 3) {
                context.setFillColor(CGColor(
                    red: CGFloat((x &* 7) % 251) / 251.0,
                    green: CGFloat((x &* y) % 241) / 241.0,
                    blue: CGFloat((x &+ y &* 3) % 239) / 239.0,
                    alpha: 1.0
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 3))
            }
        }
        return context.makeImage()!
    }

    private func writeSourcePNG(
        name: String = "source.png",
        width: Int = 320,
        height: Int = 240
    ) throws -> URL {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, ImageConversionFormat.png.typeIdentifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, makeGradientImage(width: width, height: height), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = tempDirectory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    /// The quality-search-path fixture: same-format resolution keeps JPEG on
    /// the lossy strategy.
    private func writeSourceJPEG(
        name: String = "source.jpg",
        width: Int = 320,
        height: Int = 240,
        quality: Double = 0.9
    ) throws -> URL {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, ImageConversionFormat.jpeg.typeIdentifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, makeGradientImage(width: width, height: height), [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = tempDirectory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    private func makeItem(_ url: URL, base: String = "output") -> ImageConversionItemSnapshot {
        ImageConversionItemSnapshot(
            id: UUID(),
            input: .file(url),
            destination: AtomicOutputWriter.DestinationPolicy(
                directory: tempDirectory, baseName: base, fileExtension: "jpg"
            )
        )
    }

    private func request(
        targetBytes: Int64,
        allowResize: Bool = false
    ) -> TargetSizeRequest {
        TargetSizeRequest(
            targetBytes: targetBytes,
            allowResize: allowResize,
            transparencyBackgroundHex: "#FFFFFF"
        )
    }

    // MARK: - Success path

    func test_convertItem_reachableTarget_commitsWithinLimit() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())
        let config = request(targetBytes: 40_000)

        let outcome = await engine.convertItem(item, request: config)

        guard case .success(let conversion) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertLessThanOrEqual(conversion.output.byteCount, 40_000)
        XCTAssertEqual(conversion.output.url.lastPathComponent, "output.jpg")
        let onDisk = try Data(contentsOf: conversion.output.url)
        XCTAssertEqual(Int64(onDisk.count), conversion.output.byteCount)
        // The final file honors the metadata policy.
        XCTAssertTrue(CandidateAuditor.audit(onDisk).ancillaryMetadataAbsent)
        await engine.reset()
    }

    func test_previewThenRun_commitsTheExactPreviewArtifact() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())
        let config = request(targetBytes: 40_000)

        let preview = try await engine.prepareCandidate(
            item: item, request: config
        )
        // Matching fingerprints: the second preparation is a pure cache hit.
        let again = try await engine.prepareCandidate(
            item: item, request: config
        )
        XCTAssertEqual(preview, again)

        let outcome = await engine.convertItem(item, request: config)
        guard case .success(let conversion) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(conversion.candidate.artifact, preview.artifact,
                       "the run must commit the preview's artifact, not a re-encode")
        XCTAssertEqual(conversion.output.sha256, preview.artifact.sha256,
                       "committed bytes are byte-identical to the exact preview")
        await engine.reset()
    }

    func test_changedConfiguration_invalidatesCachedCandidate() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())

        let first = try await engine.prepareCandidate(
            item: item, request: request(targetBytes: 40_000)
        )
        let second = try await engine.prepareCandidate(
            item: item, request: request(targetBytes: 20_000)
        )
        XCTAssertNotEqual(first.artifact, second.artifact,
                          "a changed limit must produce a fresh candidate")
        await engine.reset()
    }

    func test_pruningPreviewInvalidatesItsCacheButKeepsTheSelectedArtifact() async throws {
        let engine = try ImageConversionEngine()
        let firstItem = makeItem(try writeSourceJPEG(name: "first.jpg"), base: "first-output")
        let secondItem = makeItem(try writeSourceJPEG(name: "second.jpg"), base: "second-output")
        let config = request(targetBytes: 40_000)
        let first = try await engine.prepareCandidate(
            item: firstItem,
            request: config
        )
        let second = try await engine.prepareCandidate(
            item: secondItem,
            request: config
        )

        await engine.pruneDisplayed(keepingItem: secondItem.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.artifact.artifactURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.artifact.artifactURL.path))
        let regenerated = try await engine.prepareCandidate(
            item: firstItem,
            request: config
        )
        XCTAssertNotEqual(regenerated.artifact, first.artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: regenerated.artifact.artifactURL.path))
        await engine.reset()
    }

    // MARK: - Best effort and Save Anyway

    func test_unattainableTarget_returnsTargetMiss_withoutWritingAnyFile() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())
        let config = request(targetBytes: 500) // impossible

        let outcome = await engine.convertItem(item, request: config)

        guard case .targetMiss(let candidate) = outcome else {
            return XCTFail("expected targetMiss, got \(outcome)")
        }
        guard case .bestEffort(let reason) = candidate.kind else {
            return XCTFail("expected bestEffort kind")
        }
        XCTAssertEqual(
            reason, .pixelFloorReached,
            "a 320px image sits below the Pixel Floor, so enabling resize could not help"
        )
        XCTAssertGreaterThan(candidate.artifact.byteCount, 500)
        let outputs = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.hasSuffix(".jpg") && $0 != "source.jpg" }
        XCTAssertEqual(outputs, [], "a Best-Effort Result is never auto-saved")
        await engine.reset()
    }

    func test_saveBestEffort_commitsRetainedArtifactByteIdentically() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())
        let outcome = await engine.convertItem(item, request: request(targetBytes: 500))
        guard case .targetMiss(let candidate) = outcome else {
            return XCTFail("expected targetMiss, got \(outcome)")
        }
        // The frozen configuration carries the resolved same-format output.
        XCTAssertEqual(
            candidate.configuration,
            TargetSizeJobConfiguration(format: .jpeg, request: request(targetBytes: 500))
        )

        let committed = try await engine.saveBestEffort(
            itemID: item.id,
            expectedArtifact: candidate.artifact,
            destination: item.destination
        )
        XCTAssertEqual(committed.sha256, candidate.artifact.sha256)
        XCTAssertEqual(
            try Data(contentsOf: committed.url).count, Int(candidate.artifact.byteCount)
        )
        await engine.reset()
    }

    func test_saveBestEffortRejectsAStaleCandidateAfterConfigurationChanges() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourceJPEG())
        let firstConfig = request(targetBytes: 500)
        let secondConfig = request(targetBytes: 600)

        let first = try await engine.prepareCandidate(
            item: item,
            request: firstConfig
        )
        let second = try await engine.prepareCandidate(
            item: item,
            request: secondConfig
        )
        XCTAssertNotEqual(first.artifact, second.artifact)

        do {
            _ = try await engine.saveBestEffort(
                itemID: item.id,
                expectedArtifact: first.artifact,
                destination: item.destination
            )
            XCTFail("expected stale candidate rejection")
        } catch {
            XCTAssertEqual(error as? ImageConversionFailure, .sourceChanged)
        }
        await engine.reset()
    }

    func test_resizeFallback_reachesOtherwiseUnattainableTarget() async throws {
        // A source larger than the 640px Pixel Floor, with a target derived
        // from real measurements: unattainable at original dimensions, but
        // comfortably attainable once resized.
        let url = try writeSourceJPEG(name: "large.jpg", width: 1600, height: 1200)

        let probe = try ImageIOCandidateEncoder(input: .file(url))
        let floorAtOriginal = try probe.encode(.init(
            format: .jpeg, quality: 40,
            dimensions: PixelDimensions(width: 1600, height: 1200),
            transparencyBackgroundHex: nil
        ))
        let floorAtPixelFloor = try probe.encode(.init(
            format: .jpeg, quality: 40,
            dimensions: PixelDimensions(width: 640, height: 480),
            transparencyBackgroundHex: nil
        ))
        let target = Int64(floorAtPixelFloor.count) * 12 / 10
        try XCTSkipUnless(Int64(floorAtOriginal.count) > target,
                          "fixture no longer separates original from resized floor")

        let engine = try ImageConversionEngine()
        let missOutcome = await engine.convertItem(
            makeItem(url, base: "miss"), request: request(targetBytes: target, allowResize: false)
        )
        guard case .targetMiss(let missed) = missOutcome else {
            return XCTFail("expected miss without resize, got \(missOutcome)")
        }
        guard case .bestEffort(.qualityFloorReached) = missed.kind else {
            return XCTFail("resize off must stop at the quality floor")
        }

        let hitOutcome = await engine.convertItem(
            makeItem(url, base: "hit"), request: request(targetBytes: target, allowResize: true)
        )
        guard case .success(let conversion) = hitOutcome else {
            return XCTFail("expected success with resize, got \(hitOutcome)")
        }
        XCTAssertLessThanOrEqual(conversion.output.byteCount, target)
        XCTAssertTrue(conversion.candidate.resizeFallbackApplied)
        XCTAssertLessThan(
            conversion.candidate.dimensions.longestEdge,
            conversion.candidate.sourceDimensions.longestEdge
        )
        await engine.reset()
    }

    // MARK: - Contract failures

    func test_cancelledConsumerCancelsUnderlyingPreparationAndAllowsRetry() async throws {
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourcePNG(width: 1_600, height: 1_200))
        let config = request(targetBytes: 500, allowResize: true)

        let preparation = Task {
            try await engine.prepareCandidate(
                item: item,
                request: config
            )
        }
        await Task.yield()
        preparation.cancel()

        do {
            _ = try await preparation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the final consumer cancels the underlying preparation.
        }
        let jobsAfterCancellation = await engine.activeJobCount
        XCTAssertEqual(jobsAfterCancellation, 0)

        _ = try await engine.prepareCandidate(
            item: item,
            request: config
        )
        let jobsAfterRetry = await engine.activeJobCount
        XCTAssertEqual(jobsAfterRetry, 0)
        await engine.reset()
    }

    func test_gifSource_isUnsupportedForTargetSize() async throws {
        // Same-format resolution rejects GIF before any frame-count detail:
        // GIF has no size-compression strategy regardless of animation.
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, ImageConversionFormat.gif.typeIdentifier as CFString, 2, nil
        )!
        let frame = makeGradientImage(width: 32, height: 32)
        CGImageDestinationAddImage(destination, frame, nil)
        CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = tempDirectory.appendingPathComponent("animated.gif")
        try (data as Data).write(to: url)

        let engine = try ImageConversionEngine()
        let outcome = await engine.convertItem(
            makeItem(url), request: request(targetBytes: 40_000)
        )
        guard case .unsupported(.targetSizeUnsupportedFormat) = outcome else {
            return XCTFail("expected unsupported(targetSizeUnsupportedFormat), got \(outcome)")
        }
        await engine.reset()
    }

    func test_multiFrameSupportedFormat_isUnsupported() async throws {
        // An animated PNG resolves to a supported format but keeps the
        // Multi-Image rejection.
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, ImageConversionFormat.png.typeIdentifier as CFString, 2, nil
        )!
        let frame = makeGradientImage(width: 32, height: 32)
        let frameProperties = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, frame, frameProperties)
        CGImageDestinationAddImage(destination, frame, frameProperties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = tempDirectory.appendingPathComponent("animated.png")
        try (data as Data).write(to: url)
        try XCTSkipUnless(
            CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0 > 1,
            "runtime did not produce a multi-frame APNG"
        )

        let engine = try ImageConversionEngine()
        let outcome = await engine.convertItem(
            makeItem(url), request: request(targetBytes: 40_000)
        )
        guard case .unsupported(.multiImageUnsupported) = outcome else {
            return XCTFail("expected unsupported(multiImageUnsupported), got \(outcome)")
        }
        await engine.reset()
    }

    func test_sourceChangedDuringRun_discardsCandidate() async throws {
        let engine = try ImageConversionEngine()
        let url = try writeSourceJPEG()
        let item = makeItem(url)
        let config = request(targetBytes: 40_000)

        // Prepare from the original source, then mutate the file so the
        // commit-time revalidation must reject the cached candidate.
        _ = try await engine.prepareCandidate(item: item, request: config)
        try Data("corrupted".utf8).write(to: url)

        let outcome = await engine.convertItem(item, request: config)
        switch outcome {
        case .failed(.sourceChanged), .unsupported(.undecodable):
            break // Both prove the stale candidate was never committed.
        default:
            XCTFail("expected sourceChanged/undecodable, got \(outcome)")
        }
        let outputs = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.hasSuffix(".jpg") && $0 != "source.jpg" }
        XCTAssertEqual(outputs, [], "no output may exist for a changed source")
        await engine.reset()
    }

    func test_passThrough_sameFormatSourceUnderLimit() async throws {
        // Build a JPEG source with GPS, already below the limit.
        let jpegData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            jpegData, ImageConversionFormat.jpeg.typeIdentifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, makeGradientImage(), [
            kCGImageDestinationLossyCompressionQuality: 0.5,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = tempDirectory.appendingPathComponent("already-small.jpg")
        try (jpegData as Data).write(to: url)

        let engine = try ImageConversionEngine()
        let item = makeItem(url, base: "copy")
        let outcome = await engine.convertItem(
            item, request: request(targetBytes: Int64(jpegData.length) + 100_000)
        )

        guard case .success(let conversion) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        if case .passThrough = conversion.candidate.kind {
            let onDisk = try Data(contentsOf: conversion.output.url)
            XCTAssertTrue(CandidateAuditor.audit(onDisk).ancillaryMetadataAbsent,
                          "pass-through must still strip GPS")
        }
        // A re-encoded fallback is also a valid outcome when the runtime
        // cannot rewrite losslessly; the audit above only binds pass-through.
        await engine.reset()
    }

    // MARK: - WebP same-format (bundled libwebp on the quality search)

    func test_webpSource_sameFormat_reachesTargetAndCommitsWebP() async throws {
        // Fixture: seed a WebP file through the app's own encoder (ImageIO
        // cannot write WebP).
        let seedURL = try writeSourcePNG(name: "seed.png", width: 800, height: 600)
        let seed = try ImageIOCandidateEncoder(input: .file(seedURL))
        let dimensions = PixelDimensions(width: 800, height: 600)
        let webpData = try seed.encode(.init(
            format: .webp, quality: 95, dimensions: dimensions, transparencyBackgroundHex: nil
        ))
        let url = tempDirectory.appendingPathComponent("source.webp")
        try webpData.write(to: url)

        // A target between the floor-quality and top-quality re-encodes,
        // derived from real measurements.
        let probe = try ImageIOCandidateEncoder(input: .file(url))
        let atFloor = try probe.encode(.init(
            format: .webp, quality: 40, dimensions: dimensions, transparencyBackgroundHex: nil
        ))
        let atTop = try probe.encode(.init(
            format: .webp, quality: 100, dimensions: dimensions, transparencyBackgroundHex: nil
        ))
        let target = Int64(atFloor.count) * 12 / 10
        try XCTSkipUnless(Int64(atTop.count) > target && Int64(webpData.count) > target,
                          "fixture no longer separates floor from top quality")

        let engine = try ImageConversionEngine()
        let outcome = await engine.convertItem(
            makeItem(url, base: "webp-out"), request: request(targetBytes: target)
        )
        guard case .success(let conversion) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertLessThanOrEqual(conversion.output.byteCount, target)
        XCTAssertEqual(conversion.output.url.pathExtension, "webp",
                       "same-format in/out: a WebP source commits a WebP output")
        XCTAssertEqual(conversion.candidate.configuration.format, .webp)
        XCTAssertGreaterThanOrEqual(conversion.candidate.quality, 40)
        await engine.reset()
    }

    // MARK: - PNG same-format (resize-only strategy)

    func test_pngSource_reachesTargetByScalingDown_regardlessOfAllowResize() async throws {
        // Derive a target that is unattainable at original dimensions but
        // attainable at the Pixel Floor, from real measurements.
        let url = try writeSourcePNG(name: "large.png", width: 1_600, height: 1_200)
        let probe = try ImageIOCandidateEncoder(input: .file(url))
        let atOriginal = try probe.encode(.init(
            format: .png, quality: 100,
            dimensions: PixelDimensions(width: 1_600, height: 1_200),
            transparencyBackgroundHex: nil
        ))
        let atFloor = try probe.encode(.init(
            format: .png, quality: 100,
            dimensions: PixelDimensions(width: 640, height: 480),
            transparencyBackgroundHex: nil
        ))
        let target = Int64(atFloor.count) * 12 / 10
        try XCTSkipUnless(Int64(atOriginal.count) > target,
                          "fixture no longer separates original from floor")

        let engine = try ImageConversionEngine()
        // PNG's only lever is resizing, so the strategy applies even with the
        // Resize Fallback preference off.
        let outcome = await engine.convertItem(
            makeItem(url, base: "shrunk"), request: request(targetBytes: target, allowResize: false)
        )
        guard case .success(let conversion) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertLessThanOrEqual(conversion.output.byteCount, target)
        XCTAssertEqual(conversion.output.url.pathExtension, "png",
                       "same-format in/out: a PNG source commits a PNG output")
        XCTAssertEqual(conversion.candidate.configuration.format, .png)
        XCTAssertTrue(conversion.candidate.resizeFallbackApplied)
        XCTAssertGreaterThanOrEqual(
            conversion.candidate.dimensions.longestEdge,
            TargetSizePolicy.pixelFloorLongestEdge
        )
        await engine.reset()
    }

    func test_pngSource_belowPixelFloor_missesWithPixelFloorReason() async throws {
        // 320px sits below the Pixel Floor: no smaller size may be produced,
        // so an unattainable target is a miss with the resize hint suppressed.
        let engine = try ImageConversionEngine()
        let item = makeItem(try writeSourcePNG())
        let outcome = await engine.convertItem(item, request: request(targetBytes: 500))

        guard case .targetMiss(let candidate) = outcome else {
            return XCTFail("expected targetMiss, got \(outcome)")
        }
        guard case .bestEffort(.pixelFloorReached) = candidate.kind else {
            return XCTFail("expected pixelFloorReached, got \(candidate.kind)")
        }
        XCTAssertEqual(candidate.configuration.format, .png)
        await engine.reset()
    }
}
