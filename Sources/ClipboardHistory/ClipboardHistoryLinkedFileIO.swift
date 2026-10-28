import CryptoKit
import Darwin
import Foundation

struct ClipboardLinkedFileProof: Sendable {
    let url: URL
    let bookmark: Data
    let identity: Data
    let digest: Data
    let byteCount: Int64
}

enum ClipboardLinkedFileIO {
    /// The input is already an authenticated complete version. This output is
    /// an ordinary, visible replacement beside the user's file, never a cache
    /// for unverified download bytes. Hash the bounded copy before publication.
    static func prepareReplacement(_ version: ClipboardSyncVerifiedFileVersion, at destination: URL) throws -> ClipboardLinkedFileProof {
        guard let digest = version.descriptor.contentDigest else { throw ClipboardSyncServiceError.corruptData }
        let source = try inspect(version.url, expectedIdentity: version.identity)
        guard source.digest == digest else { throw ClipboardSyncServiceError.corruptData }
        let url = destination.deletingLastPathComponent().appendingPathComponent(
            destination.lastPathComponent + " (AnyDoor update " + UUID().uuidString + ")")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: url) } }
        let input = open(version.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(input) }
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            if count == 0 { break }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBytes { write(output, $0.baseAddress?.advanced(by: written), count - written) }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                written += amount
            }
        }
        guard fsync(output) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let proof = try inspect(url)
        guard proof.digest == digest, proof.byteCount == version.descriptor.originalByteCount else {
            throw ClipboardSyncServiceError.corruptData
        }
        keep = true
        return proof
    }

    /// Exchange names atomically so the previous bytes survive until checked.
    /// A conflicting save is restored rather than discarded. The durable journal
    /// identifies both inodes if the process stops between exchange and commit.
    static func applyReplacement(_ replacement: ClipboardLinkedFileProof, to source: ClipboardLinkedLocationSource) throws -> ClipboardLinkedFileProof? {
        var error: NSError?
        var result: Result<ClipboardLinkedFileProof?, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source.url, options: [], error: &error) { destination in
            result = Result {
                let before = try inspectCoordinated(destination, expectedIdentity: source.identity)
                guard before.digest == source.baseDigest else { return nil }
                let prepared = try inspectCoordinated(replacement.url, expectedIdentity: replacement.identity)
                guard prepared.digest == replacement.digest else { throw ClipboardSyncServiceError.corruptData }
                try Task.checkCancellation()
                guard renamex_np(destination.path, replacement.url.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(errno)
                }
                let previous = try inspectCoordinated(replacement.url, expectedIdentity: source.identity)
                guard previous.digest == source.baseDigest else {
                    guard renamex_np(destination.path, replacement.url.path, UInt32(RENAME_SWAP)) == 0 else {
                        throw ClipboardHistoryStorageError.fileOperationFailed(errno)
                    }
                    return nil
                }
                return try inspectCoordinated(destination, expectedIdentity: replacement.identity)
            }
        }
        if let error { throw error }
        guard let result else { throw ClipboardHistoryModuleError.operationUnavailable }
        return try result.get()
    }

    /// Hashes an ordinary file in bounded memory without making a plaintext
    /// snapshot. The transfer owner freezes the body separately for publication.
    static func inspect(_ url: URL, expectedIdentity: Data? = nil) throws -> ClipboardLinkedFileProof {
        guard url.isFileURL else { throw ClipboardHistoryModuleError.invalidFileAssociation }
        var coordinationError: NSError?
        var result: Result<ClipboardLinkedFileProof, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try inspectCoordinated(coordinatedURL, expectedIdentity: expectedIdentity) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ClipboardHistoryModuleError.invalidFileAssociation }
        return try result.get()
    }

    private static func inspectCoordinated(_ coordinatedURL: URL, expectedIdentity: Data?) throws -> ClipboardLinkedFileProof {
        // URL resource values may cache the inode sampled before an exchange.
        // A new URL must prove the current path, including its new bookmark.
        var url = URL(fileURLWithPath: coordinatedURL.path)
        url.removeAllCachedResourceValues()
        let file = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size >= 0 else {
            throw ClipboardHistoryModuleError.invalidFileAssociation
        }
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let identifier = values.fileResourceIdentifier as? NSObject else {
            throw ClipboardHistoryModuleError.invalidFileAssociation
        }
        if let expectedIdentity {
            let expected = try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSObject.self, NSData.self, NSString.self, NSNumber.self], from: expectedIdentity
            ) as? NSObject
            guard identifier.isEqual(expected) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < before.st_size {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes {
                pread(file, $0.baseAddress, Int(min(Int64($0.count), before.st_size - offset)), off_t(offset))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(readCount == 0 ? ESTALE : errno) }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(readCount))) }
            offset += Int64(readCount)
        }
        var after = stat()
        var path = stat()
        guard fstat(file, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              path.st_dev == after.st_dev, path.st_ino == after.st_ino else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return ClipboardLinkedFileProof(url: url,
            bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil),
            identity: try NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true),
            digest: Data(hasher.finalize()), byteCount: offset)
    }
}
