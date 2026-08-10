import ClipboardHistory
import Foundation
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLifecycleTests: XCTestCase {
    func testPublishedRecoveryCleansSnapshotWithoutReadingLegacySource()
        async throws
    {
        let report = ClipboardHistoryLegacyMigrationReport(
            retainedEntryCount: 1,
            omittedExpiredEntryCount: 0,
            ownedPayloadCount: 0,
            redundantLegacyPayloadCount: 0
        )
        let probe = ClipboardLifecycleProbe(
            publicationState: .published(report)
        )
        let defaults = makeDefaults()
        var migrationRequestCount = 0
        var finishCount = 0
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            legacyCleanupState: { .incomplete },
            legacyPayloadDirectory: {
                FileManager.default.temporaryDirectory
            },
            migrationRequest: {
                migrationRequestCount += 1
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            },
            finishMigration: {
                finishCount += 1
            }
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(lifecycle.migrationReport, report)
        XCTAssertEqual(migrationRequestCount, 0)
        XCTAssertEqual(finishCount, 1)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .status,
                .monitoring(.migrationStarted),
                .publicationState,
                .cleanup,
                .monitoring(.migrationCompleted),
                .monitoring(.start),
            ]
        )
    }

    func testPendingSnapshotDeletionRetriesWithoutPublicationOrLegacyRead()
        async throws
    {
        let probe = ClipboardLifecycleProbe()
        let defaults = makeDefaults()
        var cleanupState =
            ClipboardHistoryLegacyCleanupState.snapshotDeletionPending
        var deletionAttempts = 0
        var migrationRequestCount = 0
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            legacyCleanupState: { cleanupState },
            migrationRequest: {
                migrationRequestCount += 1
                return try Self.emptyMigrationRequest()
            },
            retrySnapshotDeletion: {
                deletionAttempts += 1
                if deletionAttempts == 1 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                cleanupState = .completed
            }
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(deletionAttempts, 2)
        XCTAssertEqual(migrationRequestCount, 0)
        let events = await probe.recordedEvents()
        XCTAssertFalse(events.contains(.publicationState))
        XCTAssertFalse(events.contains(.migration))
        XCTAssertFalse(events.contains(.cleanup))
    }

    func testStorePermissionRecoveryResumesPublishedCleanupOnly()
        async throws
    {
        let report = ClipboardHistoryLegacyMigrationReport(
            retainedEntryCount: 2,
            omittedExpiredEntryCount: 0,
            ownedPayloadCount: 0,
            redundantLegacyPayloadCount: 0
        )
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .missingKey,
            becomesReadyOnRetry: true,
            publicationState: .published(report)
        )
        let defaults = makeDefaults()
        var migrationRequestCount = 0
        var finishCount = 0
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: defaults,
            legacyCleanupState: { .incomplete },
            legacyPayloadDirectory: {
                FileManager.default.temporaryDirectory
            },
            migrationRequest: {
                migrationRequestCount += 1
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            },
            finishMigration: {
                finishCount += 1
            }
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .storeUnavailable(.missingKey))

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(migrationRequestCount, 0)
        XCTAssertEqual(finishCount, 1)
        let events = await probe.recordedEvents()
        XCTAssertFalse(events.contains(.migration))
        XCTAssertEqual(
            events.filter { $0 == .cleanup }.count,
            1
        )
    }

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

    func testFailedResetCanBeConfirmedAgain() async throws {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .databaseCorrupt,
            resetFailuresRemaining: 1
        )
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationRequest: nil
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .resetFailed)

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let events = await probe.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .reset }.count, 2)
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
                .publicationState,
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
                .publicationState,
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
            events.suffix(8),
            [
                .reset,
                .status,
                .monitoring(.migrationStarted),
                .publicationState,
                .migration,
                .cleanup,
                .monitoring(.migrationCompleted),
                .monitoring(.start),
            ]
        )
    }

    /// Termination must not wait on a migration: its database work is not
    /// interruptible, and the cutover is crash-safe, so quitting mid-migration
    /// simply resumes next launch. Awaiting it would hang Quit for the whole
    /// first-launch conversion.
    func testStopReturnsWhileAMigrationIsStillInFlight() async {
        let probe = ClipboardLifecycleProbe()
        await probe.suspendNextMigration()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: { .incomplete },
            legacyPayloadDirectory: {
                FileManager.default.temporaryDirectory
            },
            migrationRequest: { try Self.emptyMigrationRequest() }
        )

        lifecycle.start()
        await probe.waitUntilMigrationStarts(count: 1)

        let stopped = CompletionFlag()
        Task {
            await lifecycle.stop()
            await stopped.set()
        }
        let deadline = Date().addingTimeInterval(2)
        while await !stopped.isSet(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let returned = await stopped.isSet()
        await probe.resumeMigration()
        XCTAssertTrue(
            returned,
            "stop() must not await the suspended migration"
        )
        let events = await probe.recordedEvents()
        XCTAssertTrue(events.contains(.monitoring(.stop)))
    }

    /// A locked keychain is documented as self-recovering: unlocking it has to
    /// resume capture without a relaunch. Nothing notifies the app, so the
    /// lifecycle polls the lock state and retries the store on the first unlock.
    func testALockedKeychainResumesOnUnlockWithoutRelaunch() async throws {
        let probe = ClipboardLifecycleProbe(
            availability: .paused,
            reason: .keychainLocked,
            becomesReadyOnRetry: true
        )
        let unlockState = KeychainUnlockFlag(unlocked: false)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: { .completed },
            migrationRequest: nil,
            isKeychainUnlocked: { unlockState.read() },
            keychainUnlockPollInterval: .milliseconds(10)
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .paused(.keychainLocked))

        unlockState.set(true)
        let resumed = await Self.wait(untilTrue: {
            lifecycle.state == .ready
        })

        XCTAssertTrue(
            resumed,
            "unlocking the keychain must resume the store on its own"
        )
        let events = await probe.recordedEvents()
        XCTAssertTrue(events.contains(.retryStore))
    }

    func testLockingKeychainWhileReadyPausesCaptureAndResumesFromBaseline()
        async throws
    {
        let probe = ClipboardLifecycleProbe(
            becomesReadyOnRetry: true
        )
        let unlockState = KeychainUnlockFlag(unlocked: true)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: { .completed },
            migrationRequest: nil,
            isKeychainUnlocked: { unlockState.read() },
            keychainUnlockPollInterval: .milliseconds(10)
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)

        unlockState.set(false)
        let paused = await Self.wait(untilTrue: {
            lifecycle.state == .paused(.keychainLocked)
        })
        XCTAssertTrue(paused, "locking the keychain must pause capture")

        unlockState.set(true)
        let resumed = await Self.wait(untilTrue: {
            lifecycle.state == .ready
        })
        XCTAssertTrue(resumed, "unlocking must establish a new baseline")

        let events = await probe.recordedEvents()
        XCTAssertTrue(events.contains(.monitoring(.stop)))
        XCTAssertGreaterThanOrEqual(
            events.filter { $0 == .monitoring(.start) }.count,
            2
        )
    }

    /// In practice a keychain locks because the *screen* locked, and on this
    /// path the login keychain's own lock flag is not a reliable witness — a
    /// GUI app can be handed the key while `SecKeychainGetStatus` still reports
    /// locked. So the screen-unlock notification resumes the store on its own,
    /// without waiting for the poll to agree.
    func testAScreenUnlockResumesTheStoreWithoutWaitingForThePoll() async throws
    {
        let probe = ClipboardLifecycleProbe(
            availability: .paused,
            reason: .keychainLocked,
            becomesReadyOnRetry: true
        )
        let notifications = NotificationCenter()
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: { .completed },
            migrationRequest: nil,
            // The poll never fires: only the notification can resume this.
            isKeychainUnlocked: { false },
            keychainUnlockPollInterval: .seconds(60),
            unlockNotifications: notifications
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .paused(.keychainLocked))

        notifications.post(
            name: ClipboardHistoryLifecycle.screenUnlockNotification,
            object: nil
        )
        let resumed = await Self.wait(untilTrue: {
            lifecycle.state == .ready
        })

        XCTAssertTrue(
            resumed,
            "a screen unlock must resume the store on its own"
        )
        let events = await probe.recordedEvents()
        XCTAssertTrue(events.contains(.retryStore))
    }

    /// The poll must never retry on a guess: an undeterminable lock state reads
    /// as still locked, and retrying on a locked keychain would re-raise the
    /// password prompt every few seconds.
    func testAStillLockedKeychainIsNeverRetried() async throws {
        let probe = ClipboardLifecycleProbe(
            availability: .paused,
            reason: .keychainLocked,
            becomesReadyOnRetry: true
        )
        let unlockState = KeychainUnlockFlag(unlocked: nil)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: { .completed },
            migrationRequest: nil,
            isKeychainUnlocked: { unlockState.read() },
            keychainUnlockPollInterval: .milliseconds(10)
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        unlockState.set(false)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(lifecycle.state, .paused(.keychainLocked))
        let events = await probe.recordedEvents()
        XCTAssertFalse(events.contains(.retryStore))
        await lifecycle.stop()
    }

    private static func wait(
        untilTrue predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
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
    case publicationState
    case migration
    case cleanup
    case monitoring(ClipboardHistoryMonitoringCommand)
    case reset
}

