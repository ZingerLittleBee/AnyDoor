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
        guard lstat(path, &status) == 0,
              [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(status.st_mode & mode_t(S_IFMT)) else { return false }
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
            bytes: nil, url: nil, bookmark: source.bookmark)
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
        if try ClipboardFileTree.needsEncoding(url) {
            let measurement = try ClipboardFileTree(url).stream { _ in }
            return .init(state: .pendingUpload, byteCount: measurement.original, bytes: nil, url: url, bookmark: bookmark)
        }
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

}
