import Darwin
import Foundation
import GRDB
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryRetentionTests: XCTestCase {
    func testRetentionOffersEveryPresetAndDefaultsToThirtyDays() async throws {
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule()

        XCTAssertEqual(
            ClipboardHistoryRetentionPeriod.allCases,
            [
                .oneDay,
                .sevenDays,
                .thirtyDays,
                .ninetyDays,
                .oneHundredEightyDays,
                .threeHundredSixtyFiveDays,
                .unlimited,
            ]
        )
        let status = try await module.retentionStatus()
        XCTAssertEqual(
            status,
            ClipboardHistoryRetentionStatus(period: .thirtyDays)
        )
    }

    func testEveryValidTagProtectsAndLosingFinalProtectionStartsFullWindow()
        async throws
    {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        let captured = try await module.capture(textRequest("protected"))

        _ = try await module.replaceTagDefinitions(with: ["first", "second"])
        _ = try await module.apply(
            .setTags(captured.entryID, ["first", "second"])
        )
        clock.now = start.addingTimeInterval(100 * 86_400)
        _ = try await module.apply(
            .setTags(captured.entryID, ["second"])
        )
        clock.now = start.addingTimeInterval(200 * 86_400)
        let protectedPage = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            protectedPage.entries.map(\.id),
            [captured.entryID]
        )

        let unprotectedAt = clock.now
        let updated = try await module.apply(
            .setTags(captured.entryID, [])
        )
        guard case .updated(let entry) = updated else {
            return XCTFail("Expected tag mutation to update the entry")
        }
        XCTAssertEqual(entry.capturedAt, start)
        XCTAssertEqual(entry.tagIDs, [])

        clock.now = unprotectedAt.addingTimeInterval(30 * 86_400 - 1)
        let beforeBoundary = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            beforeBoundary.entries.map(\.id),
            [captured.entryID]
        )
        clock.now = unprotectedAt.addingTimeInterval(30 * 86_400)
        let atBoundary = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(atBoundary.entries, [])
    }

    func testFavoriteProtectsAndDefinitionRemovalDropsMembershipAtomically()
        async throws
    {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        let captured = try await module.capture(textRequest("favorite"))

        _ = try await module.replaceTagDefinitions(with: ["kept"])
        _ = try await module.apply(.setTags(captured.entryID, ["kept"]))
        _ = try await module.apply(.setFavorite(captured.entryID, true))
        clock.now = start.addingTimeInterval(100 * 86_400)
        let reconciliation = try await module.replaceTagDefinitions(with: [])
        XCTAssertEqual(reconciliation.removedMembershipCount, 1)
        XCTAssertEqual(reconciliation.unprotectedEntryCount, 0)

        _ = try await module.apply(.setFavorite(captured.entryID, false))
        clock.now = clock.now.addingTimeInterval(30 * 86_400 - 1)
        let countBeforeBoundary = try await module.count(
            ClipboardHistoryQuery()
        )
        XCTAssertEqual(countBeforeBoundary, 1)
        clock.now = clock.now.addingTimeInterval(1)
        let countAtBoundary = try await module.count(ClipboardHistoryQuery())
        XCTAssertEqual(countAtBoundary, 0)
    }

    func testRetentionReductionUsesRevisionBoundPreviewAndRejectsStaleApply()
        async throws
    {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        let old = try await module.capture(textRequest("old"))
        clock.now = start.addingTimeInterval(10 * 86_400)

        let preparation = try await module.prepareRetentionChange(to: .oneDay)
        guard case .confirmationRequired(let preview) = preparation else {
            return XCTFail("Expected a destructive retention preview")
        }
        XCTAssertEqual(preview.affectedCount, 1)

        _ = try await module.apply(.setFavorite(old.entryID, true))
        let stale = try await module.confirm(preview.token)
        guard case .stale(let refreshed) = stale else {
            return XCTFail("Expected stale retention confirmation")
        }
        XCTAssertEqual(refreshed.affectedCount, 0)
        let retentionAfterStale = try await module.retentionStatus()
        XCTAssertEqual(retentionAfterStale.period, .thirtyDays)
    }

    func testZeroImpactRetentionReductionAppliesImmediately() async throws {
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule()
        _ = try await module.capture(textRequest("fresh"))

        let preparation = try await module.prepareRetentionChange(to: .oneDay)

        XCTAssertEqual(preparation, .applied(.oneDay))
        let retention = try await module.retentionStatus()
        XCTAssertEqual(retention.period, .oneDay)
    }

    func testClearHistoryScopesAndStalePreviewPreserveDefinitionsAndSettings()
        async throws
    {
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule()
        _ = try await module.replaceTagDefinitions(with: ["saved"])
        let ordinary = try await module.capture(textRequest("ordinary"))
        let tagged = try await module.capture(textRequest("tagged"))
        let favorite = try await module.capture(textRequest("favorite"))
        _ = try await module.apply(.setTags(tagged.entryID, ["saved"]))
        _ = try await module.apply(.setFavorite(favorite.entryID, true))

        let preview = try await module.previewClearHistory(
            scope: .unprotectedOnly
        )
        XCTAssertEqual(preview.affectedCount, 1)
        _ = try await module.capture(textRequest("new"))
        let stale = try await module.confirm(preview.token)
        guard case .stale(let refreshed) = stale else {
            return XCTFail("Expected stale clear confirmation")
        }
        XCTAssertEqual(refreshed.affectedCount, 2)

        let defaultResult = try await module.confirm(refreshed.token)
        XCTAssertEqual(defaultResult, .applied(deletedCount: 2))
        let survivingPage = try await module.page(ClipboardHistoryQuery())
        let survivingIDs = Set(survivingPage.entries.map(\.id))
        XCTAssertEqual(survivingIDs, [tagged.entryID, favorite.entryID])
        XCTAssertFalse(survivingIDs.contains(ordinary.entryID))

        let expanded = try await module.previewClearHistory(
            scope: .includingProtected
        )
        XCTAssertEqual(expanded.affectedCount, 2)
        let expandedResult = try await module.confirm(expanded.token)
        XCTAssertEqual(expandedResult, .applied(deletedCount: 2))
        let remainingCount = try await module.count(ClipboardHistoryQuery())
        XCTAssertEqual(remainingCount, 0)
        let retainedSettings = try await module.retentionStatus()
        XCTAssertEqual(retainedSettings.period, .thirtyDays)

        let replacement = try await module.capture(textRequest("replacement"))
        let assignment = try await module.apply(
            .setTags(replacement.entryID, ["saved"])
        )
        guard case .updated(let entry) = assignment else {
            return XCTFail("Expected retained tag definition to remain usable")
        }
        XCTAssertEqual(entry.tagIDs, ["saved"])
    }

    func testTextEditReplacesSemanticStateWithoutMovingRecencyOrMerging()
        async throws
    {
        let start = Date(timeIntervalSince1970: 4_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        _ = try await module.replaceTagDefinitions(with: ["saved"])
        let edited = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: textRequest("unused").source,
                content: .qrCode("old QR value")
            )
        )
        _ = try await module.apply(.setTags(edited.entryID, ["saved"]))
        clock.now = start.addingTimeInterval(100)
        let equalExisting = try await module.capture(
            textRequest("https://example.com")
        )
        clock.now = start.addingTimeInterval(200)
        let before = try await module.editDiagnosticsForTesting(edited.entryID)

        let mutation = try await module.apply(
            .editText(edited.entryID, "https://example.com")
        )
        guard case .updated(let entry) = mutation else {
            return XCTFail("Expected text edit to update the entry")
        }
        let after = try await module.editDiagnosticsForTesting(edited.entryID)
        XCTAssertEqual(entry.capturedAt, start)
        XCTAssertEqual(entry.facets, [.text, .link])
        XCTAssertEqual(entry.tagIDs, ["saved"])
        XCTAssertEqual(after?.capturedAt, before?.capturedAt)
        XCTAssertEqual(after?.lastCapturedAt, before?.lastCapturedAt)
        XCTAssertEqual(after?.editedAt, clock.now)
        XCTAssertEqual(after?.retentionStartedAt, clock.now)
        XCTAssertNotEqual(after?.fingerprint, before?.fingerprint)
        XCTAssertEqual(after?.representationKinds, ["text"])
        XCTAssertEqual(after?.searchKinds, ["exactText"])

        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: edited.entryID,
                purpose: .normalPaste
            )
        )
        XCTAssertEqual(
            materialized.items,
            [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: "https://example.com"
                        )
                    ]
                )
            ]
        )
        let oldSearch = try await module.page(
            ClipboardHistoryQuery(text: "old QR")
        )
        XCTAssertEqual(oldSearch.entries, [])
        let newSearch = try await module.page(
            ClipboardHistoryQuery(text: "example.com")
        )
        XCTAssertEqual(
            Set(newSearch.entries.map(\.id)),
            [edited.entryID, equalExisting.entryID]
        )
        let browse = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            browse.entries.map(\.id),
            [equalExisting.entryID, edited.entryID]
        )
    }

    func testTextEditRejectsZeroLengthAndEntriesWithoutExactSingleItemText()
        async throws
    {
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule()
        let text = try await module.capture(textRequest("editable"))
        let bitmap = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: textRequest("unused").source,
                content: .bitmap(
                    Data(
                        base64Encoded:
                            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                    )!,
                    provenance: .image
                )
            )
        )

        do {
            _ = try await module.apply(.editText(text.entryID, ""))
            XCTFail("Expected zero-length edit rejection")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .invalidTextEdit
            )
        }
        do {
            _ = try await module.apply(.editText(bitmap.entryID, "plain"))
            XCTFail("Expected non-text edit rejection")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .invalidTextEdit
            )
        }

        let whitespace = try await module.apply(
            .editText(text.entryID, " \n ")
        )
        guard case .updated(let entry) = whitespace else {
            return XCTFail("Expected whitespace edit to remain valid")
        }
        XCTAssertEqual(entry.previewText, " \n ")
    }

    func testExpiredEntryIsAbsentFromSearchCountMaterializationAndDuplicateReuse()
        async throws
    {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        let original = try await module.capture(textRequest("expiry sentinel"))

        clock.now = start.addingTimeInterval(29 * 86_400)
        _ = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: original.entryID,
                purpose: .preview
            )
        )
        clock.now = start.addingTimeInterval(30 * 86_400)

        let browse = try await module.page(ClipboardHistoryQuery())
        let search = try await module.page(
            ClipboardHistoryQuery(text: "sentinel")
        )
        let count = try await module.count(ClipboardHistoryQuery())
        XCTAssertEqual(browse.entries, [])
        XCTAssertEqual(search.entries, [])
        XCTAssertEqual(count, 0)
        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: original.entryID,
                    purpose: .normalPaste
                )
            )
            XCTFail("Expected expired materialization to be unavailable")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .entryNotFound
            )
        }

        let recaptured = try await module.capture(
            textRequest("expiry sentinel")
        )
        XCTAssertNotEqual(recaptured.entryID, original.entryID)
    }

    func testPaginationReevaluatesExpiryBetweenPages() async throws {
        let start = Date(timeIntervalSince1970: 6_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        for index in 0 ..< 101 {
            clock.now = start.addingTimeInterval(Double(index))
            _ = try await module.capture(textRequest("page \(index)"))
        }

        clock.now = start.addingTimeInterval(30 * 86_400 - 1)
        let first = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(first.entries.count, 100)
        let cursor = try XCTUnwrap(first.nextCursor)

        clock.now = start.addingTimeInterval(30 * 86_400 + 101)
        let second = try await module.page(
            ClipboardHistoryQuery(),
            after: cursor
        )
        XCTAssertEqual(second.entries, [])
        XCTAssertNil(second.nextCursor)
    }

    func testUnlimitedRetentionNeverExpiresAndUsageDoesNotExtendFiniteRetention()
        async throws
    {
        let start = Date(timeIntervalSince1970: 7_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)

        let unlimitedPreparation = try await module.prepareRetentionChange(
            to: .unlimited
        )
        XCTAssertEqual(unlimitedPreparation, .applied(.unlimited))
        let unlimited = try await module.capture(textRequest("forever"))
        clock.now = start.addingTimeInterval(20 * 365 * 86_400)
        let reused = try await module.capture(textRequest("forever"))
        XCTAssertEqual(reused.entryID, unlimited.entryID)

        let finitePreparation = try await module.prepareRetentionChange(
            to: .thirtyDays
        )
        XCTAssertEqual(finitePreparation, .applied(.thirtyDays))
        let finiteStart = clock.now
        let finite = try await module.capture(textRequest("finite"))
        clock.now = finiteStart.addingTimeInterval(29 * 86_400)
        for purpose in [
            ClipboardHistoryMaterializationPurpose.preview,
            .normalPaste,
            .plainTextPaste,
            .hostAction,
        ] {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: finite.entryID,
                    purpose: purpose
                )
            )
        }
        clock.now = finiteStart.addingTimeInterval(30 * 86_400)
        let page = try await module.page(ClipboardHistoryQuery(text: "finite"))
        XCTAssertEqual(page.entries, [])
    }

    func testMaintenancePhysicallyReclaimsExpiredPayloadsWithinTwentyFourHours()
        async throws
    {
        let start = Date()
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule(clock: clock)
        _ = try await module.capture(bitmapRequest())
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        clock.now = start.addingTimeInterval(30 * 86_400)
        let hidden = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(hidden.entries, [])
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        let report = try await module.performMaintenance(
            orphanGracePeriod: 48 * 60 * 60
        )
        XCTAssertEqual(report.reclaimedPayloadCount, 2)
        XCTAssertEqual(try fixture.payloadFiles(), [])
    }

    func testAutomaticMaintenanceUsesPersistedDailyDeadlineAcrossReopen()
        async throws
    {
        let start = Date(timeIntervalSince1970: 9_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let firstScheduler = MaintenanceTestScheduler(now: start)
        let first = fixture.makeModule(
            clock: clock,
            maintenanceScheduler: firstScheduler
        )

        await waitForMaintenanceScheduler(firstScheduler, sleepCount: 1)
        let firstDeadlines = await firstScheduler.recordedDeadlines
        let firstDeadline = try XCTUnwrap(firstDeadlines.first)
        XCTAssertEqual(
            firstDeadline.timeIntervalSince1970,
            start.addingTimeInterval(86_400).timeIntervalSince1970,
            accuracy: 0.001
        )
        let orphan = fixture.url
            .appendingPathComponent("payloads")
            .appendingPathComponent("reopen-overdue.payload")
        try Data(repeating: 0xC3, count: 4_096).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: start],
            ofItemAtPath: orphan.path
        )
        try await first.closeStoreForTesting()

        clock.now = start.addingTimeInterval(30 * 3_600)
        let secondScheduler = MaintenanceTestScheduler(now: clock.now)
        let second = fixture.makeModule(
            clock: clock,
            maintenanceScheduler: secondScheduler
        )
        await waitForMaintenanceScheduler(secondScheduler, sleepCount: 1)
        let reopenedDeadlines = await secondScheduler.recordedDeadlines
        let reopenedDeadline = try XCTUnwrap(reopenedDeadlines.first)
        XCTAssertEqual(reopenedDeadline, firstDeadline)
        await waitUntil {
            !FileManager.default.fileExists(atPath: orphan.path)
        }
        await waitForMaintenanceScheduler(secondScheduler, sleepCount: 2)
        let nextDeadlines = await secondScheduler.recordedDeadlines
        let nextDeadline = try XCTUnwrap(nextDeadlines.last)
        XCTAssertEqual(
            nextDeadline.timeIntervalSince(clock.now),
            86_400,
            accuracy: 0.001
        )
        try await second.closeStoreForTesting()
    }

    func testAutomaticMaintenanceRetriesStorageUsageFailureBeforeAdvancingSchedule()
        async throws
    {
        let start = Date(timeIntervalSince1970: 10_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let fault = OneShotStorageTraversalFailure()
        let scheduler = MaintenanceTestScheduler(now: start)
        let module = fixture.makeModule(
            clock: clock,
            maintenanceScheduler: scheduler,
            storageTraversalHook: { _ in
                try fault.failOnce()
            }
        )

        await waitForMaintenanceScheduler(scheduler, sleepCount: 1)
        let deadline = start.addingTimeInterval(86_400)
        clock.now = deadline
        await scheduler.advance(to: deadline)
        await waitForMaintenanceScheduler(scheduler, sleepCount: 2)
        let failedSchedule = try await module.maintenanceScheduleForTesting()
        XCTAssertNil(failedSchedule.lastSuccess)
        XCTAssertEqual(
            failedSchedule.nextDeadline,
            deadline.timeIntervalSince1970
        )
        XCTAssertEqual(fault.failureCount, 1)
        let retryDeadlines = await scheduler.recordedDeadlines
        let retryDeadline = try XCTUnwrap(retryDeadlines.last)
        XCTAssertEqual(
            retryDeadline.timeIntervalSince(deadline),
            5 * 60,
            accuracy: 0.001
        )

        clock.now = retryDeadline
        await scheduler.advance(to: retryDeadline)
        await waitForMaintenanceScheduler(scheduler, sleepCount: 3)
        let successfulSchedule = try await module.maintenanceScheduleForTesting()
        XCTAssertEqual(
            successfulSchedule.lastSuccess,
            retryDeadline.timeIntervalSince1970
        )
        XCTAssertEqual(
            successfulSchedule.nextDeadline,
            retryDeadline.addingTimeInterval(86_400).timeIntervalSince1970
        )
        let successDeadlines = await scheduler.recordedDeadlines
        let nextDeadline = try XCTUnwrap(successDeadlines.last)
        XCTAssertEqual(
            nextDeadline.timeIntervalSince(retryDeadline),
            86_400,
            accuracy: 0.001
        )
        try await module.closeStoreForTesting()
    }

    func testManualMaintenanceReportsStorageFailureBeforeRecordingSuccess()
        async throws
    {
        let start = Date(timeIntervalSince1970: 10_500_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let fault = OneShotStorageTraversalFailure()
        let module = fixture.makeModule(
            clock: clock,
            storageTraversalHook: { _ in
                try fault.failOnce()
            }
        )
        let initialSchedule = try await module.maintenanceScheduleForTesting()

        do {
            _ = try await module.performMaintenance()
            XCTFail("Expected storage usage failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryStorageError,
                .fileOperationFailed(EIO)
            )
        }
        let failedSchedule = try await module.maintenanceScheduleForTesting()
        XCTAssertEqual(failedSchedule.lastSuccess, initialSchedule.lastSuccess)
        XCTAssertEqual(
            failedSchedule.nextDeadline,
            initialSchedule.nextDeadline
        )

        let report = try await module.performMaintenance()
        XCTAssertEqual(report.reclaimedPayloadCount, 0)
        XCTAssertGreaterThan(report.storageBytes, 0)
        XCTAssertEqual(fault.failureCount, 1)
        let successfulSchedule = try await module.maintenanceScheduleForTesting()
        XCTAssertEqual(
            successfulSchedule.lastSuccess,
            start.timeIntervalSince1970
        )
        XCTAssertEqual(
            successfulSchedule.nextDeadline,
            start.addingTimeInterval(86_400).timeIntervalSince1970
        )
    }

    func testCloseRetryAndResetKeepExactlyOneMaintenanceTask()
        async throws
    {
        let start = Date(timeIntervalSince1970: 11_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let scheduler = MaintenanceTestScheduler(now: start)
        let module = fixture.makeModule(
            clock: clock,
            maintenanceScheduler: scheduler
        )
        await waitForMaintenanceScheduler(scheduler, sleepCount: 1)
        let initialWaiterCount = await scheduler.activeWaiterCount
        XCTAssertEqual(initialWaiterCount, 1)

        try await module.closeStoreForTesting()
        await waitUntil { await scheduler.activeWaiterCount == 0 }
        let firstCancellationCount = await scheduler.cancellationCount
        XCTAssertEqual(firstCancellationCount, 1)

        await module.retry()
        await waitForMaintenanceScheduler(scheduler, sleepCount: 2)
        let firstRetryWaiterCount = await scheduler.activeWaiterCount
        XCTAssertEqual(firstRetryWaiterCount, 1)
        await module.retry()
        await waitForMaintenanceScheduler(scheduler, sleepCount: 3)
        let secondRetryWaiterCount = await scheduler.activeWaiterCount
        let secondCancellationCount = await scheduler.cancellationCount
        XCTAssertEqual(secondRetryWaiterCount, 1)
        XCTAssertEqual(secondCancellationCount, 2)

        try await module.reset(confirmation: .confirmed)
        await waitForMaintenanceScheduler(scheduler, sleepCount: 4)
        let resetWaiterCount = await scheduler.activeWaiterCount
        let resetCancellationCount = await scheduler.cancellationCount
        XCTAssertEqual(resetWaiterCount, 1)
        XCTAssertEqual(resetCancellationCount, 3)

        try await module.closeStoreForTesting()
        await waitUntil { await scheduler.activeWaiterCount == 0 }
        let finalCancellationCount = await scheduler.cancellationCount
        XCTAssertEqual(finalCancellationCount, 4)
    }

    func testStorageUsageIncludesEveryOwnedArtifactAndDoesNotFollowSymlinks()
        async throws
    {
        let fixture = try RetentionTemporaryStore()
        let module = fixture.makeModule()
        _ = try await module.capture(bitmapRequest())
        let staging = fixture.url
            .appendingPathComponent("staging")
            .appendingPathComponent("manual.staging")
        let orphan = fixture.url
            .appendingPathComponent("payloads")
            .appendingPathComponent("manual.payload")
        try Data(repeating: 0xA7, count: 32_768).write(to: staging)
        try Data(repeating: 0xB8, count: 65_536).write(to: orphan)
        await module.awaitDerivedJobsForTesting()

        let expected = try allocatedRegularFileBytes(in: fixture.url)
        let reported = try await module.storageUsage()
        XCTAssertEqual(reported, expected)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ReferencedSource-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(repeating: 0xCC, count: 1_048_576).write(to: outside)
        let link = fixture.url.appendingPathComponent("referenced-source")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        let afterSymlink = try await module.storageUsage()
        XCTAssertEqual(afterSymlink, reported)
    }

    func testStorageUsageFailsSafelyWhenDirectoryBecomesExternalSymlink()
        async throws
    {
        let fixture = try RetentionTemporaryStore()
        let owned = fixture.url.appendingPathComponent("owned-nested")
        try FileManager.default.createDirectory(
            at: owned,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xE5, count: 4_096).write(
            to: owned.appendingPathComponent("owned.payload")
        )
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-StorageBoundary-\(UUID().uuidString)"
            )
        let parked = fixture.url.appendingPathComponent("owned-parked")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideFile = outside.appendingPathComponent("outside.payload")
        try Data(repeating: 0xF6, count: 1_048_576).write(to: outsideFile)
        let swap = StorageTraversalSwap(
            target: owned,
            parked: parked,
            outside: outside
        )
        let module = fixture.makeModule(storageTraversalHook: { url in
            try swap.performIfNeeded(at: url)
        })

        do {
            _ = try await module.storageUsage()
            XCTFail("Expected safe traversal failure")
        } catch {
            XCTAssertNotNil(error as? ClipboardHistoryStorageError)
        }
        XCTAssertTrue(swap.didSwap)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideFile.path),
            "Traversal must never consume or mutate the external target"
        )
    }

    func testLogicalDeletionFaultsRollbackSearchRowsEntriesAndPayloadReferences()
        async throws
    {
        for point in [
            ClipboardHistoryFaultPoint.logicalDeletionAfterSearchIndexes,
            .logicalDeletionAfterEntries,
            .logicalDeletionAfterPayloadRows,
        ] {
            let fixture = try RetentionTemporaryStore()
            let writer = fixture.makeModule()
            let text = try await writer.capture(
                textRequest("rollback \(point)")
            )
            let bitmap = try await writer.capture(bitmapRequest())
            let payloadCount = try fixture.payloadFiles().count
            try await writer.closeStoreForTesting()

            let failing = fixture.makeModule(faults: [point])
            for entryID in [text.entryID, bitmap.entryID] {
                do {
                    _ = try await failing.apply(.delete(entryID))
                    XCTFail("Expected injected \(point) failure")
                } catch {
                    XCTAssertEqual(
                        error as? ClipboardHistoryModuleError,
                        .storageFailure
                    )
                }
            }
            let search = try await failing.page(
                ClipboardHistoryQuery(text: "rollback")
            )
            let browse = try await failing.page(ClipboardHistoryQuery())
            XCTAssertEqual(search.entries.map(\.id), [text.entryID])
            XCTAssertEqual(
                Set(browse.entries.map(\.id)),
                [text.entryID, bitmap.entryID]
            )
            XCTAssertEqual(try fixture.payloadFiles().count, payloadCount)
            _ = try await failing.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: bitmap.entryID,
                    purpose: .normalPaste
                )
            )
        }
    }

    func testRetentionApplyFailureRollsBackPeriodAndAffectedEntries()
        async throws
    {
        let start = Date(timeIntervalSince1970: 8_000_000)
        let clock = RetentionTestClock(start)
        let fixture = try RetentionTemporaryStore()
        let writer = fixture.makeModule(clock: clock)
        let captured = try await writer.capture(textRequest("atomic"))
        clock.now = start.addingTimeInterval(10 * 86_400)
        let preparation = try await writer.prepareRetentionChange(to: .oneDay)
        guard case .confirmationRequired(let preview) = preparation else {
            return XCTFail("Expected retention confirmation")
        }
        try await writer.closeStoreForTesting()

        let failing = fixture.makeModule(
            clock: clock,
            faults: [.databaseTransaction]
        )
        do {
            _ = try await failing.confirm(preview.token)
            XCTFail("Expected atomic retention failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }
        let status = try await failing.retentionStatus()
        let page = try await failing.page(ClipboardHistoryQuery())
        XCTAssertEqual(status.period, .thirtyDays)
        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
    }

    func testWriteFailureRejectsOnlyEditAndNeverPrunesExistingHistory()
        async throws
    {
        let fixture = try RetentionTemporaryStore()
        let writer = fixture.makeModule()
        let first = try await writer.capture(textRequest("preserved first"))
        let second = try await writer.capture(textRequest("preserved second"))
        try await writer.closeStoreForTesting()

        let failing = fixture.makeModule(faults: [.databaseTransaction])
        do {
            _ = try await failing.apply(
                .editText(first.entryID, "replacement")
            )
            XCTFail("Expected write failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }
        let page = try await failing.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            Set(page.entries.map(\.id)),
            [first.entryID, second.entryID]
        )
        await failing.awaitSearchIndexRebuildForTesting()
        let original = try await failing.page(
            ClipboardHistoryQuery(text: "preserved first")
        )
        let replacement = try await failing.page(
            ClipboardHistoryQuery(text: "replacement")
        )
        XCTAssertEqual(original.entries.map(\.id), [first.entryID])
        XCTAssertEqual(replacement.entries, [])
    }

    private func textRequest(
        _ value: String
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            ),
            content: .text(value)
        )
    }

    private func bitmapRequest() -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: textRequest("unused").source,
            content: .bitmap(
                Data(
                    base64Encoded:
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                )!,
                provenance: .image
            )
        )
    }

    private func allocatedRegularFileBytes(in directory: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var total: UInt64 = 0
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) {
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                total += try allocatedRegularFileBytes(in: child)
            } else if values.isRegularFile == true {
                total += UInt64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? 0
                )
            }
        }
        return total
    }
}

