import AppKit
import CoreGraphics
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryCaptureNoticeLimiterTests: XCTestCase {
    func testAdmitsOneNoticePerKindPerThirtySecondWindow() {
        var limiter = ClipboardHistoryCaptureNoticeLimiter()

        XCTAssertTrue(limiter.admit(.tooLarge, at: .zero))
        XCTAssertFalse(limiter.admit(.tooLarge, at: .seconds(20)))
        XCTAssertFalse(
            limiter.admit(.tooLarge, at: .seconds(30) - .nanoseconds(1))
        )
        // The window runs from the last admitted notice, so the suppressed
        // attempts above did not extend it.
        XCTAssertTrue(limiter.admit(.tooLarge, at: .seconds(30)))
        XCTAssertFalse(limiter.admit(.tooLarge, at: .seconds(59)))
        XCTAssertTrue(limiter.admit(.tooLarge, at: .seconds(60)))
    }

    func testKindsAreRateLimitedIndependently() {
        var limiter = ClipboardHistoryCaptureNoticeLimiter()

        XCTAssertTrue(limiter.admit(.tooLarge, at: .zero))
        XCTAssertTrue(limiter.admit(.captureFailed, at: .seconds(10)))
        XCTAssertFalse(limiter.admit(.tooLarge, at: .seconds(11)))
        XCTAssertFalse(limiter.admit(.captureFailed, at: .seconds(11)))
        XCTAssertTrue(limiter.admit(.tooLarge, at: .seconds(30)))
        XCTAssertFalse(limiter.admit(.captureFailed, at: .seconds(39)))
        XCTAssertTrue(limiter.admit(.captureFailed, at: .seconds(40)))
    }
}

