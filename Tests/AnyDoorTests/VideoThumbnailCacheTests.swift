import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import AnyDoor

@MainActor
final class VideoThumbnailCacheTests: XCTestCase {
    func testThumbnailUsesFirstFrameAndRespectsLandscapePixelLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("landscape.mov")
        try await writeMovie(at: url)

        let result = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        let image = try XCTUnwrap(result)
        assertSize(image, aspectRatio: 16.0 / 9.0)
        try assertColor(image, expected: .red)

        // Confirm the generated fixture really changes color: a later frame
        // must not accidentally satisfy the first-frame assertion above.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let later = try await generator.image(at: CMTime(value: 1, timescale: 1))
        try assertColor(later.image, expected: .blue)
    }

    func testPortraitVideoRetainsItsAspectRatioWithinPixelLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("portrait.mov")
        try await writeMovie(at: url, width: 180, height: 320)

        let result = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        let image = try XCTUnwrap(result)
        assertSize(image, aspectRatio: 9.0 / 16.0)
        try assertColor(image, expected: .red)
    }

    func testTrackRotationProducesAPortraitThumbnail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotated.mov")
        // The encoded pixels remain landscape; only the track transform
        // declares that playback should be portrait.
        try await writeMovie(
            at: url,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        )

        let result = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        let image = try XCTUnwrap(result)
        assertSize(image, aspectRatio: 9.0 / 16.0)
        try assertColor(image, expected: .red)
    }

    func testMissingAndInvalidVideosReturnNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.mov")
        let invalid = directory.appendingPathComponent("invalid.mov")
        try Data("This is not a movie.".utf8).write(to: invalid)

        let missingResult = await VideoThumbnailCache.thumbnail(at: missing, maxPixel: 128)
        let invalidResult = await VideoThumbnailCache.thumbnail(at: invalid, maxPixel: 128)
        XCTAssertNil(missingResult)
        XCTAssertNil(invalidResult)
    }

    func testReplacingVideoAtSamePathRefreshesTheThumbnail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replace.mov")
        try await writeMovie(at: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: url.path
        )
        let original = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        try assertColor(XCTUnwrap(original), expected: .red)

        try FileManager.default.removeItem(at: url)
        try await writeMovie(at: url, firstColor: .blue)
        // Use distinct explicit timestamps so this does not depend on how
        // quickly the two movies were written or filesystem time precision.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: url.path
        )
        let replacement = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        try assertColor(XCTUnwrap(replacement), expected: .blue)
    }

    func testAlreadyCancelledRequestReturnsNilIncludingCacheHit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancelled.mov")
        try await writeMovie(at: url)

        let coldRequest = Task { @MainActor in
            await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        }
        // No actor suspension occurs between creating and cancelling these
        // tasks, so each request starts with cancellation already set.
        coldRequest.cancel()
        let coldResult = await coldRequest.value
        XCTAssertNil(coldResult)

        let warmResult = await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        XCTAssertNotNil(warmResult)
        let cachedRequest = Task { @MainActor in
            await VideoThumbnailCache.thumbnail(at: url, maxPixel: 128)
        }
        cachedRequest.cancel()
        let cachedResult = await cachedRequest.value
        XCTAssertNil(cachedResult)
    }

    private func assertSize(
        _ image: CGImage,
        aspectRatio: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(image.width, 0, file: file, line: line)
        XCTAssertGreaterThan(image.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128, file: file, line: line)
        XCTAssertEqual(
            Double(image.width) / Double(image.height), aspectRatio,
            accuracy: 0.03, file: file, line: line
        )
    }

    private func assertColor(
        _ image: CGImage,
        expected: FrameColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        // Allow the small rounding and color-conversion differences of H.264.
        let dominantIndex = expected == .red ? 0 : 2
        let otherIndex = expected == .red ? 2 : 0
        XCTAssertGreaterThan(rgba[dominantIndex], 180, file: file, line: line)
        XCTAssertLessThan(rgba[otherIndex], 70, file: file, line: line)
        XCTAssertLessThan(rgba[1], 70, file: file, line: line)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum FrameColor: Equatable {
        case red
        case blue
    }

    private enum MovieFixtureError: Error {
        case cannotAddInput
        case writerFailed
        case inputReadinessTimedOut
        case pixelBufferAllocationFailed
        case pixelBufferLockFailed
    }

    private func writeMovie(
        at url: URL,
        width: Int = 320,
        height: Int = 180,
        transform: CGAffineTransform = .identity,
        firstColor: FrameColor = .red
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 1,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw MovieFixtureError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MovieFixtureError.writerFailed }
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        let laterColor: FrameColor = firstColor == .red ? .blue : .red
        for (index, color) in [firstColor, laterColor].enumerated() {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? MovieFixtureError.writerFailed
                }
                guard ContinuousClock.now < deadline else {
                    throw MovieFixtureError.inputReadinessTimedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let buffer = try makePixelBuffer(width: width, height: height, color: color)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1))
            else { throw writer.error ?? MovieFixtureError.writerFailed }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MovieFixtureError.writerFailed
        }
    }

    private func makePixelBuffer(width: Int, height: Int, color: FrameColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            nil, &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw MovieFixtureError.pixelBufferAllocationFailed
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw MovieFixtureError.pixelBufferLockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = color == .blue ? 255 : 0
                base[offset + 1] = 0
                base[offset + 2] = color == .red ? 255 : 0
                base[offset + 3] = 255
            }
        }
        return buffer
    }
}
