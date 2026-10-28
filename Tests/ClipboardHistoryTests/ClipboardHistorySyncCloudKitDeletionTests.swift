import CloudKit
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySyncCloudKitDeletionTests: XCTestCase {
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