/// The lock-state probe is synchronous, so the test's stand-in needs its own
/// lock rather than actor isolation.
private final class KeychainUnlockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var unlocked: Bool?

    init(unlocked: Bool?) {
        self.unlocked = unlocked
    }

    func set(_ value: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        unlocked = value
    }

    func read() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return unlocked
    }
}

private actor CompletionFlag {
    private var value = false

    func set() {
        value = true
    }

    func isSet() -> Bool {
        value
    }
}

private actor ClipboardLifecycleProbe {
    private(set) var events: [ClipboardLifecycleEvent] = []
    private(set) var migrationCount = 0
    private(set) var migrationEntryCounts: [Int] = []
    private var availability: ClipboardHistoryStatus.Availability
    private var reason: ClipboardHistoryStatus.AvailabilityReason?
    private var migrationFailuresRemaining: Int
    private var cleanupFailuresRemaining: Int
    private var resetFailuresRemaining: Int
    private let becomesReadyOnRetry: Bool
    private let publicationState:
        ClipboardHistoryLegacyMigrationPublicationState
    private var shouldSuspendNextMigration = false
    private var migrationContinuation: CheckedContinuation<Void, Never>?

    init(
        availability: ClipboardHistoryStatus.Availability = .ready,
        reason: ClipboardHistoryStatus.AvailabilityReason? = nil,
        migrationFailuresRemaining: Int = 0,
        cleanupFailuresRemaining: Int = 0,
        resetFailuresRemaining: Int = 0,
        becomesReadyOnRetry: Bool = false,
        publicationState:
            ClipboardHistoryLegacyMigrationPublicationState = .notPublished
    ) {
        self.availability = availability
        self.reason = reason
        self.migrationFailuresRemaining = migrationFailuresRemaining
        self.cleanupFailuresRemaining = cleanupFailuresRemaining
        self.resetFailuresRemaining = resetFailuresRemaining
        self.becomesReadyOnRetry = becomesReadyOnRetry
        self.publicationState = publicationState
    }

    nonisolated var operations: ClipboardHistoryLifecycleOperations {
        ClipboardHistoryLifecycleOperations(
            status: {
                await self.recordStatus()
            },
            setMonitoring: { command, _ in
                await self.recordMonitoring(command)
            },
            legacyMigrationPublicationState: {
                try await self.recordPublicationState()
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

    private func recordPublicationState() throws
        -> ClipboardHistoryLegacyMigrationPublicationState
    {
        events.append(.publicationState)
        return publicationState
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
        if resetFailuresRemaining > 0 {
            resetFailuresRemaining -= 1
            throw ClipboardHistoryModuleError.resetFailed
        }
        availability = .ready
        reason = nil
    }
}

@MainActor
final class ClipboardLifecycleRecoveryTests: XCTestCase {
    /// A confirmed reset that fails used to render the storeUnavailable line,
    /// so the destructive button looked like it had done nothing and invited a
    /// second press. Every stalled state must name itself.
    func testEveryStalledStateHasItsOwnLine() {
        let states: [ClipboardHistoryLifecycleState] = [
            .migrationFailed,
            .storeUnavailable(nil),
            .resetFailed,
            .paused(.keychainLocked),
        ]
        let messages = states.compactMap {
            ClipboardLifecycleRecovery(state: $0)?.message
        }
        XCTAssertEqual(messages.count, states.count)
        XCTAssertEqual(Set(messages).count, states.count)
    }

    /// Reset is the one irreversible way out, so it is offered only where it is
    /// the actual remedy — never for a keychain lock that resolves on unlock.
    func testResetIsOfferedOnlyWhereItIsTheRemedy() {
        XCTAssertEqual(
            ClipboardLifecycleRecovery(state: .storeUnavailable(nil))?
                .includesReset,
            true
        )
        XCTAssertEqual(
            ClipboardLifecycleRecovery(state: .resetFailed)?.includesReset,
            true
        )
        XCTAssertEqual(
            ClipboardLifecycleRecovery(state: .paused(.keychainLocked))?
                .includesReset,
            false
        )
        XCTAssertEqual(
            ClipboardLifecycleRecovery(state: .migrationFailed)?.includesReset,
            false
        )
    }

    func testHealthyAndTransientStatesOfferNoRecoverySection() {
        XCTAssertNil(ClipboardLifecycleRecovery(state: .ready))
        XCTAssertNil(ClipboardLifecycleRecovery(state: .preparing))
        XCTAssertNil(ClipboardLifecycleRecovery(state: .migrating))
    }
}
