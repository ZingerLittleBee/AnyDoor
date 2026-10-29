import CloudKit
import CryptoKit
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySyncCloudKitReadTests: XCTestCase {
    func testMissingReferencedChunkIsUnavailableForBothDownloadPaths() async throws {
        let cloud = ClipboardSyncCloudKit(recordReader: { _, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, .failure(CKError(.unknownItem))) })
        })
        let record = Self.remoteRecord()
        do {
            _ = try await cloud.download(record, for: Self.account)
            XCTFail("A missing referenced chunk must fail ordinary download")
        } catch {
            XCTAssertEqual(error as? ClipboardSyncServiceError, .recordUnavailable)
        }
        do {
            _ = try await cloud.downloadFileSegment(record, index: 0, for: Self.account)
            XCTFail("A missing referenced chunk must fail segmented download")
        } catch {
            XCTAssertEqual(error as? ClipboardSyncServiceError, .recordUnavailable)
        }
    }

    func testNativeDownloadsReadVerifiedAssetsAndRejectChangedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-cloud-asset-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try XCTUnwrap(AES.GCM.seal(Data("one complete encrypted unit".utf8),
            using: SymmetricKey(data: Data(repeating: 0x31, count: 32))).combined)
        let url = root.appendingPathComponent("asset")
        try bytes.write(to: url)
        let remote = Self.remoteRecord(bytes: bytes)
        let cloud = ClipboardSyncCloudKit(recordReader: { account, ids, keys in
            XCTAssertEqual(account, Self.account)
            XCTAssertTrue(keys.contains("asset"))
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, .success(Self.chunk(id: $0, remote: remote, index: 0, bytes: bytes, url: url)))
            })
        })
        let ordinary = try await cloud.download(remote, for: Self.account)
        let segmented = try await cloud.downloadFileSegment(remote, index: 0, for: Self.account)
        XCTAssertEqual(ordinary, [bytes])
        XCTAssertEqual(segmented, bytes)

        let malformed = ClipboardSyncCloudKit(recordReader: { _, ids, _ in
            let chunk = Self.chunk(id: ids[0], remote: remote, index: 1, bytes: bytes, url: url)
            return [ids[0]: .success(chunk)]
        })
        do {
            _ = try await malformed.downloadFileSegment(remote, index: 0, for: Self.account)
            XCTFail("A valid asset cannot replace the wrong immutable chunk")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .corruptData) }
    }

    func testMissingChunkDoesNotDowngradeOperationZoneOrControlFailures() async throws {
        let remote = Self.remoteRecord()
        for code: CKError.Code in [.unknownItem, .zoneNotFound, .userDeletedZone] {
            let operationFailure = ClipboardSyncCloudKit(recordReader: { _, _, _ in throw CKError(code) })
            do {
                _ = try await operationFailure.download(remote, for: Self.account)
                XCTFail("An operation failure must stop ordinary download")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
            do {
                _ = try await operationFailure.downloadFileSegment(remote, index: 0, for: Self.account)
                XCTFail("An operation failure must stop segmented download")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
        }
        for code: CKError.Code in [.zoneNotFound, .userDeletedZone] {
            let zoneFailure = ClipboardSyncCloudKit(recordReader: { _, ids, _ in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, .failure(CKError(code))) })
            })
            do {
                _ = try await zoneFailure.downloadFileSegment(remote, index: 0, for: Self.account)
                XCTFail("A zone failure must not be isolated as one missing chunk")
            } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
        }
        let mixedFailure = ClipboardSyncCloudKit(recordReader: { _, ids, _ in
            let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
                "chunk": CKError(.unknownItem), "zone": CKError(.zoneNotFound),
            ]])
            return [ids[0]: .failure(error)]
        })
        do {
            _ = try await mixedFailure.download(remote, for: Self.account)
            XCTFail("A nested missing item cannot hide collection failure")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
        do {
            _ = try await mixedFailure.downloadFileSegment(remote, index: 0, for: Self.account)
            XCTFail("A nested missing item cannot hide collection failure")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
        let missingControl = ClipboardSyncCloudKit(recordReader: { account, ids, keys in
            XCTAssertEqual(account, Self.account)
            XCTAssertEqual(ids.map(\.recordName), ["control.v1"])
            XCTAssertFalse(keys.contains("asset"))
            return [ids[0]: .failure(CKError(.unknownItem))]
        })
        let control = try await missingControl.control(for: Self.account)
        XCTAssertNil(control, "Optional authority absence must retain its existing bootstrap/recovery meaning")
        let missingZone = ClipboardSyncCloudKit(recordReader: { _, _, _ in throw CKError(.zoneNotFound) })
        let absentZoneControl = try await missingZone.control(for: Self.account)
        XCTAssertNil(absentZoneControl)
        let deletedZone = ClipboardSyncCloudKit(recordReader: { _, _, _ in throw CKError(.userDeletedZone) })
        do {
            _ = try await deletedZone.control(for: Self.account)
            XCTFail("A user-deleted collection still requires authority recovery")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .missingRemoteState) }
        let omitted = ClipboardSyncCloudKit(recordReader: { _, _, _ in [:] })
        do {
            _ = try await omitted.downloadFileSegment(remote, index: 0, for: Self.account)
            XCTFail("An incomplete provider result must not be treated as a missing record")
        } catch { XCTAssertEqual(error as? ClipboardSyncServiceError, .corruptData) }
    }

    func testCancelledNativeReadCannotReturnALateChunkResult() async throws {
        let held = NativeReadContinuation()
        let started = expectation(description: "External record read is held")
        let cloud = ClipboardSyncCloudKit(recordReader: { _, ids, _ in
            started.fulfill()
            await held.wait()
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, .failure(CKError(.unknownItem))) })
        })
        let requested = Task { try await cloud.downloadFileSegment(Self.remoteRecord(), index: 0, for: Self.account) }
        addTeardownBlock { await held.release(); _ = try? await requested.value }
        await fulfillment(of: [started], timeout: 2)
        await cloud.cancel()
        await held.release()
        do {
            _ = try await requested.value
            XCTFail("The cancelled generation must reject the late external result")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    static let account = ClipboardSyncAccount(container: ClipboardSyncNativeConfiguration.container,
        environment: ClipboardSyncNativeConfiguration.environment, owner: "native-read-fixture")

    static func remoteRecord(bytes: Data = Data("encrypted fixture unit".utf8)) -> ClipboardSyncRemoteRecord {
        .init(recordID: "fixture-body", operationID: UUID(), epoch: UUID(), keyID: UUID(), kind: .fileBody,
            chunkCount: 1, encryptedByteCount: Int64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
    }

    static func chunk(id: CKRecord.ID, remote: ClipboardSyncRemoteRecord, index: Int, bytes: Data, url: URL) -> CKRecord {
        let chunk = CKRecord(recordType: "ClipboardSyncChunkV1", recordID: id)
        chunk["operationID"] = remote.operationID.uuidString as NSString
        chunk["epoch"] = remote.epoch.uuidString as NSString
        chunk["keyID"] = remote.keyID.uuidString as NSString
        chunk["chunkIndex"] = index as NSNumber
        chunk["chunkDigest"] = Data(SHA256.hash(data: bytes)) as NSData
        chunk["asset"] = CKAsset(fileURL: url)
        return chunk
    }
}

private actor NativeReadContinuation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
