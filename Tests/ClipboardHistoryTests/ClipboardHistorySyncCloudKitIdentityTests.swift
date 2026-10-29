import CloudKit
import Foundation
import os
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySyncCloudKitIdentityTests: XCTestCase {
    func testDefaultOwnerControlResponseRetainsSystemFieldsForConcreteOwnerCASResponse() async throws {
        let fixture = NativeIdentityFixture()
        let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
        let observed = try await cloud.control(for: fixture.account)
        let control = try XCTUnwrap(observed)
        XCTAssertEqual(control.accountID, fixture.account.identifier)
        XCTAssertEqual(control.epoch, fixture.epoch)
        let nextEpoch = UUID()
        let transitioned = try await cloud.transition(control, to: "resetting", epoch: nextEpoch, for: fixture.account)
        XCTAssertEqual(transitioned.phase, "resetting")
        XCTAssertEqual(transitioned.epoch, nextEpoch)
        XCTAssertEqual(transitioned.keyID, control.keyID)
        XCTAssertEqual(fixture.savedControlOwners(), [CKCurrentUserDefaultName],
            "The CAS must reuse the server system fields rather than construct a new concrete-owner record")
    }

    func testKnownOwnerAliasDoesNotAdmitForeignCallbackOrRecordIdentity() async throws {
        for fault in NativeIdentityFixture.IdentityFault.allCases {
            let fixture = NativeIdentityFixture(fault: fault)
            let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
            do {
                _ = try await cloud.control(for: fixture.account)
                XCTFail("Foreign native identity must fail: \(fault)")
            } catch {
                XCTAssertEqual(error as? ClipboardSyncServiceError, fault.expectedFailure, "\(fault)")
            }
            XCTAssertTrue(fixture.savedControlOwners().isEmpty)
        }
    }

    func testConcreteAccountChangeAndForeignSystemFieldsRejectCAS() async throws {
        let fixture = NativeIdentityFixture()
        let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
        let observed = try await cloud.control(for: fixture.account)
        let control = try XCTUnwrap(observed)
        fixture.setAccountOwner("another-concrete-owner")
        do {
            _ = try await cloud.transition(control, to: "resetting", epoch: UUID(), for: fixture.account)
            XCTFail("An alias cannot bridge concrete account changes")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .accountChanged) }
        fixture.setAccountOwner(fixture.account.owner)
        let foreign = NativeIdentityFixture(account: .init(container: fixture.account.container,
            environment: fixture.account.environment, owner: "another-concrete-owner"))
        let foreignCloud = ClipboardSyncCloudKit(nativeOperations: foreign.operations)
        let foreignObserved = try await foreignCloud.control(for: foreign.account)
        let foreignControl = try XCTUnwrap(foreignObserved)
        let wrongToken = ClipboardSyncControl(accountID: control.accountID, keyID: control.keyID,
            keyCheck: control.keyCheck, epoch: control.epoch, phase: control.phase, serverToken: foreignControl.serverToken)
        do {
            _ = try await cloud.transition(wrongToken, to: "resetting", epoch: UUID(), for: fixture.account)
            XCTFail("A default-owner token from another account-scoped zone cannot authorize CAS")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .corruptData) }
        XCTAssertTrue(fixture.savedControlOwners().isEmpty)
    }

    func testNativeAssetCallbacksUseOwnerAliasForBothDownloadPaths() async throws {
        let account = ClipboardHistorySyncCloudKitReadTests.account
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-alias-assets-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("opaque encrypted asset returned by the native provider".utf8)
        let url = root.appendingPathComponent("asset")
        try bytes.write(to: url)
        let remote = ClipboardHistorySyncCloudKitReadTests.remoteRecord(bytes: bytes)
        let cloud = ClipboardSyncCloudKit(nativeOperations: .init(accountOwner: { account.owner }, add: { operation in
            guard let fetch = operation as? CKFetchRecordsOperation else {
                XCTFail("Unexpected native operation: \(type(of: operation))")
                return
            }
            for requested in fetch.recordIDs ?? [] {
                let returned = CKRecord.ID(recordName: requested.recordName,
                    zoneID: CKRecordZone.ID(zoneName: requested.zoneID.zoneName, ownerName: CKCurrentUserDefaultName))
                let chunk = ClipboardHistorySyncCloudKitReadTests.chunk(id: returned, remote: remote,
                    index: 0, bytes: bytes, url: url)
                fetch.perRecordResultBlock?(returned, .success(chunk))
            }
            fetch.fetchRecordsResultBlock?(.success(()))
        }))
        let ordinary = try await cloud.download(remote, for: account)
        let segmented = try await cloud.downloadFileSegment(remote, index: 0, for: account)
        XCTAssertEqual(ordinary, [bytes])
        XCTAssertEqual(segmented, bytes)
    }

    func testChangePageRejectsForeignRecordCallbackDespiteLocalValueAndLaterFailure() async throws {
        for fault: NativeIdentityFixture.IdentityFault in [.callbackOwner, .callbackZone, .callbackName] {
            let fixture = NativeIdentityFixture(fault: fault, callbackBoundary: .changedRecord)
            let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
            let observed = try await cloud.control(for: fixture.account)
            let control = try XCTUnwrap(observed)
            do {
                _ = try await cloud.changes(for: fixture.account, control: control, cursor: nil)
                XCTFail("A local record value cannot authorize a foreign change callback key")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, fault.expectedFailure) }
        }
    }

    func testChangePageRejectsForeignZoneCallbackBeforeLaterFailure() async throws {
        for fault: NativeIdentityFixture.IdentityFault in [.callbackOwner, .callbackZone] {
            let fixture = NativeIdentityFixture(fault: fault, callbackBoundary: .changedZone)
            let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
            let observed = try await cloud.control(for: fixture.account)
            let control = try XCTUnwrap(observed)
            do {
                _ = try await cloud.changes(for: fixture.account, control: control, cursor: nil)
                XCTFail("A foreign zone callback cannot be hidden by a later network failure")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .accountChanged) }
        }
    }

    func testZoneCreationRejectsForeignCallbackBeforeLaterSuccessOrOutcome() async throws {
        for fault: NativeIdentityFixture.IdentityFault in [.callbackOwner, .callbackZone] {
            let fixture = NativeIdentityFixture(fault: fault, callbackBoundary: .savedZone)
            let cloud = ClipboardSyncCloudKit(nativeOperations: fixture.operations)
            let candidate = ClipboardSyncControl(accountID: fixture.account.identifier, keyID: UUID(),
                keyCheck: Data(repeating: 0x51, count: 32), epoch: UUID(), phase: "active", serverToken: nil)
            do {
                _ = try await cloud.createControl(candidate, for: fixture.account)
                XCTFail("A foreign zone callback must not be replaced by subsequent successful callbacks")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .accountChanged) }
            XCTAssertTrue(fixture.savedControlOwners().isEmpty)
        }
    }

    func testZoneFailureWithoutItemCallbacksKeepsTheProviderError() async throws {
        let account = ClipboardHistorySyncCloudKitReadTests.account
        let cloud = ClipboardSyncCloudKit(nativeOperations: .init(accountOwner: { account.owner }, add: { operation in
            if let zones = operation as? CKModifyRecordZonesOperation {
                zones.modifyRecordZonesResultBlock?(.failure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 120.0])))
            } else if let fetch = operation as? CKFetchRecordsOperation {
                for id in fetch.recordIDs ?? [] { fetch.perRecordResultBlock?(id, .failure(CKError(.unknownItem))) }
                fetch.fetchRecordsResultBlock?(.success(()))
            } else { XCTFail("Unexpected native operation: \(type(of: operation))") }
        }))
        let candidate = ClipboardSyncControl(accountID: account.identifier, keyID: UUID(),
            keyCheck: Data(repeating: 0x51, count: 32), epoch: UUID(), phase: "active", serverToken: nil)
        do {
            _ = try await cloud.createControl(candidate, for: account)
            XCTFail("A callback-free provider failure cannot become missing result corruption")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .network(retryAfter: 120)) }
    }
}

