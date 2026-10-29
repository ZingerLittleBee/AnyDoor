import CryptoKit
import Darwin
import Foundation

extension ClipboardSyncFileTransfer {
    static func freezeTree(url: URL, bookmark: Data, identity: Data, directory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        objectID: UUID, versionID: UUID, faults: ClipboardHistoryFaultInjector) throws -> ClipboardSyncFrozenFile {
        guard try ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity).standardizedFileURL == url.standardizedFileURL else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let tree = try ClipboardFileTree(url)
        let measurement = try tree.stream { _ in }
        let unit = Int64(ClipboardSyncCodec.chunkByteCount)
        let count = measurement.encoded / unit + (measurement.encoded % unit == 0 ? 0 : 1)
        guard let chunks = Int(exactly: count) else { throw ClipboardSyncServiceError.localStorage }
        try cacheOperation {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        var buffer = Data()
        var index = 0
        var encryptedCount: Int64 = 0
        var hash = SHA256()
        func flush() throws {
            let encrypted = try ClipboardSyncCodec.sealFileSegment(buffer, account: account, control: control, key: key,
                objectID: objectID, versionID: versionID, originalByteCount: measurement.original,
                index: index, count: chunks, encodedByteCount: measurement.encoded)
            try persistFrozenSegment(encrypted, in: directory, index: index, faults: faults)
            hash.update(data: encrypted)
            encryptedCount = try ClipboardFileTree.add(encryptedCount, Int64(encrypted.count))
            buffer.removeAll(keepingCapacity: true)
            index += 1
        }
        let frozen = try tree.stream { data in
            var offset = 0
            while offset < data.count {
                let amount = min(ClipboardSyncCodec.chunkByteCount - buffer.count, data.count - offset)
                buffer.append(data[offset..<(offset + amount)])
                offset += amount
                if buffer.count == ClipboardSyncCodec.chunkByteCount { try flush() }
            }
        }
        if !buffer.isEmpty { try flush() }
        try faults.check(.syncFileTreeBeforeFreezeVerification)
        try tree.verify()
        guard frozen == measurement, index == chunks,
              try ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity).standardizedFileURL == url.standardizedFileURL else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        try cacheOperation { try syncDirectory(directory) }
        succeeded = true
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        return .init(upload: .init(record: .init(recordID: "v1-\(versionID.uuidString.lowercased())", operationID: versionID,
            epoch: control.epoch, keyID: control.keyID, kind: .fileBody, chunkCount: chunks,
            encryptedByteCount: encryptedCount, digest: Data(hash.finalize())), directory: directory),
            originalByteCount: measurement.original, contentDigest: measurement.digest,
            bodyFormat: .treeSegmentsV1, kind: status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? .directory : .file,
            encodedByteCount: measurement.encoded)
    }
}
