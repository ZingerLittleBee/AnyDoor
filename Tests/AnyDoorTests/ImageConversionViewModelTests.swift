import CoreGraphics
import ImageCodec
import ImageIO
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

@MainActor
private final class OutputDirectoryPickerGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<URL?, Never>?

    func pick() async -> URL? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func resume(returning url: URL?) {
        let continuation = continuation
        self.continuation = nil
        isWaiting = false
        continuation?.resume(returning: url)
    }
}

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
    func testCancelActiveWorkStopsAnInFlightConversion() async throws {
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
        await model.cancelActiveWork()

        XCTAssertFalse(model.isConverting)
        XCTAssertTrue(model.items.contains(item), "an interrupted item stays in the basket")
        XCTAssertNil(model.itemStatuses[item.id],
                     "a cancelled run must not record a terminal per-item status")
        model.clear()
    }

    @MainActor
    func testCancelActiveWorkPreventsPendingPickerFromStartingConversion() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try writePNG()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let outputDirectory = source.deletingLastPathComponent()

        let gate = OutputDirectoryPickerGate()
        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.outputDirectoryPicker = { _ in await gate.pick() }
        model.addFiles([source])
        model.convert()

        let pickerDeadline = ContinuousClock.now + .seconds(1)
        while !gate.isWaiting, ContinuousClock.now < pickerDeadline {
            await Task.yield()
        }
        XCTAssertTrue(gate.isWaiting)

        let cancellation = Task { @MainActor in
            await model.cancelActiveWork()
        }
        await Task.yield()
        gate.resume(returning: outputDirectory)
        await cancellation.value

        let unexpectedStartDeadline = ContinuousClock.now + .milliseconds(200)
        while ImageConversionPreferences.outputDirectory(defaults: defaults) == nil,
              ContinuousClock.now < unexpectedStartDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(ImageConversionPreferences.outputDirectory(defaults: defaults))
        XCTAssertFalse(model.isConverting)
        XCTAssertEqual(model.items.count, 1)
    }

    @MainActor
    func testCancelActiveWorkStopsOutputPickerBeforeItsTaskStarts() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.addBitmap(Data([0x01]))

        var pickerCalls = 0
        model.outputDirectoryPicker = { _ in
            pickerCalls += 1
            return FileManager.default.temporaryDirectory
        }

        model.convert()
        await model.cancelActiveWork()
        await Task.yield()

        XCTAssertEqual(pickerCalls, 0)
        XCTAssertFalse(model.canConvert)
        model.convert()
        await Task.yield()
        XCTAssertEqual(pickerCalls, 0, "a quiesced model must reject new work")
    }

    @MainActor
    func testCancelActiveWorkCancelsSaveAnywayBeforeCommit() async throws {
        let suiteName = "ImageConversionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try writePNG()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ImageConversionViewModel(availableFormats: [.jpeg], defaults: defaults)
        model.outputDirectoryPicker = { _ in directory }
        model.mode = .targetSize
        model.switchTargetUnit(to: .kb)
        model.targetText = "0.01"
        model.commitTargetText()
        model.addFiles([source])
        let item = try XCTUnwrap(model.items.first)

        model.convert()
        let missDeadline = ContinuousClock.now + .seconds(10)
        while model.itemStatuses[item.id] == nil, ContinuousClock.now < missDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .targetMiss = model.itemStatuses[item.id] else {
            return XCTFail("expected a retained target miss")
        }
        let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))

        model.saveBestEffort(item)
        await model.cancelActiveWork()

        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
            filesBefore,
            "a cancelled Save Anyway task must not commit an output"
        )
        XCTAssertTrue(model.items.contains(item))
        XCTAssertTrue(model.itemStatuses.isEmpty)
    }

    @MainActor
    func testCancelActiveWorkClearsPreviewAndPreflightState() async throws {
        let source = try writeAnimatedGIF()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let model = ImageConversionViewModel(availableFormats: [.png])
        model.addFiles([source])
        model.resetSidebarForPresentation()

        await model.cancelActiveWork()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.previewState, .empty)
        XCTAssertTrue(model.qualityFirstFrameOnlyItemIDs.isEmpty)
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
