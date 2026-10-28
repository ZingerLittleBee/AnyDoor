import CryptoKit
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
            let read = names.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0) }
            guard read >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard read == size else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
        }
        return try names.split(separator: 0).map { bytes in
            guard let name = String(bytes: bytes, encoding: .utf8), name.utf8.count <= 127 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
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
        guard count >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
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
        guard fstat(fd, &fileStatus) == 0, fstat(fork, &forkStatus) == 0 else {
            let code = errno
            close(fork)
            throw ClipboardHistoryStorageError.fileOperationFailed(code)
        }
        guard fileStatus.st_dev == forkStatus.st_dev, fileStatus.st_ino == forkStatus.st_ino,
              forkStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fork)
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return fork
    }

    static func forkSize(fd: Int32) throws -> Int64 {
        var file = stat()
        guard fstat(fd, &file) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        // Compressed backing forks are storage, not the logical resource fork.
        if file.st_flags & UInt32(UF_COMPRESSED) != 0 { return 0 }
        guard let fork = try fork(fd: fd) else { return 0 }
        defer { close(fork) }
        var status = stat()
        guard fstat(fork, &status) == 0, status.st_size >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        return status.st_size
    }

    static func fingerprint(fd: Int32) throws -> Data {
        var hash = SHA256()
        func number(_ value: Int64) { var big = value.bigEndian; withUnsafeBytes(of: &big) { hash.update(bufferPointer: $0) } }
        let values = try attributes(fd: fd)
        number(Int64(values.count))
        for attribute in values {
            try Task.checkCancellation()
            hash.update(data: Data(attribute.name.utf8)); hash.update(data: Data([0]))
            number(attribute.size)
            hash.update(data: try read(attribute, fd: fd))
        }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let size = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) ? try forkSize(fd: fd) : 0
        number(size)
        if size > 0, let fork = try fork(fd: fd) {
            defer { close(fork) }
            try ClipboardFileTree.read(fork, size: size) { hash.update(data: $0) }
        }
        return Data(hash.finalize())
    }
}