private final class NativeIdentityFixture: Sendable {
    enum IdentityFault: CaseIterable, Sendable {
        case callbackOwner, callbackZone, callbackName, recordOwner, recordZone, recordName, accountField

        var expectedFailure: ClipboardSyncServiceError {
            switch self {
            case .callbackOwner, .callbackZone, .recordOwner, .recordZone: .accountChanged
            case .callbackName, .recordName, .accountField: .corruptData
            }
        }
    }
    enum CallbackBoundary: Sendable { case changedRecord, changedZone, savedZone }

    let account: ClipboardSyncAccount
    let epoch = UUID()
    private let keyID = UUID()
    private let savedOwners = OSAllocatedUnfairLock(initialState: [String]())
    private let currentOwner: OSAllocatedUnfairLock<String>
    private let fault: IdentityFault?
    private let callbackBoundary: CallbackBoundary?

    init(account: ClipboardSyncAccount = ClipboardHistorySyncCloudKitReadTests.account, fault: IdentityFault? = nil,
         callbackBoundary: CallbackBoundary? = nil) {
        self.account = account
        self.currentOwner = OSAllocatedUnfairLock(initialState: account.owner)
        self.fault = fault
        self.callbackBoundary = callbackBoundary
    }

    var operations: ClipboardSyncCloudKit.NativeOperations {
        .init(accountOwner: { self.currentOwner.withLock { $0 } }, add: { self.add($0) })
    }

