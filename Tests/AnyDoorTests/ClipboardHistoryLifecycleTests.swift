import ClipboardHistory
import Foundation
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLifecycleTests: XCTestCase {
    func testCompletedCutoverLaunchSkipsLegacyRequestAndMigration()
        async throws
    {
        let probe = ClipboardLifecycleProbe()
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: nil
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        let migrationCount = await probe.recordedMigrationCount()
        let events = await probe.recordedEvents()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(migrationCount, 0)
        XCTAssertEqual(
            events,
            [
                .status,
                .monitoring(.start),
            ]
        )
    }

    func testConfirmedResetAfterCompletedCutoverDoesNotRemigrate()
        async throws
    {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .databaseCorrupt
        )
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: nil
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()

        let migrationCount = await probe.recordedMigrationCount()
        let events = await probe.recordedEvents()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(migrationCount, 0)
        XCTAssertEqual(
            events,
            [
                .status,
                .reset,
                .status,
                .monitoring(.start),
            ]
        )
    }

    func testStartupMigratesBeforeStartingPassiveMonitoring() async throws {
        let probe = ClipboardLifecycleProbe()
        let defaults = makeDefaults()
        ClipboardPreferences.setMonitoringEnabled(true, in: defaults)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .status,
                .monitoring(.migrationStarted),
                .migration,
                .cleanup,
                .monitoring(.migrationCompleted),
                .monitoring(.start),
            ]
        )
    }

    func testMigrationFailureStaysNonDestructiveUntilRetrySucceeds()
        async throws
    {
        let probe = ClipboardLifecycleProbe(migrationFailuresRemaining: 1)
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)
        let failedEvents = await probe.recordedEvents()
        XCTAssertFalse(failedEvents.contains(.monitoring(.start)))

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let retriedEvents = await probe.recordedEvents()
        XCTAssertEqual(
            retriedEvents.filter { $0 == .monitoring(.start) }.count,
            1
        )
    }

    func testCleanupFailureRetainsLegacySourceUntilRetrySucceeds()
        async throws
    {
        let probe = ClipboardLifecycleProbe(cleanupFailuresRemaining: 1)
        let defaults = makeDefaults()
        var finishCount = 0
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest,
            finishMigration: {
                finishCount += 1
            }
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .migrationFailed)
        XCTAssertEqual(finishCount, 0)
        let failedEvents = await probe.recordedEvents()
        XCTAssertFalse(failedEvents.contains(.monitoring(.start)))

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(finishCount, 1)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events.filter { $0 == .cleanup }.count,
            2
        )
    }

    func testStoreUnavailableRetryReopensBeforeMigrationAndMonitoring()
        async throws
    {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .missingKey,
            becomesReadyOnRetry: true
        )
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .storeUnavailable(.missingKey))

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .status,
                .retryStore,
                .status,
                .monitoring(.migrationStarted),
                .migration,
                .cleanup,
                .monitoring(.migrationCompleted),
                .monitoring(.start),
            ]
        )
    }

    func testRepeatedRetryWhileMigrationIsRunningDoesNotOverlap()
        async throws
    {
        let probe = ClipboardLifecycleProbe(migrationFailuresRemaining: 1)
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        await probe.suspendNextMigration()

        lifecycle.retry()
        lifecycle.retry()
        await probe.waitUntilMigrationStarts(count: 2)
        await probe.resumeMigration()
        await lifecycle.awaitCurrentOperationForTesting()

        let migrationCount = await probe.recordedMigrationCount()
        XCTAssertEqual(migrationCount, 2)
        XCTAssertEqual(lifecycle.state, .ready)
    }

    func testMonitoringPreferenceChangedBeforeReadyNeverStartsEarly()
        async throws
    {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .databaseCorrupt
        )
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: Self.emptyMigrationRequest
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        await lifecycle.setMonitoringEnabled(true)

        XCTAssertTrue(
            ClipboardPreferences.monitoringEnabled(from: defaults)
        )
        let events = await probe.recordedEvents()
        XCTAssertFalse(events.contains(.monitoring(.start)))
    }

    func testConfirmedResetPublishesEmptyMigrationBeforeMonitoring()
        async throws
    {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .databaseCorrupt
        )
        let defaults = makeDefaults()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            migrationRequest: {
                ClipboardHistoryLegacyMigrationRequest(
                    transfer: ClipboardHistoryLegacyTransfer(
                        entries: [
                            ClipboardHistoryLegacyEntry(
                                id: UUID(),
                                kind: .text,
                                text: "must not return after reset",
                                fileName: nil,
                                colorHex: nil,
                                previewText: nil,
                                capturedAt: Date(),
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
                        retentionPeriod: .thirtyDays
                    ),
                    payloadDirectory:
                        FileManager.default.temporaryDirectory
                )
            }
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let entryCounts = await probe.recordedMigrationEntryCounts()
        XCTAssertEqual(entryCounts, [0])
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events.suffix(7),
            [
                .reset,
                .status,
                .monitoring(.migrationStarted),
                .migration,
                .cleanup,
                .monitoring(.migrationCompleted),
                .monitoring(.start),
            ]
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ClipboardHistoryLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func emptyMigrationRequest()
        throws -> ClipboardHistoryLegacyMigrationRequest
    {
        ClipboardHistoryLegacyMigrationRequest(
            transfer: ClipboardHistoryLegacyTransfer(
                entries: [],
                tags: [],
                categoryOrder: [],
                retentionPeriod: .thirtyDays
            ),
            payloadDirectory: FileManager.default.temporaryDirectory
        )
    }
}

private enum ClipboardLifecycleEvent: Equatable, Sendable {
    case status
    case retryStore
    case migration
    case cleanup
    case monitoring(ClipboardHistoryMonitoringCommand)
    case reset
}

private actor ClipboardLifecycleProbe {
    private(set) var events: [ClipboardLifecycleEvent] = []
    private(set) var migrationCount = 0
    private(set) var migrationEntryCounts: [Int] = []
    private var availability: ClipboardHistoryStatus.Availability
    private var reason: ClipboardHistoryStatus.AvailabilityReason?
    private var migrationFailuresRemaining: Int
    private var cleanupFailuresRemaining: Int
    private let becomesReadyOnRetry: Bool
    private var shouldSuspendNextMigration = false
    private var migrationContinuation: CheckedContinuation<Void, Never>?

    init(
        availability: ClipboardHistoryStatus.Availability = .ready,
        reason: ClipboardHistoryStatus.AvailabilityReason? = nil,
        migrationFailuresRemaining: Int = 0,
        cleanupFailuresRemaining: Int = 0,
        becomesReadyOnRetry: Bool = false
    ) {
        self.availability = availability
        self.reason = reason
        self.migrationFailuresRemaining = migrationFailuresRemaining
        self.cleanupFailuresRemaining = cleanupFailuresRemaining
        self.becomesReadyOnRetry = becomesReadyOnRetry
    }

    nonisolated var operations: ClipboardHistoryLifecycleOperations {
        ClipboardHistoryLifecycleOperations(
            status: {
                await self.recordStatus()
            },
            setMonitoring: { command, _ in
                await self.recordMonitoring(command)
            },
            migrate: { request in
                try await self.migrate(request)
            },
            cleanupLegacyPayloads: { _ in
                try await self.cleanupLegacyPayloads()
            },
            retryStore: {
                await self.retryStore()
            },
            resetStore: {
                try await self.resetStore()
            }
        )
    }

    func suspendNextMigration() {
        shouldSuspendNextMigration = true
    }

    func recordedEvents() -> [ClipboardLifecycleEvent] {
        events
    }

    func recordedMigrationCount() -> Int {
        migrationCount
    }

    func recordedMigrationEntryCounts() -> [Int] {
        migrationEntryCounts
    }

    func resumeMigration() {
        migrationContinuation?.resume()
        migrationContinuation = nil
    }

    func waitUntilMigrationStarts(count: Int) async {
        while migrationCount < count {
            await Task.yield()
        }
    }

    private func recordStatus() -> ClipboardHistoryStatus {
        events.append(.status)
        return ClipboardHistoryStatus(
            availability: availability,
            reason: reason,
            isMonitoring: false
        )
    }

    private func recordMonitoring(
        _ command: ClipboardHistoryMonitoringCommand
    ) -> ClipboardHistoryStatus {
        events.append(.monitoring(command))
        return ClipboardHistoryStatus(
            availability: availability,
            reason: reason,
            isMonitoring: command == .start
        )
    }

    private func migrate(
        _ request: ClipboardHistoryLegacyMigrationRequest
    ) async throws
        -> ClipboardHistoryLegacyMigrationOutcome
    {
        events.append(.migration)
        migrationCount += 1
        migrationEntryCounts.append(request.transfer.entries.count)
        if shouldSuspendNextMigration {
            shouldSuspendNextMigration = false
            await withCheckedContinuation { continuation in
                migrationContinuation = continuation
            }
        }
        if migrationFailuresRemaining > 0 {
            migrationFailuresRemaining -= 1
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        return .published(
            ClipboardHistoryLegacyMigrationReport(
                retainedEntryCount: 0,
                omittedExpiredEntryCount: 0,
                ownedPayloadCount: 0,
                redundantLegacyPayloadCount: 0
            )
        )
    }

    private func retryStore() {
        events.append(.retryStore)
        if becomesReadyOnRetry {
            availability = .ready
            reason = nil
        }
    }

    private func cleanupLegacyPayloads() throws
        -> ClipboardHistoryLegacyCleanupReport
    {
        events.append(.cleanup)
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw ClipboardHistoryModuleError.legacyCleanupFailed
        }
        return ClipboardHistoryLegacyCleanupReport(
            removedPayloadCount: 0,
            alreadyMissingPayloadCount: 0,
            pendingPayloadCount: 0,
            canDeleteLegacyRows: true
        )
    }

    private func resetStore() async throws {
        events.append(.reset)
        availability = .ready
        reason = nil
    }
}
