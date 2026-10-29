import ClipboardHistoryTestSupport
import AppKit
import Darwin
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncSettingsModelTests: XCTestCase {
    func testDormantAccountResetAllowsExplicitActivationAndClearOfAnotherAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let cloud = ResetSettingsSyncTransport()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory, keyStore: SettingsSyncLocalKeyStore(),
            syncServices: .init(transport: cloud, keys: UnavailableSettingsSyncKeys(), pollingInterval: nil)
        ))
        let model = ClipboardSyncSettingsModel(module: module)
        await model.setEnabled(true)
        try await waitForStatus(model) { model.status.canClearCloudData }
        await model.prepareReset()
        await model.confirmReset(try XCTUnwrap(model.resetConfirmation))
        XCTAssertTrue(model.isResetPending)
        XCTAssertFalse(model.canChangeEnabled)

        await cloud.switchAccount(to: "account-b")
        await model.retry()
        try await waitForStatus(model) { model.status.cloudReset?.failure == .failed(.accountChanged) }

        XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(model.status.cloudReset?.failure, .failed(.accountChanged))
        XCTAssertTrue(model.canChangeEnabled, "Settings must allow explicit activation of the new account")
        if model.canChangeEnabled { await model.setEnabled(true) }
        try await waitForStatus(model) { model.status.isEnabled && model.status.cloudReset == nil && model.status.canClearCloudData }
        XCTAssertTrue(model.status.isEnabled)
        XCTAssertNil(model.status.cloudReset)
        await model.prepareReset()
        await model.confirmReset(try XCTUnwrap(model.resetConfirmation))
        XCTAssertTrue(model.isResetPending)
        XCTAssertFalse(model.canChangeEnabled)

        await cloud.switchAccount(to: "reset-settings")
        await model.retry()
        try await waitForStatus(model) { model.status.cloudReset?.stage == .completed }
        XCTAssertEqual(model.status.cloudReset?.stage, .completed)
        await cloud.switchAccount(to: "account-b")
        let pendingB = await cloud.currentPhase()
        XCTAssertEqual(pendingB, "resetting")
        await model.retry()
        try await waitForStatus(model) { model.status.cloudReset?.stage == .completed }
        XCTAssertEqual(model.status.cloudReset?.stage, .completed)
        XCTAssertFalse(model.status.isEnabled)
    }

    func testDeniedWorkingFolderShowsLocalAccessGuidanceInSettingsAndFileControls() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-permission-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let working = root.appendingPathComponent("Working Copies")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(working.path, 0o500), 0)
        defer { _ = chmod(working.path, 0o700) }
        let services = ClipboardSyncServices(transport: SharingSettingsSyncTransport(),
            keys: SharingSettingsSyncKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: SettingsSyncLocalKeyStore(), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: SettingsSyncLocalKeyStore(), syncServices: services, testingSyncWorkingRoot: working))
        let source = root.appendingPathComponent("Source.txt")
        try Data("file permission guidance".utf8).write(to: source)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.permission-test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(source.absoluteString, forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let captured) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected an isolated file capture")
        }
        let tag = try await sender.createTagDefinition(named: "Files", assigningTo: captured.entryID).definition
        try await sender.setSyncTagSelected(tag.id, selected: true)
        try await sender.setSyncEnabled(true)
        let model = ClipboardSyncSettingsModel(module: receiver)

        await model.setEnabled(true)

        try await waitForStatus(model) { model.status.phase == .failed(.localFileAccessDenied) }
        XCTAssertEqual(model.status.phase, .failed(.localFileAccessDenied))
        XCTAssertEqual(model.status.phase.presentationMessageKey, .settingsClipboardSyncFileAccessDenied)
        XCTAssertNil(model.recoveryHelpURL)
        let page = try await receiver.page(.init())
        let failure = try XCTUnwrap(page.entries.first?.syncFiles.first?.transferFailure)
        XCTAssertEqual(failure, .localFileAccessDenied)
        XCTAssertEqual(failure.presentationMessageKey, .settingsClipboardSyncFileAccessDenied)
        XCTAssertNotEqual(L(failure.presentationMessageKey), L(.settingsClipboardSyncStorageFailure))
        XCTAssertNotEqual(L(failure.presentationMessageKey), L(.settingsClipboardSyncAccessDenied))
    }

    func testSettingsCanWithdrawAndRejoinTheLastTagWhileShowingItsLocalScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: directory,
            keyStore: SettingsSyncLocalKeyStore(), syncServices: .init(
                transport: SharingSettingsSyncTransport(), keys: SharingSettingsSyncKeys(), pollingInterval: nil)))
        let capture = try await module.capture(.init(source: .unknown, content: .text("settings retained copy")))
        let tag = try await module.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        let model = ClipboardSyncSettingsModel(module: module)
        await model.setEnabled(true)
        await model.selectTag(tag.id)
        try await waitForStatus(model) { model.tags.first?.withdrawalEntryCount == 1 }
        XCTAssertEqual(model.tags.first?.withdrawalEntryCount, 1)
        await model.selectTag(tag.id, selected: false)
        try await waitForStatus(model) { model.status.phase == .upToDate && model.status.withdrawnEntryCount == 1 }
        XCTAssertFalse(model.operationFailed)
        XCTAssertEqual(model.status.phase, .upToDate)
        XCTAssertEqual(model.status.withdrawnEntryCount, 1)
        XCTAssertEqual(model.tags.first?.rejoinEntryCount, 1)
        XCTAssertEqual(model.tags.first?.isSelected, false)
        await model.selectTag(tag.id)
        try await waitForStatus(model) { model.status.withdrawnEntryCount == 0 }
        XCTAssertEqual(model.status.withdrawnEntryCount, 0)
        XCTAssertEqual(model.tags.first?.isSelected, true)
        let retained = try await module.page(.init()).entries
        XCTAssertEqual(retained.map(\.id), [capture.entryID])
    }

    func testCloudResetConfirmationAndRetryRemainAvailableWithSyncOffAndKeysDenied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let cloud = ResetSettingsSyncTransport()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory, keyStore: SettingsSyncLocalKeyStore(),
            syncServices: .init(transport: cloud, keys: UnavailableSettingsSyncKeys(), pollingInterval: nil)
        ))
        let local = try await module.capture(.init(source: .unknown, content: .text("local history")))
        let model = ClipboardSyncSettingsModel(module: module)
        await model.setEnabled(true)
        try await waitForStatus(model) { model.status.canClearCloudData }
        await model.prepareReset()
        XCTAssertNotNil(model.resetConfirmation)
        model.cancelResetConfirmation()
        let before = await cloud.currentPhase()
        XCTAssertEqual(before, "active")
        await model.prepareReset()
        let confirmation = try XCTUnwrap(model.resetConfirmation)
        // SwiftUI dismisses the confirmation binding before the async action
        // necessarily runs. The selected token must survive that dismissal.
        model.cancelResetConfirmation()
        await model.confirmReset(confirmation)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertTrue(model.isResetPending)
        XCTAssertEqual(model.status.cloudReset?.failure, .failed(.network))
        await model.retry()
        try await waitForStatus(model) { model.status.cloudReset?.stage == .completed }
        XCTAssertEqual(model.status.cloudReset?.stage, .completed)
        XCTAssertFalse(model.isResetPending)
        let retained = try await module.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
    }

    func testDeniedKeyAccessOffersSystemRecoveryWithoutEnablingASecondAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: directory, keyStore: SettingsSyncLocalKeyStore(),
            syncServices: .init(transport: HeldSettingsSyncTransport(immediatelyAvailable: true),
                keys: UnavailableSettingsSyncKeys(), pollingInterval: nil)
        ))
        let local = try await module.capture(.init(source: .unknown, content: .text("local history stays available")))
        let model = ClipboardSyncSettingsModel(module: module)
        await model.setEnabled(true)
        try await waitForStatus(model) { model.status.phase == .accessDenied }
        XCTAssertEqual(model.status.phase, .accessDenied)
        XCTAssertEqual(model.recoveryHelpURL?.absoluteString,
            "https://support.apple.com/guide/security/secure-icloud-keychain-recovery-secdeb202947/web")
        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [local.entryID])
        await model.setEnabled(false)
        XCTAssertNil(model.recoveryHelpURL)
    }

    func testSameNameChoicesShowIdentityAndMergeRequiresDisplayedScopeConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: directory,
            keyStore: SettingsSyncLocalKeyStore(), syncServices: .init(
                transport: HeldSettingsSyncTransport(immediatelyAvailable: true), keys: UnavailableSettingsSyncKeys(), pollingInterval: nil)))
        let entry = try await module.capture(.init(source: .unknown, content: .text("newly enrolled")))
        _ = try await module.replaceTagDefinitions(with: [
            .init(id: "same-prefix-a", displayName: "Work"), .init(id: "same-prefix-b", displayName: "Work")])
        _ = try await module.apply(.setTags(entry.entryID, ["same-prefix-b"]))
        let model = ClipboardSyncSettingsModel(module: module)
        await model.setEnabled(true)
        await model.selectTag("same-prefix-a")
        XCTAssertEqual(Set(model.tags.map { model.tagTitle($0) }).count, 2)
        await model.prepareMerge(sourceID: "same-prefix-b", targetID: "same-prefix-a")
        XCTAssertEqual(model.mergePreview?.newlyEligibleEntryCount, 1)
        model.cancelMerge()
        await model.confirmMerge()
        let cancelled = try await module.tagDefinitions()
        XCTAssertEqual(cancelled.count, 2)
        await model.prepareMerge(sourceID: "same-prefix-b", targetID: "same-prefix-a")
        await model.confirmMerge()
        XCTAssertNil(model.mergePreview)
        XCTAssertEqual(model.tags.map(\.id), ["same-prefix-a"])
        let merged = try await module.page(.init()).entries
        XCTAssertEqual(merged.first?.tagIDs, ["same-prefix-a"])
    }

    func testMultipleTagChoicesRequireActivationAndSurviveDisablingThisMac()
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
        let other = try await module.createTagDefinition(named: "Other", assigningTo: capture.entryID)
        let model = ClipboardSyncSettingsModel(module: module)
        await model.refresh()

        await model.selectTag(assignment.definition.id)

        XCTAssertFalse(model.tags.contains(where: \.isSelected))
        await model.setEnabled(true)
        await model.selectTag(assignment.definition.id)
        XCTAssertEqual(model.tags.filter(\.isSelected).map(\.id), [assignment.definition.id])
        XCTAssertTrue(model.canSelectTag)
        await model.selectTag(other.definition.id)
        XCTAssertEqual(Set(model.tags.filter(\.isSelected).map(\.id)), [assignment.definition.id, other.definition.id])

        await model.setEnabled(false)
        let reopenedSettings = ClipboardSyncSettingsModel(module: module)
        await reopenedSettings.refresh()

        XCTAssertEqual(Set(reopenedSettings.tags.filter(\.isSelected).map(\.id)), [assignment.definition.id, other.definition.id])
        XCTAssertFalse(reopenedSettings.status.isEnabled)
        let entries = try await module.page(ClipboardHistoryQuery()).entries
        XCTAssertEqual(entries.first?.tagIDs, [assignment.definition.id, other.definition.id])
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

        try await waitForStatus(model) { model.status.phase == .capabilityUnavailable }
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

    /// Settings commands finish after admission. Observe the later public state
    /// without issuing another retry, which would change reset/failure behavior.
    private func waitForStatus(_ model: ClipboardSyncSettingsModel, until predicate: () -> Bool,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            await model.refresh()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Queued sync did not publish the expected Settings state", file: file, line: line)
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
    private let immediatelyAvailable: Bool

    init(immediatelyAvailable: Bool = false) { self.immediatelyAvailable = immediatelyAvailable }

    var hasPendingAccount: Bool { accountRequest != nil }

    func account() async throws -> ClipboardSyncAccount {
        try Task.checkCancellation()
        if immediatelyAvailable {
            return ClipboardSyncAccount(container: "test", environment: "test", owner: "recovery-test")
        }
        return try await withCheckedThrowingContinuation { accountRequest = $0 }
    }

    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        if immediatelyAvailable { return nil }
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

    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) throws -> Data {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func cancel() async {
        accountRequest?.resume(throwing: CancellationError())
        accountRequest = nil
    }
}

