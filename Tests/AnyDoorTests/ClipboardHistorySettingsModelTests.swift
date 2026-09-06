import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistorySettingsModelTests: XCTestCase {
    func testClearDefaultsToUnprotectedAndRefreshesStaleCount()
        async throws
    {
        let fixture = try SettingsFixture()
        let first = try await fixture.module.capture(
            request("first")
        )
        let protected = try await fixture.module.capture(
            request("protected")
        )
        _ = try await fixture.module.apply(
            .setFavorite(protected.entryID, true)
        )
        let model = fixture.model

        await model.beginClearHistory()

        XCTAssertFalse(model.clearIncludesProtected)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 1)

        await model.setClearIncludesProtected(true)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 2)
        await model.setClearIncludesProtected(false)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 1)

        _ = try await fixture.module.capture(request("new"))
        await model.confirmClearHistory()

        XCTAssertEqual(
            model.clearConfirmation?.preview.affectedCount,
            2,
            "A changed revision must refresh instead of deleting"
        )
        var page = try await fixture.module.page(
            ClipboardHistoryQuery()
        )
        XCTAssertEqual(page.entries.count, 3)

        await model.confirmClearHistory()
        page = try await fixture.module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [protected.entryID])
        XCTAssertFalse(page.entries.contains { $0.id == first.entryID })
    }

    func testClearIncludingProtectedPreservesTagDefinitions()
        async throws
    {
        let fixture = try SettingsFixture()
        let entry = try await fixture.module.capture(request("tagged"))
        let assignment = try await fixture.module.createTagDefinition(
            named: "Keep Definition",
            assigningTo: entry.entryID
        )
        let model = fixture.model

        await model.beginClearHistory()
        await model.setClearIncludesProtected(true)
        await model.confirmClearHistory()

        let definitions = try await fixture.module.tagDefinitions()
        XCTAssertEqual(definitions, [assignment.definition])
        let page = try await fixture.module.page(
            ClipboardHistoryQuery()
        )
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testRefreshReadsThirtyDayAndOCRDefaults() async throws {
        let fixture = try SettingsFixture()

        await fixture.model.refresh()

        XCTAssertEqual(fixture.model.retention, .thirtyDays)
        XCTAssertFalse(
            fixture.model.automaticImageTextIndexingEnabled
        )
        XCTAssertGreaterThan(fixture.model.storageBytes, 0)
    }

    func testFirstShowAndClipboardSelectedReopenRefreshFreshUsage()
        async throws
    {
        let fixture = try SettingsFixture()
        fixture.presentation.selectedTab = .clipboard

        fixture.presentation.recordShow()
        await fixture.model.refreshForSettingsPresentation()
        let firstUsage = fixture.model.storageBytes

        let entry = try await fixture.module.capture(
            request(String(repeating: "fresh usage ", count: 20_000))
        )
        let expectedUsage = try await fixture.module.storageUsage()

        fixture.presentation.recordShow()
        await fixture.model.refreshForSettingsPresentation()

        XCTAssertEqual(fixture.model.storageBytes, expectedUsage)
        XCTAssertGreaterThan(fixture.model.storageBytes, firstUsage)
        let page = try await fixture.module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [entry.entryID])
    }

    func testSettingsPresentationGenerationsAreMonotonicAcrossRapidShows() {
        let presentation = SettingsPresentation()

        presentation.recordShow()
        presentation.recordShow()
        presentation.recordShow()

        XCTAssertEqual(presentation.showGeneration, 3)
    }

    func testClipboardRefreshRequiresSelectionAndStartsWhenPaneIsSelected()
        async throws
    {
        let usageReader = ControlledStorageUsageReader()
        let fixture = try SettingsFixture(
            refreshOperations: usageReader.operations
        )

        fixture.presentation.recordShow()
        await fixture.model.refreshForSettingsPresentation()

        let hiddenRequestCount = await usageReader.requestCount
        XCTAssertEqual(hiddenRequestCount, 0)

        fixture.presentation.selectedTab = .clipboard
        let refresh = Task { @MainActor in
            await fixture.model.refreshForSettingsPresentation()
        }
        await waitUntil("selected Clipboard pane storage read") {
            await usageReader.requestCount == 1
        }
        await usageReader.release(requestID: 0, with: .value(41))
        await refresh.value

        XCTAssertEqual(fixture.model.storageBytes, 41)
    }

    func testRapidVisibleShowsCancelStaleRefreshAndOnlyPublishLatest()
        async throws
    {
        for staleResponse in [
            ControlledStorageUsageReader.Response.value(101),
            .failure,
        ] {
            let usageReader = ControlledStorageUsageReader()
            let presentation = SettingsPresentation(
                selectedTab: .clipboard
            )
            let fixture = try SettingsFixture(
                presentation: presentation,
                refreshOperations: usageReader.operations
            )

            presentation.recordShow()
            let staleRefresh = Task { @MainActor in
                await fixture.model.refreshForSettingsPresentation()
            }
            await waitUntil("first storage read") {
                await usageReader.requestCount == 1
            }

            presentation.recordShow()
            let latestRefresh = Task { @MainActor in
                await fixture.model.refreshForSettingsPresentation()
            }
            await waitUntil("replacement storage read") {
                await usageReader.requestCount == 2
            }
            await waitUntil("stale storage read cancellation") {
                await usageReader.cancelledRequestIDs.contains(0)
            }

            await usageReader.release(
                requestID: 0,
                with: staleResponse
            )
            await staleRefresh.value

            XCTAssertEqual(fixture.model.storageBytes, 0)
            XCTAssertFalse(fixture.model.operationFailed)

            await usageReader.release(requestID: 1, with: .value(202))
            await latestRefresh.value

            XCTAssertEqual(fixture.model.storageBytes, 202)
            XCTAssertFalse(fixture.model.operationFailed)
        }
    }

    func testPresentationRefreshFailureIsSilentUntilTheStoreIsReady()
        async throws
    {
        let presentation = SettingsPresentation(selectedTab: .clipboard)
        let fixture = try SettingsFixture(
            presentation: presentation,
            refreshOperations: .alwaysFailing
        )

        // Not ready: the lifecycle section already explains the state, so a
        // presentation read that fails because of it must not add a second
        // "an operation failed" error for something the user never did.
        XCTAssertNotEqual(fixture.lifecycle.state, .ready)
        presentation.recordShow()
        await fixture.model.refreshForSettingsPresentation()
        XCTAssertFalse(fixture.model.operationFailed)

        fixture.lifecycle.start()
        await waitUntil("lifecycle ready") {
            fixture.lifecycle.state == .ready
        }

        // Ready: a failure now is genuinely unexpected and stays reported.
        presentation.recordShow()
        await fixture.model.refreshForSettingsPresentation()
        XCTAssertTrue(fixture.model.operationFailed)
    }

    private func request(
        _ text: String
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: .unknown,
            content: .text(text)
        )
    }
}

