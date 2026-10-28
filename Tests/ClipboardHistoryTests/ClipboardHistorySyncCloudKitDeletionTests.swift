import CloudKit
import Darwin
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySyncCloudKitDeletionTests: XCTestCase {
    func testLocalFileFailuresRemainDistinctFromProviderAccessAndQuotaFailures() {
        let local = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let cases: [(Error, ClipboardSyncServiceError)] = [
            (local, .localFileAccessDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .localFileAccessDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .localFileAccessDenied),
            (ClipboardHistoryStorageError.fileOperationFailed(EACCES), .localFileAccessDenied),
            (ClipboardHistoryStorageError.fileOperationFailed(ENOSPC), .localStorage),
            (ClipboardSyncServiceError.localStorage, .localStorage),
            (CKError(.permissionFailure, userInfo: [NSUnderlyingErrorKey: local]), .accessDenied),
            (CKError(.quotaExceeded, userInfo: [NSUnderlyingErrorKey: local]), .quota),
        ]
        for (error, expected) in cases {
            let result = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: [error], deleteErrors: [])
            XCTAssertEqual(result as? ClipboardSyncServiceError, expected)
        }
    }

    func testMissingDeletionTargetRetriesWithoutTreatingControlAsMissing() {
        let result = ClipboardSyncCloudKit.atomicModificationFailure(
            saveErrors: [CKError(.batchRequestFailed)], deleteErrors: [CKError(.unknownItem)])
        XCTAssertEqual(result as? ClipboardSyncServiceError, .conflict)
    }

    func testMissingControlAndDeniedAccessRemainFailuresDuringDeletion() {
        let missingControl = ClipboardSyncCloudKit.atomicModificationFailure(
            saveErrors: [CKError(.unknownItem)], deleteErrors: [CKError(.unknownItem)])
        XCTAssertEqual(missingControl as? ClipboardSyncServiceError, .missingRemoteState)
        let denied = ClipboardSyncCloudKit.atomicModificationFailure(
            saveErrors: [CKError(.permissionFailure)], deleteErrors: [CKError(.unknownItem)])
        XCTAssertEqual(denied as? ClipboardSyncServiceError, .accessDenied)
    }
}
