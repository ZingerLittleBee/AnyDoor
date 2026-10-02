import ClipboardHistoryTestSupport
import AppKit
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardProductionAdapterTests: XCTestCase {
    func testExplicitProductionsWriteSemanticValuesAndAvoidPassiveDuplicates()
        async throws
    {
        let fixture = try Fixture(testCase: self)
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        let ocr = try await fixture.adapter.produceOCR("recognized text")
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "recognized text"
        )
        XCTAssertEqual(ocr.pasteboardChangeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()

        let qr = try await fixture.adapter.produceQRCode("https://example.com")
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "https://example.com"
        )
        XCTAssertEqual(qr.pasteboardChangeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()

        let color = try await fixture.adapter.produceColor(
            hex: "#AABBCC",
            pasteboardValue: "rgb(170 187 204)"
        )
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "rgb(170 187 204)"
        )
        XCTAssertEqual(
            color.pasteboardChangeCount,
            fixture.pasteboard.changeCount
        )
        await monitor.observeForTesting()

        let (image, png) = try Self.makeImage()
        let screenshot = try await fixture.adapter.produceScreenshot(
            image: image,
            png: png,
            copyToPasteboard: true
        )
        XCTAssertEqual(
            screenshot.pasteboardChangeCount,
            fixture.pasteboard.changeCount
        )
        XCTAssertNotNil(fixture.pasteboard.data(forType: .tiff))
        await monitor.observeForTesting()

        let page = try await fixture.module.page(.init())
        XCTAssertEqual(page.entries.count, 4)
        XCTAssertEqual(page.entries.map(\.id), [
            try XCTUnwrap(screenshot.capture).entryID,
            try XCTUnwrap(color.capture).entryID,
            try XCTUnwrap(qr.capture).entryID,
            try XCTUnwrap(ocr.capture).entryID,
        ])
        XCTAssertEqual(page.entries[0].facets, [.image, .screenshot])
        XCTAssertTrue(page.entries[1].facets.contains(.color))
        XCTAssertTrue(page.entries[2].facets.contains(.qrCode))
        XCTAssertEqual(page.entries[3].previewText, "recognized text")
        XCTAssertTrue(
            page.entries.allSatisfy { $0.source == .anyDoor }
        )
    }

    func testScreenshotCanRecordWithoutChangingPasteboard() async throws {
        let fixture = try Fixture(testCase: self)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(
            fixture.pasteboard.setString("keep me", forType: .string)
        )
        let initialChangeCount = fixture.pasteboard.changeCount
        let (image, png) = try Self.makeImage()

        let outcome = try await fixture.adapter.produceScreenshot(
            image: image,
            png: png,
            copyToPasteboard: false
        )

        XCTAssertNil(outcome.pasteboardChangeCount)
        XCTAssertEqual(fixture.pasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "keep me"
        )
        let page = try await fixture.module.page(.init())
        XCTAssertEqual(
            page.entries.map(\.id),
            [try XCTUnwrap(outcome.capture).entryID]
        )
        XCTAssertEqual(page.entries.first?.facets, [.image, .screenshot])
    }

    func testCaptureFailureIsThrownAndSuppressedWriteIsNotPassivelyCaptured()
        async throws
    {
        let fixture = try Fixture(testCase: self, faults: [.databaseTransaction])
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        do {
            _ = try await fixture.adapter.produceOCR("cannot persist")
            XCTFail("Expected explicit capture to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }

        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "cannot persist"
        )
        await monitor.observeForTesting()
        let page = try await fixture.module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testCopyingRecordedScreenshotSuppressesWithoutCreatingCapture()
        async throws
    {
        let fixture = try Fixture(testCase: self)
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)
        let (image, _) = try Self.makeImage()

        let changeCount = try fixture.adapter.copyExistingScreenshot(image)

        XCTAssertEqual(changeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()
        let page = try await fixture.module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    /// Until the lifecycle confirms the pre-v2 migration, the store has to
    /// stay empty, even though it is already open. Every production still
    /// writes the pasteboard; only its history write is skipped.
    func testExplicitCapturesSkipHistoryUntilTheMigrationIsConfirmed()
        async throws
    {
        for state in [
            ClipboardHistoryLifecycleState.preparing,
            .migrating,
            .migrationFailed,
            .migrationBlocked(entryCount: 1),
        ] {
            let fixture = try Fixture(
                testCase: self,
                admitsHistoryWrite: state.leavesExplicitCapturesToTheStore
            )

            let ocr = try await fixture.adapter.produceOCR("recognized text")
            XCTAssertEqual(
                fixture.pasteboard.string(forType: .string),
                "recognized text",
                "\(state)"
            )
            let qr = try await fixture.adapter.produceQRCode(
                "https://example.com"
            )
            XCTAssertEqual(
                fixture.pasteboard.string(forType: .string),
                "https://example.com",
                "\(state)"
            )
            let color = try await fixture.adapter.produceColor(
                hex: "#AABBCC",
                pasteboardValue: "rgb(170 187 204)"
            )
            XCTAssertEqual(
                fixture.pasteboard.string(forType: .string),
                "rgb(170 187 204)",
                "\(state)"
            )
            let (image, png) = try Self.makeImage()
            let screenshot = try await fixture.adapter.produceScreenshot(
                image: image,
                png: png,
                copyToPasteboard: true
            )
            XCTAssertNotNil(
                fixture.pasteboard.data(forType: .tiff),
                "\(state)"
            )
            XCTAssertEqual(
                screenshot.pasteboardChangeCount,
                fixture.pasteboard.changeCount,
                "\(state)"
            )

            for outcome in [ocr, qr, color, screenshot] {
                XCTAssertNil(outcome.capture, "\(state)")
            }
            let page = try await fixture.module.page(.init())
            XCTAssertTrue(page.entries.isEmpty, "\(state)")
        }
    }

    /// After the migration the store decides, as before: one that is not
    /// open refuses the capture, and the pasteboard write stands.
    func testLaterStatesLeaveTheCaptureToTheStore() async throws {
        for (state, keyResult) in [
            (
                ClipboardHistoryLifecycleState.paused(.keychainLocked),
                ClipboardHistoryMasterKeyResult.locked
            ),
            (.storeUnavailable(.keyAccessDenied), .accessDenied),
            (.resetFailed, .failure(-1)),
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AnyDoor-ClipboardProductionClosed-\(UUID().uuidString)",
                    isDirectory: true
                )
            removeClipboardHistoryDirectoryAfterTest(directory)
            let module = trackClipboardHistoryModule(
                ClipboardHistoryModule(
                    testingStoreRoot: directory,
                    keyStore: FixedKeyStore(result: keyResult)
                )
            )
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name(
                    "AnyDoor-ClipboardProductionClosed-\(UUID().uuidString)"
                )
            )
            let adapter = ClipboardProductionAdapter(
                module: module,
                selfWrites: module.pasteboardSelfWrites,
                admitsHistoryWrite: { state.leavesExplicitCapturesToTheStore },
                pasteboard: pasteboard
            )

            do {
                _ = try await adapter.produceOCR("recognized text")
                XCTFail("Expected the store to refuse the capture in \(state)")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardHistoryModuleError,
                    .storeUnavailable,
                    "\(state)"
                )
            }
            XCTAssertEqual(
                pasteboard.string(forType: .string),
                "recognized text",
                "\(state)"
            )
        }
    }

    /// The stop-loss end to end: a capture taken while the migration is
    /// failed reaches only the pasteboard, so the retry still finds the empty
    /// store the migration needs. Once ready, captures are recorded again,
    /// with passive monitoring off.
    func testCaptureWhileTheMigrationFailedDoesNotBlockTheRetry()
        async throws
    {
        let fixture = try Fixture(testCase: self)
        let legacyPayloads = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardProductionLegacy-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: legacyPayloads,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(legacyPayloads)
        let defaults = try makeDefaults()
        ClipboardPreferences.setMonitoringEnabled(false, in: defaults)
        let legacyID = UUID()
        var preparationCount = 0
        var migrationFinished = false
        let lifecycle = ClipboardHistoryLifecycle(
            module: fixture.module,
            defaults: defaults,
            migrationPreparation: {
                preparationCount += 1
                // The app's recovery mode: the store is open, but the
                // snapshot could not be prepared on the first attempt.
                guard preparationCount > 1 else {
                    throw ClipboardHistoryLegacySourceError.incompleteSnapshot
                }
                return .proceed
            },
            legacyCleanupState: {
                migrationFinished ? .completed : .incomplete
            },
            legacyPayloadDirectory: { legacyPayloads },
            migrationRequest: {
                ClipboardHistoryLegacyMigrationRequest(
                    transfer: ClipboardHistoryLegacyTransfer(
                        entries: [
                            ClipboardHistoryLegacyEntry(
                                id: legacyID,
                                kind: .text,
                                text: "legacy text",
                                fileName: nil,
                                colorHex: nil,
                                previewText: "legacy text",
                                capturedAt: Date(timeIntervalSince1970: 1_000),
                                richData: nil,
                                richType: nil,
                                source: .unknown,
                                isFavorite: false,
                                tagIDs: [],
                                files: []
                            )
                        ],
                        tags: [],
                        categoryOrder: [],
                        retentionPeriod: .unlimited
                    ),
                    payloadDirectory: legacyPayloads
                )
            },
            finishMigration: {
                migrationFinished = true
            }
        )
        let adapter = ClipboardProductionAdapter(
            module: fixture.module,
            selfWrites: fixture.module.pasteboardSelfWrites,
            admitsHistoryWrite: { lifecycle.admitsExplicitCaptures },
            pasteboard: fixture.pasteboard
        )

        addTeardownBlock {
            await lifecycle.awaitCurrentOperationForTesting()
            await lifecycle.stop()
        }
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)
        let early = try await adapter.produceOCR("captured while failed")
        XCTAssertNil(early.capture)
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "captured while failed"
        )

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        let migrated = try await fixture.module.page(.init())
        XCTAssertEqual(migrated.entries.map(\.id.value), [legacyID])

        let late = try await adapter.produceOCR("captured when ready")
        let recorded = try XCTUnwrap(late.capture)
        let page = try await fixture.module.page(.init())
        XCTAssertEqual(
            page.entries.map(\.id.value),
            [recorded.entryID.value, legacyID]
        )
        await lifecycle.stop()
    }

    private func makeDefaults() throws -> UserDefaults {
        makeTemporaryDefaults()
    }

    private static func makeImage() throws -> (NSImage, Data) {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        image.unlockFocus()
        return (image, try XCTUnwrap(image.pngData()))
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let module: ClipboardHistoryModule
    let pasteboard: NSPasteboard
    let adapter: ClipboardProductionAdapter

    init(
        testCase: XCTestCase,
        faults: Set<ClipboardHistoryFaultPoint> = [],
        admitsHistoryWrite: Bool = true
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardProduction-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        testCase.removeClipboardHistoryDirectoryAfterTest(directory)
        module = try testCase.trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: directory
                    .appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x42, count: 32),
                faultInjector: ClipboardHistoryFaultInjector(points: faults)
            )
        )
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "AnyDoor-ClipboardProduction-\(UUID().uuidString)"
            )
        )
        adapter = ClipboardProductionAdapter(
            module: module,
            selfWrites: module.pasteboardSelfWrites,
            admitsHistoryWrite: { admitsHistoryWrite },
            pasteboard: pasteboard
        )
    }
}

/// A Keychain item that always answers `result`, so the store never opens.
private struct FixedKeyStore: ClipboardHistoryMasterKeyStoring {
    let result: ClipboardHistoryMasterKeyResult

    func load() -> ClipboardHistoryMasterKeyResult { result }

    func create() -> ClipboardHistoryMasterKeyResult { result }

    func delete() -> ClipboardHistoryMasterKeyResult { result }
}
