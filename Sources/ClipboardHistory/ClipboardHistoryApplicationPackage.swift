import Darwin
import Foundation

enum ClipboardApplicationPackage {
    static func isApplication(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        if url.pathExtension.lowercased() == "app" { return true }
        return (try? information(at: url)["CFBundlePackageType"] as? String) == "APPL"
    }

    /// Read only the small package declaration through no-follow descriptors.
    /// This is classification, never a substitute for the complete tree proof.
    static func information(at url: URL) throws -> [String: Any] {
        let root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(root) }
        let contents = openat(root, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(contents) }
        let info = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard info >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(info) }
        var status = stat()
        guard fstat(info, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0, status.st_size <= 1_024 * 1_024 else { throw ClipboardHistoryModuleError.operationUnavailable }
        var bytes = Data(count: Int(status.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pread(info, $0.baseAddress?.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(count == 0 ? ESTALE : errno) }
            offset += count
        }
        guard let values = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return values
    }
}
