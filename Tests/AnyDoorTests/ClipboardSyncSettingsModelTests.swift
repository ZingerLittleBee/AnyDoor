import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncSettingsModelTests: XCTestCase {
    func testTagChoiceRequiresActivationAndSurvivesDisablingThisMac()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory,
            keyStore: SettingsSyncLocalKeyStore()
        ))
        let capture = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("A tagged note")
        ))
        let assignment = try await module.createTagDefinition(
            named: "Work", assigningTo: capture.entryID
        )
        let model = ClipboardSyncSettingsModel(module: module)
        await model.refresh()

        await model.selectTag(assignment.definition.id)

        XCTAssertNil(model.selectedTagID)
        await model.setEnabled(true)
        await model.selectTag(assignment.definition.id)
        XCTAssertEqual(model.selectedTagID, assignment.definition.id)
        XCTAssertFalse(model.canSelectTag)

        await model.setEnabled(false)
        let reopenedSettings = ClipboardSyncSettingsModel(module: module)
        await reopenedSettings.refresh()

        XCTAssertEqual(reopenedSettings.selectedTagID, assignment.definition.id)
        XCTAssertFalse(reopenedSettings.status.isEnabled)
        let entries = try await module.page(ClipboardHistoryQuery()).entries
        XCTAssertEqual(entries.first?.tagIDs, [assignment.definition.id])
    }

    func testDisablingWhileConnectingCancelsTheRequestWithoutEnablingMonitoring()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let transport = HeldSettingsSyncTransport()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory,
            keyStore: SettingsSyncLocalKeyStore(),
            syncServices: ClipboardSyncServices(
                transport: transport,
                keys: UnavailableSettingsSyncKeys(),
                pollingInterval: nil
            )
        ))
        let model = ClipboardSyncSettingsModel(module: module)
        let activation = Task { await model.setEnabled(true) }
        var startedConnecting = false
        for _ in 0..<500 {
            await model.refresh()
            if await transport.hasPendingAccount, model.status.isEnabled {
                startedConnecting = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(startedConnecting, "Activation must reach the isolated account request")

        await model.setEnabled(false)
        let enabledAfterDisable = model.status.isEnabled

        // Always release the external request, including on the red path.
        await module.suspendSync()
        await activation.value
        XCTAssertFalse(enabledAfterDisable)
        XCTAssertFalse(model.isPerformingAction)
        let historyStatus = await module.status()
        XCTAssertFalse(historyStatus.isMonitoring)
    }

    func testExplicitActivationReportsUnavailableCapabilityWithoutClaimingDelivery()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: directory.appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x48, count: 32)
            )
        )
        let model = ClipboardSyncSettingsModel(module: module)

        await model.setEnabled(true)

        XCTAssertTrue(model.status.isEnabled)
        XCTAssertEqual(model.status.phase, .capabilityUnavailable)
        XCTAssertNil(model.status.lastCompletedAt)
        XCTAssertEqual(model.status.uploadedEntryCount, 0)
        XCTAssertEqual(model.status.receivedEntryCount, 0)

        await model.setEnabled(false)

        XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(model.status.phase, .disabled)
    }

    func testOpeningSyncSettingsKeepsDeviceDisabledAndHistoryLocal()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: directory.appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x47, count: 32)
            )
        )
        let capture = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("A local note")
            )
        )
        let assignment = try await module.createTagDefinition(
            named: "Personal",
            assigningTo: capture.entryID
        )
        let model = ClipboardSyncSettingsModel(module: module)

        await model.refresh()

        XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(model.status.phase, .disabled)
        XCTAssertEqual(model.tags.map(\.id), [assignment.definition.id])
        XCTAssertEqual(model.tags.map(\.isSelected), [false])
        XCTAssertEqual(model.tags.map(\.eligibleEntryCount), [1])
        let entries = try await module.page(ClipboardHistoryQuery()).entries
        XCTAssertEqual(entries.map(\.id), [capture.entryID])
    }
}

private struct SettingsSyncLocalKeyStore: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Data(repeating: 0x51, count: 32))
    }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private struct UnavailableSettingsSyncKeys: ClipboardSyncKeyStoring {
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        throw ClipboardSyncServiceError.accessDenied
    }

    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        throw ClipboardSyncServiceError.accessDenied
    }
}

private actor HeldSettingsSyncTransport: ClipboardSyncTransport {
    private var accountRequest: CheckedContinuation<ClipboardSyncAccount, any Error>?

    var hasPendingAccount: Bool { accountRequest != nil }

    func account() async throws -> ClipboardSyncAccount {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { accountRequest = $0 }
    }

    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    func createControl(
        _ candidate: ClipboardSyncControl,
        for account: ClipboardSyncAccount
    ) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    func changes(
        for account: ClipboardSyncAccount,
        control: ClipboardSyncControl,
        cursor: Data?
    ) async throws -> ClipboardSyncChanges {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    func download(
        _ record: ClipboardSyncRemoteRecord,
        for account: ClipboardSyncAccount
    ) async throws -> [Data] {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    func commit(
        _ upload: ClipboardSyncUpload,
        for account: ClipboardSyncAccount,
        control: ClipboardSyncControl
    ) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    func cancel() async {
        accountRequest?.resume(throwing: CancellationError())
        accountRequest = nil
    }
}