final class ClipboardHistoryCaptureNoticeTests: XCTestCase {
    @MainActor
    func testOversizedImageRaisesOneTooLargeNoticePerWindow() async throws {
        let harness = try await CaptureNoticeHarness()
        let png = try XCTUnwrap(overPixelLimitPNG)

        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])

        for second in [1, 10, 20] {
            harness.clock.now = .seconds(second)
            harness.writeImage(png)
            await harness.observe()
        }
        harness.clock.now = .seconds(30) - .milliseconds(1)
        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(
            harness.notices,
            [.tooLarge],
            "A burst of refused copies raises one notice"
        )

        harness.clock.now = .seconds(30)
        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge, .tooLarge])

        let page = try await harness.module.page(.init())
        XCTAssertEqual(page.entries, [])
    }

    @MainActor
    func testOversizedContentSharesTheTooLargeNoticeAndWindow() async throws {
        let harness = try await CaptureNoticeHarness()
        // The only large write in this file: 128 MiB + 1 byte of HTML, which
        // the module refuses as `contentTooLarge`.
        let html = NSPasteboardItem()
        html.setData(
            Data(repeating: 0x41, count: 128 * 1_024 * 1_024 + 1),
            forType: .html
        )
        harness.write([html])
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])

        // Both limits share one message, so they share one window: an
        // oversized image right after must not stack an identical toast.
        harness.writeImage(try XCTUnwrap(overPixelLimitPNG))
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])

        let page = try await harness.module.page(.init())
        XCTAssertEqual(page.entries, [])
    }

    @MainActor
    func testTooLargeAndCaptureFailedNoticesAreRateLimitedSeparately()
        async throws
    {
        let harness = try await CaptureNoticeHarness(faults: [.diskFull])
        let png = try XCTUnwrap(overPixelLimitPNG)

        harness.writeImage(png)
        await harness.observe()
        harness.writeText("rejected by a full disk")
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge, .captureFailed])

        harness.writeImage(png)
        await harness.observe()
        harness.writeText("rejected again")
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge, .captureFailed])
    }

    @MainActor
    func testAnyDoorSelfWriteRaisesNoNotice() async throws {
        let harness = try await CaptureNoticeHarness()
        let png = try XCTUnwrap(overPixelLimitPNG)

        let wrote = harness.module.pasteboardSelfWrites.perform(
            to: harness.pasteboard
        ) { pasteboard in
            pasteboard.clearContents()
            return pasteboard.writeObjects([makeImageItem(png)])
        }
        XCTAssertTrue(wrote)
        await harness.observe()
        XCTAssertEqual(harness.notices, [])

        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(
            harness.notices,
            [.tooLarge],
            "The same copy made by another app raises the notice"
        )
    }

    @MainActor
    func testExcludedSourceAppRaisesNoNotice() async throws {
        let passwords = ClipboardHistoryApplicationSource(
            bundleIdentifier: "com.apple.Passwords",
            displayName: "Passwords"
        )
        let harness = try await CaptureNoticeHarness(
            sourceProvider: { passwords }
        )
        let png = try XCTUnwrap(overPixelLimitPNG)

        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(
            harness.notices,
            [],
            "A notice would reveal password manager activity"
        )

        harness.monitor.updateConfiguration(
            .init(excludedBundleIdentifiers: [])
        )
        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])
    }

    @MainActor
    func testExclusionMarkerRaisesNoNotice() async throws {
        let harness = try await CaptureNoticeHarness()
        let png = try XCTUnwrap(overPixelLimitPNG)

        harness.writeImage(
            png,
            strings: [.init("org.nspasteboard.ConcealedType"): "1"]
        )
        await harness.observe()
        XCTAssertEqual(harness.notices, [])

        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])
    }

    /// `readSnapshot` confirms the generation before it reads the items, so a
    /// concealed write landing in between reaches the module as `excluded`
    /// after the monitor's own marker check passed. The rejection mapping is
    /// the only guard left there, so the snapshot here comes from a second
    /// pasteboard that already holds that racing write.
    @MainActor
    func testExclusionMarkerRacingTheSnapshotRaisesNoNotice() async throws {
        let racingWrite = makeNoticePasteboard()
        defer { racingWrite.releaseGlobally() }
        let harness = try await CaptureNoticeHarness(
            snapshotRequest: { _, _ in
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: racingWrite
                )
            }
        )
        let png = try XCTUnwrap(overPixelLimitPNG)

        racingWrite.clearContents()
        XCTAssertTrue(
            racingWrite.writeObjects([
                makeImageItem(
                    png,
                    strings: [.init("org.nspasteboard.ConcealedType"): "1"]
                )
            ])
        )
        harness.writeImage(png)
        await harness.observe()
        let verdict = try await harness.module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: racingWrite),
            source: .unknown
        )
        XCTAssertEqual(verdict, .skipped(.excluded))
        XCTAssertEqual(
            harness.notices,
            [],
            "A notice would reveal password manager activity"
        )

        racingWrite.clearContents()
        XCTAssertTrue(racingWrite.writeObjects([makeImageItem(png)]))
        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(
            harness.notices,
            [.tooLarge],
            "The same snapshot without the marker raises the notice"
        )
    }

    @MainActor
    func testIgnoredUniversalClipboardRaisesNoNotice() async throws {
        let harness = try await CaptureNoticeHarness(
            configuration: .init(ignoresUniversalClipboard: true)
        )
        let png = try XCTUnwrap(overPixelLimitPNG)
        let remote: [NSPasteboard.PasteboardType: String] = [
            .init("com.apple.is-remote-clipboard"): "1"
        ]

        harness.writeImage(png, strings: remote)
        await harness.observe()
        XCTAssertEqual(harness.notices, [])

        harness.monitor.updateConfiguration(
            .init(ignoresUniversalClipboard: false)
        )
        harness.writeImage(png, strings: remote)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])
    }

    @MainActor
    func testLockedKeychainRaisesNoNotice() async throws {
        let unlocked = OSAllocatedUnfairLock(initialState: false)
        let harness = try await CaptureNoticeHarness(
            isKeychainUnlocked: { unlocked.withLock { $0 } }
        )
        let png = try XCTUnwrap(overPixelLimitPNG)

        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [])

        unlocked.withLock { $0 = true }
        harness.writeImage(png)
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])
    }

    @MainActor
    func testRoutineRejectionsRaiseNoNotice() async throws {
        let harness = try await CaptureNoticeHarness()

        harness.pasteboard.clearContents()
        await harness.observe()
        let cleared = try await harness.captureDirectly()
        XCTAssertEqual(cleared, .skipped(.empty))
        XCTAssertEqual(harness.notices, [])

        let emptyString = NSPasteboardItem()
        emptyString.setString("", forType: .string)
        harness.write([emptyString])
        await harness.observe()
        let unsupported = try await harness.captureDirectly()
        XCTAssertEqual(unsupported, .skipped(.unsupportedItem))
        XCTAssertEqual(harness.notices, [])

        let missingFile = NSPasteboardItem()
        missingFile.setString(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AnyDoor-CaptureNotice-missing-\(UUID().uuidString).txt"
                )
                .absoluteString,
            forType: .fileURL
        )
        harness.write([missingFile])
        await harness.observe()
        let invalidReference = try await harness.captureDirectly()
        XCTAssertEqual(invalidReference, .skipped(.invalidFileReference))
        XCTAssertEqual(harness.notices, [])

        harness.writeImage(try XCTUnwrap(overPixelLimitPNG))
        await harness.observe()
        XCTAssertEqual(harness.notices, [.tooLarge])
    }

    /// Production builds the monitor inside `setMonitoring` without a
    /// handler, so notices must reach the one the module was constructed with.
    @MainActor
    func testMonitorFallsBackToTheModuleNoticeHandler() async throws {
        let store = try CaptureNoticeTemporaryStore()
        let recorder = CaptureNoticeRecorder()
        let module = ClipboardHistoryModule(
            testingStoreRoot: store.url,
            keyStore: CaptureNoticeMemoryKeyStore(),
            captureNotices: { recorder.notices.append($0) }
        )
        let pasteboard = makeNoticePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            sourceProvider: { nil },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([
                makeImageItem(try XCTUnwrap(overPixelLimitPNG))
            ])
        )
        await monitor.observeForTesting()

        XCTAssertEqual(recorder.notices, [.tooLarge])
    }
}

