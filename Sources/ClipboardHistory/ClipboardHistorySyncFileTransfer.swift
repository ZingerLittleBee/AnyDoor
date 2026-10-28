import CryptoKit
import Darwin
import Foundation

struct ClipboardSyncFileUpload: Sendable {
    let record: ClipboardSyncRemoteRecord
    let directory: URL
}

struct ClipboardSyncFrozenFile: Sendable {
    let upload: ClipboardSyncFileUpload
    let originalByteCount: Int64
    let contentDigest: Data
    var bodyFormat: ClipboardSyncFileBodyFormat = .segmentsV1
    var kind: ClipboardSyncFileKind? = nil
    var encodedByteCount: Int64? = nil
}

/// Background persistence contains only bounded authenticated ciphertext units.
/// A URL identifies one immutable unit, never the user's original plaintext.
enum ClipboardSyncFileTransfer {
    static let maximumEncryptedSegmentBytes = ClipboardSyncCodec.chunkByteCount + 28

    static func segmentURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent("\(index).ciphertext")
    }

    static func readSegment(in directory: URL, index: Int) throws -> Data {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(parent) }
        let descriptor = openat(parent, "\(index).ciphertext", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor) }
        return try readEncryptedDescriptor(descriptor)
    }

    static func readAsset(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor) }
        return try readEncryptedDescriptor(descriptor)
    }

    private static func readEncryptedDescriptor(_ descriptor: Int32) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 28, status.st_size <= maximumEncryptedSegmentBytes else {
            throw ClipboardSyncServiceError.corruptData
        }
        return try read(descriptor, count: Int(status.st_size), offset: 0)
    }

    @concurrent
    static func freeze(url: URL, bookmark: Data, identity: Data, directory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        objectID: UUID, versionID: UUID, faults: ClipboardHistoryFaultInjector = .init()) async throws -> ClipboardSyncFrozenFile {
        var result: Result<ClipboardSyncFrozenFile, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                try freezeCoordinated(url: coordinated, bookmark: bookmark, identity: identity,
                    directory: directory, account: account, control: control, key: key,
                    objectID: objectID, versionID: versionID, faults: faults)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ClipboardSyncServiceError.localStorage }
        return try result.get()
    }

    private static func freezeCoordinated(url: URL, bookmark: Data, identity: Data, directory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        objectID: UUID, versionID: UUID, faults: ClipboardHistoryFaultInjector) throws -> ClipboardSyncFrozenFile {
        if try ClipboardFileTree.needsEncoding(url) {
            return try freezeTree(url: url, bookmark: bookmark, identity: identity, directory: directory,
                account: account, control: control, key: key, objectID: objectID, versionID: versionID, faults: faults)
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0 else { throw ClipboardSyncServiceError.accessDenied }
        guard try ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity).standardizedFileURL == url.standardizedFileURL else {
            throw ClipboardSyncServiceError.accessDenied
        }
        let size = Int64(before.st_size)
        let unit = Int64(ClipboardSyncCodec.chunkByteCount)
        let count = max(1, size / unit + (size % unit == 0 ? 0 : 1))
        guard let chunkCount = Int(exactly: count) else { throw ClipboardSyncServiceError.localStorage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        var plaintextDigest = SHA256()
        var ciphertextDigest = SHA256()
        var encryptedCount: Int64 = 0
        var offset: Int64 = 0
        for index in 0..<chunkCount {
            try Task.checkCancellation()
            let bytes = try read(descriptor, count: Int(min(unit, size - offset)), offset: offset)
            plaintextDigest.update(data: bytes)
            let encrypted = try ClipboardSyncCodec.sealFileSegment(bytes, account: account, control: control,
                key: key, objectID: objectID, versionID: versionID, originalByteCount: size,
                index: index, count: chunkCount)
            try persistSegment(encrypted, in: directory, index: index)
            ciphertextDigest.update(data: encrypted)
            let addition = encryptedCount.addingReportingOverflow(Int64(encrypted.count))
            guard !addition.overflow else { throw ClipboardSyncServiceError.localStorage }
            encryptedCount = addition.partialValue
            offset += Int64(bytes.count)
        }
        var after = stat()
        var atPath = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &atPath) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard sameSnapshot(before, after), sameSnapshot(after, atPath),
              try ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity).standardizedFileURL == url.standardizedFileURL else {
            throw ClipboardSyncServiceError.accessDenied
        }
        try syncDirectory(directory)
        succeeded = true
        return ClipboardSyncFrozenFile(upload: .init(record: .init(
            recordID: "v1-\(versionID.uuidString.lowercased())", operationID: versionID,
            epoch: control.epoch, keyID: control.keyID, kind: .fileBody, chunkCount: chunkCount,
            encryptedByteCount: encryptedCount, digest: Data(ciphertextDigest.finalize())
        ), directory: directory), originalByteCount: size, contentDigest: Data(plaintextDigest.finalize()))
    }

    static func persistSegment(_ bytes: Data, in directory: URL, index: Int) throws {
        guard bytes.count >= 28, bytes.count <= maximumEncryptedSegmentBytes else {
            throw ClipboardSyncServiceError.corruptData
        }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(parent) }
        let temporary = "\(UUID().uuidString).partial"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor); _ = unlinkat(parent, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(written == 0 ? EIO : errno) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard linkat(parent, temporary, parent, "\(index).ciphertext", 0) == 0,
              fsync(parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
    }

    static func removeSegment(in directory: URL, index: Int) throws {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(parent) }
        guard unlinkat(parent, "\(index).ciphertext", 0) == 0 || errno == ENOENT else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
    }

    private static func read(_ descriptor: Int32, count: Int, offset: Int64) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var filled = 0
            while filled < count {
                let received = pread(descriptor, buffer.baseAddress?.advanced(by: filled), count - filled, off_t(offset + Int64(filled)))
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(received == 0 ? EIO : errno) }
                filled += received
            }
        }
        return bytes
    }

    private static func sameSnapshot(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
