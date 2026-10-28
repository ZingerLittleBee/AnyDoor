import Darwin
import Foundation

/// Owns the creation root and resolves every later operation from those FDs.
/// Metadata never follows a candidate path that another process can replace.
final class ClipboardFileTreeOutput {
    private let parent: Int32
    private let name: String
    private var root: Int32 = -1

    init(destination: URL, parentDescriptor: Int32) throws {
        let handle = dup(parentDescriptor)
        guard handle >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var expected = stat(), atPath = stat()
        guard fstat(handle, &expected) == 0, lstat(destination.deletingLastPathComponent().path, &atPath) == 0,
              expected.st_dev == atPath.st_dev, expected.st_ino == atPath.st_ino else {
            close(handle)
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        parent = handle
        name = destination.lastPathComponent
    }

    deinit { if root >= 0 { close(root) }; close(parent) }

    func create(_ header: ClipboardFileTree.Header) throws -> Int32 {
        let directory = try parentFor(header.path)
        defer { close(directory) }
        let leaf = header.path.isEmpty ? name : String(header.path.split(separator: "/").last ?? "")
        let fd: Int32
        switch header.kind {
        case "directory":
            guard mkdirat(directory, leaf, 0o700) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            fd = openat(directory, leaf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        case "link":
            guard let link = header.link, symlinkat(link, directory, leaf) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            fd = openat(directory, leaf, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        default:
            fd = openat(directory, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var created = stat()
        let expectedKind = header.kind == "directory" ? S_IFDIR : header.kind == "link" ? S_IFLNK : S_IFREG
        guard fstat(fd, &created) == 0, created.st_mode & mode_t(S_IFMT) == mode_t(expectedKind) else {
            close(fd)
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        if header.path.isEmpty {
            root = dup(fd)
            guard root >= 0 else { close(fd); throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        return fd
    }

    func applyMetadata(_ header: ClipboardFileTree.Header, expected: ClipboardSyncFileSnapshot) throws {
        let fd: Int32
        if header.path.isEmpty { fd = dup(root) }
        else {
            let directory = try parentFor(header.path)
            defer { close(directory) }
            let leaf = String(header.path.split(separator: "/").last ?? "")
            fd = openat(directory, leaf, O_RDONLY | O_CLOEXEC | (header.kind == "link" ? O_SYMLINK : O_NOFOLLOW))
        }
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_dev == expected.device, status.st_ino == expected.inode,
              status.st_mode & mode_t(S_IFMT) == expected.mode & mode_t(S_IFMT) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        if header.kind != "link", fchmod(fd, mode_t(header.mode)) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: header.modifiedSeconds, tv_nsec: header.modifiedNanoseconds)]
        guard futimens(fd, &times) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        if header.kind != "link", fsync(fd) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
    }

    func snapshot() throws -> ClipboardSyncFileSnapshot {
        var current = stat(), path = stat()
        guard fstat(root, &current) == 0, fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == path.st_dev, current.st_ino == path.st_ino else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        return .init(current)
    }

    private func parentFor(_ path: String) throws -> Int32 {
        if path.isEmpty {
            let fd = dup(parent)
            guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            return fd
        }
        var fd = dup(root)
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        do {
            for component in path.split(separator: "/").dropLast() {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
}
