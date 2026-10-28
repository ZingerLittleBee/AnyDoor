import Darwin
import Foundation

enum ClipboardFileMetadata {
    struct Attribute: Codable {
        let name: String
        let size: Int64
    }

    // Darwin's VFS maximum, not an application file-size cap. Ordinary xattrs
    // require one whole value; data/resource forks remain fixed-buffer streams.
    static let maximumAttributeBytes = Int(Int32.max)

    static func portable(_ name: String) -> Bool {
        !["com.apple.ResourceFork", "com.apple.decmpfs", "com.apple.system.Security", "com.apple.provenance",
          "com.apple.rootless", "com.apple.macl", "com.apple.fileprovider.fpfs#P", "com.apple.fileprovider.dir#N"].contains(name)
            && !name.hasPrefix("com.apple.fs.") && !name.hasPrefix("com.apple.fileprovider.")
    }

    static func attributes(fd: Int32) throws -> [Attribute] {
        let size = flistxattr(fd, nil, 0, 0)
        if size < 0, errno == ENOTSUP { return [] }
        guard size >= 0, size <= maximumAttributeBytes else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var names = try allocate(size)
        if size > 0 {
            guard names.withUnsafeMutableBytes({ flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0) }) == size else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
        }
        return try names.split(separator: 0).map { bytes in
            guard let name = String(bytes: bytes, encoding: .utf8), name.utf8.count <= 127 else {
                throw ClipboardSyncServiceError.accessDenied
            }
            return name
        }.filter(portable).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { name in
            let count = fgetxattr(fd, name, nil, 0, 0, 0)
            guard count >= 0, count <= maximumAttributeBytes else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            return Attribute(name: name, size: Int64(count))
        }
    }

    static func read(_ attribute: Attribute, fd: Int32) throws -> Data {
        guard attribute.size >= 0, attribute.size <= maximumAttributeBytes else { throw ClipboardSyncServiceError.corruptData }
        var value = try allocate(Int(attribute.size))
        let count = value.withUnsafeMutableBytes { fgetxattr(fd, attribute.name, $0.baseAddress, $0.count, 0, 0) }
        guard count == attribute.size else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        return value
    }

    static func allocate(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        guard count > 0, count <= maximumAttributeBytes, let pointer = malloc(count) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ENOMEM)
        }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .free)
    }

    static func fork(fd: Int32, writing: Bool = false) throws -> Int32? {
        let fork = openat(fd, "..namedfork/rsrc", (writing ? O_WRONLY | O_CREAT : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fork < 0, !writing, errno == ENOENT || errno == ENOATTR || errno == ENOTSUP { return nil }
        guard fork >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var fileStatus = stat(), forkStatus = stat()
        guard fstat(fd, &fileStatus) == 0, fstat(fork, &forkStatus) == 0,
              fileStatus.st_dev == forkStatus.st_dev, fileStatus.st_ino == forkStatus.st_ino,
              forkStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fork)
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return fork
    }

    static func forkSize(fd: Int32) throws -> Int64 {
        guard let fork = try fork(fd: fd) else { return 0 }
        defer { close(fork) }
        var status = stat()
        guard fstat(fork, &status) == 0, status.st_size >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        return status.st_size
    }
}