private actor ResetSettingsSyncTransport: ClipboardSyncTransport {
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }

    private var scope = ClipboardSyncAccount(container: "test", environment: "test", owner: "reset-settings")
    private var descriptors: [String: ClipboardSyncControl] = [:]
    private var failedCleanupAccounts = Set<String>()
    func switchAccount(to owner: String) {
        scope = .init(container: "test", environment: "test", owner: owner)
    }
    func account() -> ClipboardSyncAccount { scope }
    func currentPhase() -> String? { descriptors[scope.identifier]?.phase }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? {
        if descriptors[account.identifier] == nil {
            descriptors[account.identifier] = ClipboardSyncControl(accountID: account.identifier, keyID: UUID(), keyCheck: Data(repeating: 0, count: 32),
                epoch: UUID(), phase: "active", serverToken: Data([1]))
        }
        return descriptors[account.identifier]
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.corruptData
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        .init(records: [], cursor: nil, hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        throw ClipboardSyncServiceError.corruptData
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.corruptData
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID, for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        guard descriptors[account.identifier] == control, account == scope else { throw ClipboardSyncServiceError.conflict }
        let next = ClipboardSyncControl(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: epoch, phase: phase, serverToken: Data(UUID().uuidString.utf8))
        descriptors[account.identifier] = next
        return next
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) throws -> ClipboardSyncCleanupPage {
        if failedCleanupAccounts.insert(account.identifier).inserted {
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        return .init(control: control, cursor: nil, deletedRecordCount: 0, hasMore: false)
    }
    func cancel() {}
}

private actor SharingSettingsSyncKeys: ClipboardSyncKeyStoring {
    private var values: [UUID: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { values[keyID] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) -> Data {
        values[keyID] = key
        return key
    }
}

private actor SharingSettingsSyncTransport: ClipboardSyncTransport {
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
                    control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) throws -> Data {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    private var descriptor: ClipboardSyncControl?
    private var uploads: [ClipboardSyncUpload] = []
    func account() -> ClipboardSyncAccount { .init(container: "test", environment: "test", owner: "sharing-settings") }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? { descriptor }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        descriptor = candidate
        return candidate
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        .init(records: uploads.map(\.record), cursor: nil, hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        guard let upload = uploads.first(where: { $0.record.recordID == record.recordID }) else {
            throw ClipboardSyncServiceError.recordUnavailable
        }
        return upload.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        guard descriptor == control else { throw ClipboardSyncServiceError.conflict }
        uploads.append(upload)
        return advance(control)
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        guard descriptor == control else { throw ClipboardSyncServiceError.conflict }
        uploads.removeAll { $0.record.recordID == record.recordID }
        return advance(control)
    }
    private func advance(_ control: ClipboardSyncControl) -> ClipboardSyncControl {
        let next = ClipboardSyncControl(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: control.epoch, phase: control.phase, serverToken: Data(UUID().uuidString.utf8))
        descriptor = next
        return next
    }
    func cancel() {}
}