private final class RetentionTemporaryStore {
    let url: URL
    private let keyStore = RetentionMasterKeyStore()

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardRetentionTests-\(UUID().uuidString)"
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeModule(
        clock: RetentionTestClock = RetentionTestClock(Date()),
        faults: Set<ClipboardHistoryFaultPoint> = [],
        maintenanceScheduler:
            (any ClipboardHistoryMaintenanceScheduling)? = nil,
        faultInjector: ClipboardHistoryFaultInjector? = nil,
        storageTraversalHook:
            (@Sendable (URL) throws -> Void)? = nil
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: url,
            keyStore: keyStore,
            faultInjector: faultInjector
                ?? ClipboardHistoryFaultInjector(points: faults),
            now: { clock.now },
            maintenanceScheduler: maintenanceScheduler,
            storageTraversalHook: storageTraversalHook
        )
    }

    func payloadFiles() throws -> [URL] {
        let directory = url.appendingPathComponent("payloads")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "payload" }
    }
}

private final class RetentionMasterKeyStore:
    ClipboardHistoryMasterKeyStoring,
    @unchecked Sendable
{
    private let key = Data(repeating: 0x85, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
    }
}

private final class RetentionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    init(_ now: Date) {
        value = now
    }
}

private actor MaintenanceTestScheduler:
    ClipboardHistoryMaintenanceScheduling
{
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var now: Date
    private var waiters: [UUID: Waiter] = [:]
    private(set) var recordedDeadlines: [Date] = []
    private(set) var cancellationCount = 0

    init(now: Date) {
        self.now = now
    }

    var activeWaiterCount: Int {
        waiters.count
    }

    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        recordedDeadlines.append(deadline)
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    deadline: deadline,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(to date: Date) {
        now = date
        let ready = waiters.filter { $0.value.deadline <= date }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        cancellationCount += 1
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private final class OneShotStorageTraversalFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures = 1
    private var recordedFailureCount = 0

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailureCount
    }

    func failOnce() throws {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return }
        remainingFailures -= 1
        recordedFailureCount += 1
        throw ClipboardHistoryStorageError.fileOperationFailed(EIO)
    }
}

