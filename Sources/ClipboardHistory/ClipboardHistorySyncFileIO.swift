import CryptoKit
import Darwin
import Foundation

struct ClipboardSyncFileSource: Sendable {
    let entryID: String
    let itemIndex: Int
    let representationIndex: Int
    let name: String
    let bookmark: Data?
    let identity: Data?
    let provenance: String
}

struct ClipboardSyncFileSample: Sendable {
    let state: ClipboardSyncFileSourceState
    let byteCount: Int64?
    let bytes: Data?
    let url: URL?
    let bookmark: Data?
}

struct ClipboardSyncPublishedFile: Sendable {
    let url: URL
    let bookmark: Data
    let identity: Data
}

enum ClipboardSyncFileIO {
    static func isAvailable(path: String?, identity: Data?) -> Bool {
        guard let path, let identity else { return false }
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let current = values.fileResourceIdentifier as? NSObject,
              let expected = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSObject.self, NSData.self, NSString.self, NSNumber.self], from: identity
              ) as? NSObject else { return false }
        return current.isEqual(expected)
    }

    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    static func resolve(bookmark: Data, identity: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              let current = values.fileResourceIdentifier as? NSObject,
              let original = try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSObject.self, NSData.self, NSString.self, NSNumber.self], from: identity
              ) as? NSObject, current.isEqual(original) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return url
    }

    static func sample(_ source: ClipboardSyncFileSource) -> ClipboardSyncFileSample {
        let unavailable = ClipboardSyncFileSample(state: .sourceUnavailable, byteCount: nil,
            bytes: nil, url: nil, bookmark: nil)
        guard source.provenance == "ordinary" || source.provenance == "legacyUnverified",
              let bookmark = source.bookmark, let identity = source.identity else { return unavailable }
        do {
            let url = try resolve(bookmark: bookmark, identity: identity)
            var result: ClipboardSyncFileSample = unavailable
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) {
                coordinatedURL in
                do {
                    result = try sampleResolved(coordinatedURL, bookmark: bookmark, identity: identity)
                } catch {
                    result = unavailable
                }
            }
            return coordinationError == nil ? result : unavailable
        } catch { return unavailable }
    }

    private static func sampleResolved(_ url: URL, bookmark: Data, identity: Data) throws -> ClipboardSyncFileSample {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return ClipboardSyncFileSample(state: .unsupportedKind, byteCount: nil, bytes: nil, url: url, bookmark: bookmark)
        }
        guard before.st_size >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(EINVAL) }
        let count = Int64(before.st_size)
        guard count <= ClipboardHistoryModule.automaticSyncFileDownloadBytes else {
            // This is pending upload work for the streaming slice, not a size cap.
            return ClipboardSyncFileSample(state: .pendingUpload, byteCount: count, bytes: nil, url: url, bookmark: bookmark)
        }
        let bytes = try readSmallFile(descriptor, byteCount: Int(count))
        var after = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              try resolve(bookmark: bookmark, identity: identity).standardizedFileURL == url.standardizedFileURL,
              lstat(url.path, &pathStatus) == 0,
              pathStatus.st_dev == after.st_dev, pathStatus.st_ino == after.st_ino else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return ClipboardSyncFileSample(state: .available, byteCount: count, bytes: bytes, url: url, bookmark: bookmark)
    }

    private static func readSmallFile(_ descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < byteCount {
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, min($0.count, byteCount - data.count), off_t(data.count))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(count == 0 ? ESTALE : errno) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    /// The caller supplies completely authenticated bytes. No download fragment
    /// or decrypted background cache is ever written by this operation.
    static func publish(
        _ data: Data, descriptor: ClipboardSyncFileDescriptor, root: URL,
        accountID: String, faultInjector: ClipboardHistoryFaultInjector
    ) throws -> ClipboardSyncPublishedFile {
        guard validFilename(descriptor.displayName), descriptor.originalByteCount == Int64(data.count),
              descriptor.contentDigest == Data(SHA256.hash(data: data)),
              accountID.allSatisfy({ $0.isHexDigit }), accountID.count == 64 else {
            throw ClipboardSyncServiceError.corruptData
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(directory) }
        var url = root
        for component in [accountID, descriptor.objectID.uuidString.lowercased(), descriptor.versionID.uuidString.lowercased()] {
            if mkdirat(directory, component, 0o700) != 0, errno != EEXIST {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard fsync(directory) == 0 else {
                let failure = errno
                close(child)
                throw ClipboardHistoryStorageError.fileOperationFailed(failure)
            }
            close(directory)
            directory = child
            url.appendPathComponent(component, isDirectory: true)
        }
        let destination = url.appendingPathComponent(descriptor.displayName)
        var parent = stat()
        var parentPath = stat()
        guard fstat(directory, &parent) == 0, lstat(url.path, &parentPath) == 0,
              parent.st_dev == parentPath.st_dev, parent.st_ino == parentPath.st_ino else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let existing = openat(directory, descriptor.displayName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        var published = stat()
        if existing >= 0 {
            defer { close(existing) }
            var status = stat()
            guard fstat(existing, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_size == data.count,
                  try readSmallFile(existing, byteCount: data.count) == data else {
                throw ClipboardHistoryStorageError.fileOperationFailed(EEXIST)
            }
            guard fstat(existing, &published) == 0, unchangedFile(status, published) else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
        } else {
            guard errno == ENOENT else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            let pendingName = "Receiving-\(UUID().uuidString).partial"
            let pending = openat(directory, pendingName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard pending >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer {
                close(pending)
                _ = unlinkat(directory, pendingName, 0)
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = write(pending, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                    offset += count
                }
            }
            guard fcntl(pending, F_FULLFSYNC) == 0 || fsync(pending) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            try faultInjector.check(.syncFileBeforePublication)
            guard linkat(directory, pendingName, directory, descriptor.displayName, 0) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            guard unlinkat(directory, pendingName, 0) == 0, fsync(directory) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            guard fstat(pending, &published) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        guard lstat(url.path, &parentPath) == 0,
              parent.st_dev == parentPath.st_dev, parent.st_ino == parentPath.st_ino else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        var destinationStatus = stat()
        guard lstat(destination.path, &destinationStatus) == 0, unchangedFile(published, destinationStatus) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let values = try destination.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let identifier = values.fileResourceIdentifier as? NSObject else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let result = ClipboardSyncPublishedFile(url: destination,
            bookmark: try destination.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil),
            identity: try NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true))
        guard lstat(destination.path, &destinationStatus) == 0, unchangedFile(published, destinationStatus) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return result
    }

    private static func unchangedFile(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    }
}
