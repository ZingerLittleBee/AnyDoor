import CoreGraphics
import ImageCodec
import ImageIO
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class ImageConversionViewModelTests: XCTestCase {
    @MainActor
    func testBasketMutationsAreIgnoredWhileAConversionIsRunning() throws {
        let model = ImageConversionViewModel(availableFormats: [.jpeg])
        model.addBitmap(Data([0x01]))
        let original = try XCTUnwrap(model.items.first)
        let incoming = ImageConversionBasketItem.bitmap(Data([0x02]), displayName: "Incoming")
        model.isConverting = true

        model.addBitmap(Data([0x03]))
        model.add([incoming])
        model.remove(original)
        model.clear()

        XCTAssertEqual(model.items, [original])
    }

    @MainActor
    func testTargetConfigurationChangeClearsPriorItemOutcomes() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try writePNG()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        // Bypass the modal output-folder panel.
        let outputDirectory = source.deletingLastPathComponent()
        model.outputDirectoryPicker = { _ in outputDirectory }
        model.mode = .targetSize
        model.switchTargetUnit(to: .kb)
        model.targetText = "0.01"
        model.commitTargetText()
        model.addFiles([source])
        let item = try XCTUnwrap(model.items.first)

        // The run starts asynchronously after the folder pick resolves; wait
        // for the terminal per-item status rather than the transient flag.
        model.convert()
        let runDeadline = ContinuousClock.now + .seconds(10)
        while model.itemStatuses[item.id] == nil, ContinuousClock.now < runDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .targetMiss = model.itemStatuses[item.id] else {
            return XCTFail("expected a retained target miss")
        }
        XCTAssertEqual(
            ImageConversionPreferences.outputDirectory(defaults: defaults), outputDirectory,
            "a confirmed pick must be remembered"
        )

        model.targetText = "0.02"
        model.commitTargetText()
        XCTAssertTrue(model.itemStatuses.isEmpty)
        model.clear()
    }

    @MainActor
    func testHidingWindowDeletesTheDisplayedPreviewArtifact() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try writePNG()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.mode = .targetSize
        model.addFiles([source])
        model.resetSidebarForPresentation()

        let deadline = ContinuousClock.now + .seconds(5)
        while model.previewState == .updating, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready(let candidate) = model.previewState else {
            return XCTFail("expected an exact preview candidate")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.artifact.artifactURL.path))

        model.windowDidHide()
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: candidate.artifact.artifactURL.path),
              ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.artifact.artifactURL.path))
        model.clear()
    }

    @MainActor
    func testQualityBasketShowsFirstFrameOnlyNoticeBeforeRun() async throws {
        let source = try writeAnimatedGIF()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let model = ImageConversionViewModel(availableFormats: [.png])

        model.addFiles([source])

        let item = try XCTUnwrap(model.items.first)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.qualityFirstFrameOnlyItemIDs.contains(item.id),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.qualityFirstFrameOnlyItemIDs.contains(item.id))
        model.clear()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.qualityFirstFrameOnlyItemIDs.isEmpty)
    }

    @MainActor
    func testQualityModeProducesAnExactResultPreview() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try writePNG()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.selectedFormat = .jpeg
        model.mode = .quality
        model.addFiles([source])
        model.resetSidebarForPresentation()

        func awaitPreview() async throws -> ImageConversionViewModel.QualityPreviewCandidate {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if case .readyQuality(let preview) = model.previewState { return preview }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("preview did not settle: \(model.previewState)")
            throw CancellationError()
        }

        let preview = try await awaitPreview()
        // The preview bytes are the exact run output: same converter, same
        // format and quality.
        let expected = try ImageConverter().candidateData(
            fileAt: source, format: .jpeg, quality: Double(model.qualityPercent) / 100.0
        )
        XCTAssertEqual(preview.data, expected)

        // A quality change must supersede the preview identity.
        let previousID = preview.id
        model.qualityPercent = max(1, model.qualityPercent - 30)
        let updated = try await awaitPreview()
        XCTAssertNotEqual(updated.id, previousID)

        model.windowDidHide()
        XCTAssertEqual(model.previewState, .empty)
        model.clear()
    }

    @MainActor
    func testCancelActiveRunStopsAnInFlightConversion() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A large noisy source with an unattainable target keeps the search
        // busy long enough to observe the cancellation deterministically.
        let source = try writeNoisePNG(side: 2_048)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.outputDirectoryPicker = { _ in source.deletingLastPathComponent() }
        model.mode = .targetSize
        model.switchTargetUnit(to: .kb)
        model.targetText = "0.01"
        model.commitTargetText()
        model.addFiles([source])
        let item = try XCTUnwrap(model.items.first)

        model.convert()
        let startDeadline = ContinuousClock.now + .seconds(10)
        while !model.isConverting, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.isConverting)

        // The plugin's deactivate path: cancel and wait for the run to wind
        // down — nothing may continue in the background afterwards.
        await model.cancelActiveRun()

        XCTAssertFalse(model.isConverting)
        XCTAssertTrue(model.items.contains(item), "an interrupted item stays in the basket")
        XCTAssertNil(model.itemStatuses[item.id],
                     "a cancelled run must not record a terminal per-item status")
        model.clear()
    }

    private func writeNoisePNG(side: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageConversionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("noise.png")
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Deterministic per-pixel noise defeats compression, so every encode
        // attempt in the target-size search costs real work.
        if let buffer = context.data {
            let bytes = buffer.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for i in 0..<(context.bytesPerRow * side) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            ImageConversionFormat.png.typeIdentifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writePNG() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageConversionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            ImageConversionFormat.png.typeIdentifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writeAnimatedGIF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageConversionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("animated.gif")
        let frameURL = try writePNG()
        defer { try? FileManager.default.removeItem(at: frameURL.deletingLastPathComponent()) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(frameURL as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            ImageConversionFormat.gif.typeIdentifier as CFString,
            2,
            nil
        ))
        CGImageDestinationAddImage(destination, frame, nil)
        CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
