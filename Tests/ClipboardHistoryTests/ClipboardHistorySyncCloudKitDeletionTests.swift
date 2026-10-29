import CloudKit
import Darwin
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySyncCloudKitDeletionTests: XCTestCase {
    func testAtomicOutcomeAndRecordFailuresKeepTheLongestProviderDelay() {
        let short = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 15.0])
        let long = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 90.0])
        let outer = CKError(.partialFailure, userInfo: [CKErrorRetryAfterKey: 120.0,
            CKPartialErrorsByItemIDKey: ["busy": short, "batch": CKError(.batchRequestFailed)]])
        let wrapped = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: [short], deleteErrors: [], operationError: outer)
        XCTAssertEqual(wrapped as? ClipboardSyncServiceError, .network(retryAfter: 120))
        for failures in [[short, long], [long, short]] {
            let children = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: failures, deleteErrors: [])
            XCTAssertEqual(children as? ClipboardSyncServiceError, .network(retryAfter: 90))
        }
        let acrossSaveAndDelete = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: [short], deleteErrors: [long])
        XCTAssertEqual(acrossSaveAndDelete as? ClipboardSyncServiceError, .network(retryAfter: 90))
        let rejected = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: [short], deleteErrors: [],
            operationError: CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["cause": CKError(.serverRejectedRequest)]]))
        XCTAssertEqual(rejected as? ClipboardSyncServiceError, .providerRejected)
        let deferredConflict = ClipboardSyncCloudKit.atomicModificationFailure(saveErrors: [CKError(.serverRecordChanged)],
            deleteErrors: [], operationError: outer)
        XCTAssertEqual(deferredConflict as? ClipboardSyncServiceError, .network(retryAfter: 120),
            "A fresh CAS read must still wait when the atomic outcome supplies a provider deadline")
    }

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
