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
        let transport = UnavailableLifecycleSyncCloud()
        let services = ClipboardSyncServices(transport: transport, keys: UnavailableLifecycleSyncKeys(), pollingInterval: nil)
        let first = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory,
            keyStore: LifecycleSyncLocalKey(), syncServices: services
        ))
        try await first.setSyncEnabled(true)
        try await first.closeStoreForTesting()
        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory,
            keyStore: LifecycleSyncLocalKey(), syncServices: services
        ))
        let accountReadsBeforeMigration = await transport.readCount()
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
        XCTAssertEqual(waiting.phase, .capabilityUnavailable, "The previous fault remains visible before resuming")
        let readsWhileMigrationFailed = await transport.readCount()
        XCTAssertEqual(readsWhileMigrationFailed, accountReadsBeforeMigration)

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let resumed = await reopened.syncStatus()
        XCTAssertEqual(resumed.phase, .capabilityUnavailable)
        let resumedReads = await transport.readCount()
        XCTAssertEqual(resumedReads, accountReadsBeforeMigration + 1)
        await lifecycle.stop()
        let stopped = await reopened.syncStatus()
        XCTAssertTrue(stopped.isEnabled, "Quitting does not revoke device participation")
        let history = await reopened.status()
        XCTAssertFalse(history.isMonitoring)
    }
}

private struct LifecycleSyncLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x52, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private struct UnavailableLifecycleSyncKeys: ClipboardSyncKeyStoring {
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
}

private actor UnavailableLifecycleSyncCloud: ClipboardSyncTransport {
    private var reads = 0
    func readCount() -> Int { reads }
    func account() throws -> ClipboardSyncAccount {
        reads += 1
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func control(for account: ClipboardSyncAccount) throws -> ClipboardSyncControl? {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) throws -> ClipboardSyncChanges {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) throws -> Data {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func cancel() {}
}
