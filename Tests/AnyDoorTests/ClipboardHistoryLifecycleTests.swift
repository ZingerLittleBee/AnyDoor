import ClipboardHistory
import Foundation
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLifecycleTests: XCTestCase {
    func testMigrationPreparationFailureRetriesWithoutTouchingStore()
        async throws
    {
        let probe = ClipboardLifecycleProbe()
        var preparationAttempts = 0
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationPreparation: {
                preparationAttempts += 1
                if preparationAttempts == 1 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                return .suspendForRelaunch
            },
            migrationRequest: nil
        )

        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .migrationFailed)
        XCTAssertEqual(preparationAttempts, 1)
        let failedEvents = await probe.recordedEvents()
        XCTAssertEqual(failedEvents, [])

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .preparing)
        XCTAssertEqual(preparationAttempts, 2)
        let retriedEvents = await probe.recordedEvents()
        XCTAssertEqual(retriedEvents, [])
    }

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

    /// A store that could not move to its new folder is intact, so a
    /// confirmed reset is ignored rather than destroying it, and a retry
    /// finishes the move.
    func testRelocationFailureNeverResetsAndRetryRecovers() async throws {
        let probe = ClipboardLifecycleProbe(
            availability: .unavailable,
            reason: .storeRelocationFailed,
            becomesReadyOnRetry: true
        )
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationRequest: nil,
            isKeychainUnlocked: { true }
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(
            lifecycle.state,
            .storeUnavailable(.storeRelocationFailed)
        )

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(
            lifecycle.state,
            .storeUnavailable(.storeRelocationFailed)
        )
        let afterReset = await probe.recordedEvents()
        XCTAssertEqual(afterReset, [.status])

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [.status, .retryStore, .status, .monitoring(.start)]
        )
        await lifecycle.stop()
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

    /// An explicit capture taken before the cutover would leave the store
    /// non-empty, and the pre-v2 migration refuses such a store for good, so
    /// captures wait while the lifecycle prepares, migrates or has failed.
    /// A confirmed cutover never comes undone: a later retry that passes
    /// through `.preparing` again keeps admitting them.
    func testExplicitCapturesWaitOnlyForTheFirstConfirmedCutover()
        async throws
    {
        let probe = ClipboardLifecycleProbe(migrationFailuresRemaining: 1)
        let unlockState = KeychainUnlockFlag(unlocked: true)
        var migrationFinished = false
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            legacyCleanupState: {
                migrationFinished ? .completed : .incomplete
            },
            migrationRequest: Self.emptyMigrationRequest,
            finishMigration: {
                migrationFinished = true
            },
            isKeychainUnlocked: { unlockState.read() },
            keychainUnlockPollInterval: .milliseconds(10),
            unlockNotifications: NotificationCenter()
        )
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)

        lifecycle.start()
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)

        lifecycle.retry()
        XCTAssertEqual(lifecycle.state, .preparing)
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertTrue(lifecycle.admitsExplicitCaptures)

        unlockState.set(false)
        let paused = await Self.wait(untilTrue: {
            lifecycle.state == .paused(.keychainLocked)
        })
        XCTAssertTrue(paused)
        // An undeterminable lock state never retries on its own.
        unlockState.set(nil)
        lifecycle.retry()
        XCTAssertEqual(lifecycle.state, .preparing)
        XCTAssertTrue(lifecycle.admitsExplicitCaptures)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        let migrationCount = await probe.recordedMigrationCount()
        XCTAssertEqual(migrationCount, 2)
        await lifecycle.stop()
    }

    /// A 4.2 release recorded explicit captures while its migration was
    /// pending or had failed, and the migration refuses a store that holds
    /// entries. The lifecycle names the count and waits: a retry asks the
    /// store again, a reset is ignored, captures stay held back, and passive
    /// monitoring never starts.
    func testAStoreWithEntriesBlocksTheMigrationWithItsCount() async throws {
        let probe = ClipboardLifecycleProbe(storeEntryCount: 3)
        let defaults = makeDefaults()
        ClipboardPreferences.setMonitoringEnabled(true, in: defaults)
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
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 3))
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)

        lifecycle.resetConfirmed()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 3))

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 3))
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)

        XCTAssertEqual(finishCount, 0)
        let confirmations = await probe.recordedMigrationConfirmations()
        XCTAssertEqual(confirmations, [nil, nil])
        let remaining = await probe.recordedStoreEntryCount()
        XCTAssertEqual(remaining, 3)
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .status,
                .monitoring(.migrationStarted),
                .publicationState,
                .migration,
                .status,
                .monitoring(.migrationStarted),
                .publicationState,
                .migration,
            ]
        )
    }

    /// Confirming the discard migrates in the same pass, so the cutover
    /// completes and passive monitoring starts as after any migration.
    func testAConfirmedDiscardMigratesAndCompletesTheCutover() async throws {
        let probe = ClipboardLifecycleProbe(storeEntryCount: 2)
        let defaults = makeDefaults()
        ClipboardPreferences.setMonitoringEnabled(true, in: defaults)
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
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 2))

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 2)
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertTrue(lifecycle.admitsExplicitCaptures)
        XCTAssertEqual(finishCount, 1)
        let confirmations = await probe.recordedMigrationConfirmations()
        XCTAssertEqual(confirmations, [nil, 2])
        let events = await probe.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .status,
                .monitoring(.migrationStarted),
                .publicationState,
                .migration,
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

    /// The confirmation carries the count the user was shown. A store that
    /// no longer holds exactly that many discards nothing, and the lifecycle
    /// asks again with the new count.
    func testAStaleDiscardConfirmationAsksAgainWithTheNewCount()
        async throws
    {
        let probe = ClipboardLifecycleProbe(storeEntryCount: 3)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationRequest: Self.emptyMigrationRequest
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 3))
        await probe.setStoreEntryCount(2)

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 3)
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 2))
        let remaining = await probe.recordedStoreEntryCount()
        XCTAssertEqual(remaining, 2)

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 2)
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        let confirmations = await probe.recordedMigrationConfirmations()
        XCTAssertEqual(confirmations, [nil, 3, 2])
    }

    /// A discard that fails keeps the entries, so the failure retries like
    /// any other and comes back to the same confirmation.
    func testAFailedDiscardComesBackToTheSameConfirmation() async throws {
        let probe = ClipboardLifecycleProbe(
            storeEntryCount: 2,
            migrationFailuresRemaining: 1
        )
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationRequest: Self.emptyMigrationRequest
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 2))

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 2)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)
        XCTAssertFalse(lifecycle.admitsExplicitCaptures)
        let remaining = await probe.recordedStoreEntryCount()
        XCTAssertEqual(remaining, 2)

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationBlocked(entryCount: 2))

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 2)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        let confirmations = await probe.recordedMigrationConfirmations()
        XCTAssertEqual(confirmations, [nil, 2, nil, 2])
    }

    /// Only a blocked migration discards: a failed one has nothing to
    /// discard, and a ready store holds history the user kept.
    func testADiscardOutsideTheBlockedStateIsIgnored() async throws {
        let probe = ClipboardLifecycleProbe(migrationFailuresRemaining: 1)
        let lifecycle = ClipboardHistoryLifecycle(
            operations: probe.operations,
            defaults: makeDefaults(),
            migrationRequest: Self.emptyMigrationRequest
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 1)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .migrationFailed)

        lifecycle.retry()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)

        lifecycle.discardBlockingEntriesConfirmed(entryCount: 1)
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        let confirmations = await probe.recordedMigrationConfirmations()
        XCTAssertEqual(confirmations, [nil, nil])
    }

    /// Failures are logged publicly, so a name must say what failed without
    /// a path from an error's payload or a Foundation description.
    func testFailureLogNamesCarryNoPaths() {
        let path = "/Users/someone/Library/ClipboardHistory/secret.png"
        XCTAssertEqual(
            ClipboardHistoryLifecycle.logName(
                of: ClipboardHistoryLegacySourceError.incompleteSnapshot
            ),
            "ClipboardHistoryLegacySourceError.incompleteSnapshot"
        )
        XCTAssertEqual(
            ClipboardHistoryLifecycle.logName(
                of: ClipboardHistoryLegacySourceError
                    .cutoverMarkerPersistenceFailed(EACCES)
            ),
            "ClipboardHistoryLegacySourceError.cutoverMarkerPersistenceFailed(13)"
        )
        XCTAssertEqual(
            ClipboardHistoryLifecycle.logName(
                of: ClipboardHistoryModuleError.legacyFileRestoreCollision(
                    URL(fileURLWithPath: path)
                )
            ),
            "ClipboardHistoryModuleError.legacyFileRestoreCollision"
        )
        XCTAssertEqual(
            ClipboardHistoryLifecycle.logName(
                of: CocoaError(
                    .fileWriteNoPermission,
                    userInfo: [NSFilePathErrorKey: path]
                )
            ),
            "\(NSCocoaErrorDomain) \(CocoaError.fileWriteNoPermission.rawValue)"
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
    private(set) var migrationConfirmations: [Int?] = []
    private var availability: ClipboardHistoryStatus.Availability
    private var reason: ClipboardHistoryStatus.AvailabilityReason?
    /// Entries already in the store, which the migration refuses unless a
    /// discard of exactly that many is confirmed.
    private var storeEntryCount: Int
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
        storeEntryCount: Int = 0,
        migrationFailuresRemaining: Int = 0,
        cleanupFailuresRemaining: Int = 0,
        resetFailuresRemaining: Int = 0,
        becomesReadyOnRetry: Bool = false,
        publicationState:
            ClipboardHistoryLegacyMigrationPublicationState = .notPublished
    ) {
        self.availability = availability
        self.reason = reason
        self.storeEntryCount = storeEntryCount
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
            migrate: { request, confirmedEntryCount in
                try await self.migrate(
                    request,
                    confirmedEntryCount: confirmedEntryCount
                )
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

    func recordedMigrationConfirmations() -> [Int?] {
        migrationConfirmations
    }

    func recordedStoreEntryCount() -> Int {
        storeEntryCount
    }

    func setStoreEntryCount(_ count: Int) {
        storeEntryCount = count
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
        _ request: ClipboardHistoryLegacyMigrationRequest,
        confirmedEntryCount: Int?
    ) async throws
        -> ClipboardHistoryLegacyMigrationOutcome
    {
        events.append(.migration)
        migrationCount += 1
        migrationEntryCounts.append(request.transfer.entries.count)
        migrationConfirmations.append(confirmedEntryCount)
        if shouldSuspendNextMigration {
            shouldSuspendNextMigration = false
            await withCheckedContinuation { continuation in
                migrationContinuation = continuation
            }
        }
        // As the module does: entries in the store refuse the migration
        // unless the confirmed count still matches, and a failure after that
        // check leaves them in place.
        if storeEntryCount > 0, confirmedEntryCount != storeEntryCount {
            throw ClipboardHistoryModuleError.legacyMigrationStoreNotEmpty(
                entryCount: storeEntryCount
            )
        }
        if migrationFailuresRemaining > 0 {
            migrationFailuresRemaining -= 1
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        storeEntryCount = 0
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
            .migrationBlocked(entryCount: 2),
            .storeUnavailable(nil),
            .storeUnavailable(.storeRelocationFailed),
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

    /// A store that could not move out of the pre-v2 folder is intact, and
    /// the key was never touched: Reset would only destroy it, so the line
    /// points at Retry alone.
    func testRelocationFailureOffersRetryWithoutReset() {
        let recovery = ClipboardLifecycleRecovery(
            state: .storeUnavailable(.storeRelocationFailed)
        )
        XCTAssertEqual(recovery?.message, .settingsClipboardRelocationFailed)
        XCTAssertEqual(recovery?.includesReset, false)
    }

    /// Discarding is offered only for a blocked migration, with the count the
    /// confirmation shows. A reset there would discard the pre-upgrade history
    /// too, so it is not offered.
    func testOnlyABlockedMigrationOffersTheDiscard() {
        let blocked = ClipboardLifecycleRecovery(
            state: .migrationBlocked(entryCount: 4)
        )
        XCTAssertEqual(blocked?.message, .settingsClipboardMigrationBlocked)
        XCTAssertEqual(blocked?.discardableEntryCount, 4)
        XCTAssertEqual(blocked?.includesReset, false)
        let others: [ClipboardHistoryLifecycleState] = [
            .migrationFailed,
            .storeUnavailable(nil),
            .storeUnavailable(.storeRelocationFailed),
            .resetFailed,
            .paused(.keychainLocked),
        ]
        for state in others {
            let recovery = ClipboardLifecycleRecovery(state: state)
            XCTAssertNotNil(recovery, "\(state)")
            XCTAssertNil(recovery?.discardableEntryCount, "\(state)")
        }
    }

    func testHealthyAndTransientStatesOfferNoRecoverySection() {
        XCTAssertNil(ClipboardLifecycleRecovery(state: .ready))
        XCTAssertNil(ClipboardLifecycleRecovery(state: .preparing))
        XCTAssertNil(ClipboardLifecycleRecovery(state: .migrating))
    }
}