@MainActor
private struct SettingsFixture {
    let module: ClipboardHistoryModule
    let defaults: UserDefaults
    let lifecycle: ClipboardHistoryLifecycle
    let presentation: SettingsPresentation
    let model: ClipboardHistorySettingsModel

    init(
        presentation: SettingsPresentation = SettingsPresentation(),
        refreshOperations: ClipboardHistorySettingsRefreshOperations? = nil
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        module = try ClipboardHistoryModule(
            testingDatabaseURL:
                directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x31, count: 32)
        )
        let suite = "ClipboardHistorySettingsModelTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        lifecycle = ClipboardHistoryLifecycle(
            module: module,
            defaults: defaults,
            migrationRequest: {
                ClipboardHistoryLegacyMigrationRequest(
                    transfer: ClipboardHistoryLegacyTransfer(
                        entries: [],
                        tags: [],
                        categoryOrder: [],
                        retentionPeriod: .thirtyDays
                    ),
                    payloadDirectory: directory
                )
            }
        )
        self.presentation = presentation
        model = ClipboardHistorySettingsModel(
            module: module,
            lifecycle: lifecycle,
            presentation: presentation,
            defaults: defaults,
            refreshOperations: refreshOperations
        )
    }
}

extension ClipboardHistorySettingsRefreshOperations {
    fileprivate enum RefreshFailure: Error {
        case injected
    }

    fileprivate static var alwaysFailing: Self {
        Self(
            retentionPeriod: { throw RefreshFailure.injected },
            automaticImageTextIndexingEnabled: {
                throw RefreshFailure.injected
            },
            storageUsage: { throw RefreshFailure.injected }
        )
    }
}

private actor ControlledStorageUsageReader {
    enum Response: Sendable {
        case value(UInt64)
        case failure
    }

    private enum Failure: Error {
        case injected
    }

    private var nextRequestID = 0
    private var continuations:
        [Int: CheckedContinuation<Response, Never>] = [:]
    private(set) var requestCount = 0
    private(set) var cancelledRequestIDs: Set<Int> = []

    nonisolated var operations: ClipboardHistorySettingsRefreshOperations {
        ClipboardHistorySettingsRefreshOperations(
            retentionPeriod: { .thirtyDays },
            automaticImageTextIndexingEnabled: { false },
            storageUsage: {
                try await self.storageUsage()
            }
        )
    }

    func release(
        requestID: Int,
        with response: Response
    ) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: response
        )
    }

    private func storageUsage() async throws -> UInt64 {
        let requestID = nextRequestID
        nextRequestID += 1
        requestCount += 1
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task {
                await self.recordCancellation(requestID)
            }
        }
        switch response {
        case .value(let bytes):
            return bytes
        case .failure:
            throw Failure.injected
        }
    }

    private func recordCancellation(_ requestID: Int) {
        cancelledRequestIDs.insert(requestID)
    }
}
