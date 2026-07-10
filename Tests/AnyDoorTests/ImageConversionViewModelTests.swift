import CoreGraphics
import ImageIO
import XCTest
@testable import AnyDoor

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
        model.mode = .targetSize
        model.switchTargetUnit(to: .kb)
        model.targetText = "0.01"
        model.commitTargetText()
        model.addFiles([source])
        let item = try XCTUnwrap(model.items.first)

        model.convert()
        while model.isConverting {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .targetMiss = model.itemStatuses[item.id] else {
            return XCTFail("expected a retained target miss")
        }

        model.allowResize.toggle()
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
    func testQualityBasketShowsFirstFrameOnlyNoticeBeforeRun() throws {
        let source = try writeAnimatedGIF()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let model = ImageConversionViewModel(availableFormats: [.png])

        model.addFiles([source])

        let item = try XCTUnwrap(model.items.first)
        XCTAssertTrue(model.qualityFirstFrameOnlyItemIDs.contains(item.id))
        model.clear()
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