/// 8100 x 8000 = 64,800,000 decoded pixels, just over the 64,000,000-pixel
/// Capture Safety Limit. The all-black grayscale PNG compresses to a small
/// file and the limit reads only its header, so writing it repeatedly is
/// cheap. It is encoded once per test process.
private let overPixelLimitPNG: Data? = {
    guard let context = CGContext(
        data: nil,
        width: 8_100,
        height: 8_000,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let image = context.makeImage() else {
        return nil
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}()

/// A real module and monitor on a private named pasteboard, recording every
/// notice the monitor reports against an injected monotonic clock.
@MainActor
private final class CaptureNoticeHarness {
    let store: CaptureNoticeTemporaryStore
    let module: ClipboardHistoryModule
    let pasteboard: NSPasteboard
    let clock: CaptureNoticeClock
    let monitor: ClipboardHistoryCaptureMonitor
    private let recorder: CaptureNoticeRecorder

    var notices: [ClipboardHistoryCaptureNotice] {
        recorder.notices
    }

    init(
        configuration: ClipboardHistoryMonitoringConfiguration = .init(),
        sourceProvider: @escaping @MainActor
            () -> ClipboardHistoryApplicationSource? = { nil },
        snapshotRequest: @escaping @MainActor (NSPasteboard, Int) ->
            ClipboardHistoryPasteboardCaptureRequest = {
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: $0,
                    expectedGeneration: $1
                )
            },
        isKeychainUnlocked: @escaping @Sendable () -> Bool? = { true },
        faults: Set<ClipboardHistoryFaultPoint> = []
    ) async throws {
        let store = try CaptureNoticeTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: store.url,
            keyStore: CaptureNoticeMemoryKeyStore(),
            faultInjector: ClipboardHistoryFaultInjector(points: faults)
        )
        let pasteboard = makeNoticePasteboard()
        let clock = CaptureNoticeClock()
        let recorder = CaptureNoticeRecorder()
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            reportNotice: { recorder.notices.append($0) },
            configuration: configuration,
            sourceProvider: sourceProvider,
            now: { clock.now },
            snapshotRequest: snapshotRequest,
            isKeychainUnlocked: isKeychainUnlocked,
            installsSystemObservers: false
        )
        self.store = store
        self.module = module
        self.pasteboard = pasteboard
        self.clock = clock
        self.recorder = recorder
        self.monitor = monitor
        await monitor.setEnabled(true)
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    func observe() async {
        await monitor.observeForTesting()
    }

    func write(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
    }

    func writeImage(
        _ png: Data,
        strings: [NSPasteboard.PasteboardType: String] = [:]
    ) {
        write([makeImageItem(png, strings: strings)])
    }

    func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The module's own verdict on the current pasteboard, without the monitor.
    func captureDirectly() async throws
        -> ClipboardHistoryPasteboardCaptureOutcome
    {
        try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: .unknown
        )
    }
}

@MainActor
private func makeNoticePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(
        name: .init("dev.bybee.AnyDoor.notice.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    return pasteboard
}

@MainActor
private func makeImageItem(
    _ png: Data,
    strings: [NSPasteboard.PasteboardType: String] = [:]
) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    for (type, value) in strings {
        item.setString(value, forType: type)
    }
    return item
}

@MainActor
private final class CaptureNoticeRecorder {
    var notices: [ClipboardHistoryCaptureNotice] = []
}

@MainActor
private final class CaptureNoticeClock {
    var now = Duration.zero
}

private final class CaptureNoticeTemporaryStore {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-CaptureNotice-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct CaptureNoticeMemoryKeyStore: ClipboardHistoryMasterKeyStoring {
    private static let key = Data(repeating: 0x95, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Self.key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(Self.key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
    }
}