    func savedControlOwners() -> [String] { savedOwners.withLock { $0 } }
    func setAccountOwner(_ value: String) { currentOwner.withLock { $0 = value } }

    private func responseID(_ requested: CKRecord.ID, callback: Bool, applyFault: Bool = true) -> CKRecord.ID {
        let wrongOwner = applyFault && fault == (callback ? .callbackOwner : .recordOwner)
        let wrongZone = applyFault && fault == (callback ? .callbackZone : .recordZone)
        let wrongName = applyFault && fault == (callback ? .callbackName : .recordName)
        return CKRecord.ID(recordName: wrongName ? "another-record" : requested.recordName,
            zoneID: CKRecordZone.ID(zoneName: wrongZone ? "another-zone" : requested.zoneID.zoneName,
                ownerName: wrongOwner ? "another-concrete-owner" : CKCurrentUserDefaultName))
    }

    private func controlRecord(_ id: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "ClipboardSyncControlV1", recordID: id)
        record["protocolVersion"] = 1 as NSNumber
        record["accountID"] = (fault == .accountField ? "another-account" : account.identifier) as NSString
        record["keyID"] = keyID.uuidString as NSString
        record["keyCheck"] = Data(repeating: 0x51, count: 32) as NSData
        record["epoch"] = epoch.uuidString as NSString
        record["phase"] = "active" as NSString
        return record
    }

    private func add(_ operation: CKDatabaseOperation) {
        switch operation {
        case let fetch as CKFetchRecordsOperation:
            for id in fetch.recordIDs ?? [] {
                let alias = responseID(id, callback: true, applyFault: callbackBoundary == nil)
                let record = controlRecord(responseID(id, callback: false, applyFault: callbackBoundary == nil))
                fetch.perRecordResultBlock?(alias, .success(record))
            }
            fetch.fetchRecordsResultBlock?(.success(()))
        case let modify as CKModifyRecordsOperation:
            XCTAssertEqual(modify.savePolicy, .ifServerRecordUnchanged)
            XCTAssertTrue(modify.isAtomic)
            for record in modify.recordsToSave ?? [] {
                savedOwners.withLock { $0.append(record.recordID.zoneID.ownerName) }
                let concrete = CKRecord.ID(recordName: record.recordID.recordName,
                    zoneID: CKRecordZone.ID(zoneName: record.recordID.zoneID.zoneName, ownerName: account.owner))
                let returned = CKRecord(recordType: record.recordType, recordID: concrete)
                for key in record.allKeys() { returned[key] = record[key] }
                modify.perRecordSaveBlock?(concrete, .success(returned))
            }
            modify.modifyRecordsResultBlock?(.success(()))
        case let changes as CKFetchRecordZoneChangesOperation:
            guard let zone = changes.recordZoneIDs?.first else { return XCTFail("Missing requested zone") }
            let requested = CKRecord.ID(recordName: "control.v1", zoneID: zone)
            if callbackBoundary == .changedRecord {
                let valid = controlRecord(responseID(requested, callback: false, applyFault: false))
                changes.recordWasChangedBlock?(responseID(requested, callback: true), .success(valid))
                changes.recordWasChangedBlock?(valid.recordID, .success(valid))
            } else {
                changes.recordZoneFetchResultBlock?(responseID(requested, callback: true).zoneID, .failure(CKError(.networkFailure)))
            }
            changes.recordZoneFetchResultBlock?(zone, .failure(CKError(.networkFailure)))
            changes.fetchRecordZoneChangesResultBlock?(.failure(CKError(.networkFailure)))
        case let zones as CKModifyRecordZonesOperation:
            guard let requested = zones.recordZonesToSave?.first?.zoneID else { return XCTFail("Missing saved zone") }
            let id = CKRecord.ID(recordName: "control.v1", zoneID: requested)
            let valid = CKRecordZone(zoneID: requested)
            zones.perRecordZoneSaveBlock?(responseID(id, callback: true).zoneID, .success(valid))
            zones.perRecordZoneSaveBlock?(requested, .success(valid))
            zones.modifyRecordZonesResultBlock?(.failure(CKError(.networkFailure)))
        default:
            XCTFail("Unexpected native operation: \(type(of: operation))")
        }
    }
}
