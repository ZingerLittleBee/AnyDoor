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

    private static func inspectCoordinated(_ url: URL, expectedIdentity: Data?) throws -> ClipboardLinkedFileProof {
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