private final class StorageTraversalSwap: @unchecked Sendable {
    let target: URL
    let parked: URL
    let outside: URL
    private let lock = NSLock()
    private var swapped = false

    var didSwap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return swapped
    }

    init(target: URL, parked: URL, outside: URL) {
        self.target = target
        self.parked = parked
        self.outside = outside
    }

    func performIfNeeded(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !swapped, url.path == target.path else { return }
        try FileManager.default.moveItem(at: target, to: parked)
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: outside
        )
        swapped = true
    }
}

private func waitForMaintenanceScheduler(
    _ scheduler: MaintenanceTestScheduler,
    sleepCount: Int
) async {
    await waitUntil {
        await scheduler.recordedDeadlines.count >= sleepCount
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<100_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for asynchronous test condition")
}

private struct TextEditDiagnostics {
    let capturedAt: Date
    let lastCapturedAt: Date
    let editedAt: Date?
    let retentionStartedAt: Date
    let fingerprint: Data
    let representationKinds: [String]
    let searchKinds: [String]
}

private struct MaintenanceScheduleDiagnostics {
    let lastSuccess: Double?
    let nextDeadline: Double?
}

extension ClipboardHistoryModule {
    fileprivate func maintenanceScheduleForTesting()
        throws -> MaintenanceScheduleDiagnostics
    {
        try requiredDatabase().read { database in
            let values = Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(
                    database,
                    sql: """
                        SELECT key, real_value
                        FROM clipboard_maintenance_metadata
                        WHERE key IN (
                            'lastMaintenanceSucceededAt',
                            'nextMaintenanceDeadline'
                        )
                        """
                ).compactMap { row -> (String, Double)? in
                    guard let value: Double = row["real_value"] else {
                        return nil
                    }
                    return (row["key"], value)
                }
            )
            return MaintenanceScheduleDiagnostics(
                lastSuccess: values["lastMaintenanceSucceededAt"],
                nextDeadline: values["nextMaintenanceDeadline"]
            )
        }
    }

    fileprivate func editDiagnosticsForTesting(
        _ entryID: ClipboardHistoryEntryID
    ) throws -> TextEditDiagnostics? {
        let database = try requiredDatabase()
        let storedID = entryID.value.uuidString.lowercased()
        return try database.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT entry.captured_at, entry.last_captured_at,
                               entry.edited_at, retention.retention_started_at,
                               candidate.fingerprint
                        FROM clipboard_entries AS entry
                        JOIN clipboard_retention_state AS retention
                          ON retention.entry_id = entry.id
                        JOIN clipboard_duplicate_candidates AS candidate
                          ON candidate.entry_id = entry.id
                        WHERE entry.id = ?
                        """,
                    arguments: [storedID]
                )
            else {
                return nil
            }
            return TextEditDiagnostics(
                capturedAt: Date(timeIntervalSince1970: row["captured_at"]),
                lastCapturedAt: Date(
                    timeIntervalSince1970: row["last_captured_at"]
                ),
                editedAt: (row["edited_at"] as Double?).map {
                    Date(timeIntervalSince1970: $0)
                },
                retentionStartedAt: Date(
                    timeIntervalSince1970: row["retention_started_at"]
                ),
                fingerprint: row["fingerprint"],
                representationKinds: try String.fetchAll(
                    database,
                    sql: """
                        SELECT kind
                        FROM clipboard_representations
                        WHERE entry_id = ?
                        ORDER BY representation_index
                        """,
                    arguments: [storedID]
                ),
                searchKinds: try String.fetchAll(
                    database,
                    sql: """
                        SELECT field_kind
                        FROM clipboard_search_fields
                        WHERE entry_id = ?
                        ORDER BY field_index
                        """,
                    arguments: [storedID]
                )
            )
        }
    }
}
