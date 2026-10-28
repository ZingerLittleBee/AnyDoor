import AppKit
import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncLifecycleTests: XCTestCase {
    func testStoredParticipationResumesOnlyAfterMigrationIsReady()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(directory)
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let key = Data(repeating: 0x52, count: 32)
        let first = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: databaseURL,
            databaseKey: key
        ))
        try await first.setSyncEnabled(true)
        try await first.closeStoreForTesting()
        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: databaseURL,
            databaseKey: key
        ))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardSyncLifecycleTests-\(UUID().uuidString)")
        )
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        await reopened.installCaptureMonitorForTesting(ClipboardHistoryCaptureMonitor(
            module: reopened,
            pasteboard: pasteboard,
            sourceProvider: { nil },
            isKeychainUnlocked: { true },
            installsSystemObservers: false
        ))
        let defaults = makeTemporaryDefaults()
        ClipboardPreferences.setMonitoringEnabled(false, in: defaults)
        var preparationAttempts = 0
        let lifecycle = ClipboardHistoryLifecycle(
            module: reopened,
            defaults: defaults,
            migrationPreparation: {
                preparationAttempts += 1
                if preparationAttempts == 1 {
                    throw CocoaError(.fileReadNoPermission)
                }
                return .proceed
            },
            migrationRequest: nil
        )
        addTeardownBlock { await lifecycle.stop() }

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .migrationFailed)
        let waiting = await reopened.syncStatus()
        XCTAssertTrue(waiting.isEnabled)
        XCTAssertEqual(waiting.phase, .connecting)

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let resumed = await reopened.syncStatus()
        XCTAssertEqual(resumed.phase, .capabilityUnavailable)
        await lifecycle.stop()
        let stopped = await reopened.syncStatus()
        XCTAssertTrue(stopped.isEnabled, "Quitting does not revoke device participation")
        let history = await reopened.status()
        XCTAssertFalse(history.isMonitoring)
    }
}
