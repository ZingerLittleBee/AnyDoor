import CryptoKit
import Darwin
import Foundation
import GRDB

struct ClipboardWorkingOutputRemovalProof: Codable, Sendable {
    var snapshot: ClipboardSyncFileSnapshot
    let identity: ClipboardLinkedNativeIdentity
    let directoryMetadata: Data?
}

/// A deletion manifest is created only after the original ownership proof has
/// passed. Construction proofs remain intact until the manifest is complete.
enum ClipboardWorkingOutputRemoval {
    static func prepare(_ tree: ClipboardFileTree, record: ClipboardWorkingOutputRecord, database: DatabasePool) throws {
        try tree.forEachOwnershipEntry { path, snapshot in
            let fd = try tree.openOwnershipEntry(path, symlink: snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFLNK))
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard ClipboardSyncFileSnapshot(status) == snapshot,
                  let identity = try ClipboardLinkedNativeIdentity.read(url(path, record: record), status: status) else {
                throw ClipboardWorkingOutputChanged()
            }
            let metadata = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? try directoryMetadata(fd) : nil
            var after = stat()
            guard fstat(fd, &after) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard ClipboardSyncFileSnapshot(after) == snapshot else { throw ClipboardWorkingOutputChanged() }
            let proof = ClipboardWorkingOutputRemovalProof(snapshot: snapshot, identity: identity, directoryMetadata: metadata)
            try database.write { db in
                let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                    arguments: [record.id.uuidString, path])
                var member = try data.map { try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: $0) }
                    ?? .init(identity: identity, snapshot: snapshot, metadata: Data())
                member.removal = proof
                try db.execute(sql: """
                    INSERT INTO clipboard_working_output_members(owner_id, path, record) VALUES (?, ?, ?)
                    ON CONFLICT(owner_id, path) DO UPDATE SET record = excluded.record
                    """, arguments: [record.id.uuidString, path, try JSONEncoder().encode(member)])
            }
        }
        try tree.verify()
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_outputs WHERE id = ?",
                arguments: [record.id.uuidString]) else { throw ClipboardHistoryModuleError.operationUnavailable }
            var owner = try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: data)
            owner.removalStarted = true
            owner.reason = nil
            owner.replayDeclined = nil
            try db.execute(sql: "UPDATE clipboard_working_outputs SET record = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(owner), record.id.uuidString])
        }
    }

    static func resume(_ record: ClipboardWorkingOutputRecord, database: DatabasePool, parent: Int32,
        faults: ClipboardHistoryFaultInjector) throws {
        // Check the whole remaining namespace before deleting another member.
        // Missing rows, extra paths and an unlink without a durable checkpoint
        // are not repaired by taking a fresh snapshot.
        let tree = try ClipboardFileTree(record.url)
        var found = 0
        try tree.forEachOwnershipEntry { path, snapshot in
            let expected = try proof(path, record: record, database: database)
            guard snapshot == expected.snapshot else { throw ClipboardWorkingOutputChanged() }
            let fd = try tree.openOwnershipEntry(path, symlink: snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFLNK))
            defer { close(fd) }
            try verify(fd, path: path, expected: expected, record: record)
            found += 1
        }
        let count = try database.read { try Int.fetchOne($0,
            sql: "SELECT COUNT(*) FROM clipboard_working_output_members WHERE owner_id = ?", arguments: [record.id.uuidString]) }
        guard count == found, found > 0 else { throw ClipboardWorkingOutputChanged() }
        try tree.verify()
        let root = openat(parent, record.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard root >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(root) }
        while let path = try database.read({ try String.fetchOne($0,
            sql: "SELECT path FROM clipboard_working_output_members WHERE owner_id = ? ORDER BY path DESC LIMIT 1",
            arguments: [record.id.uuidString]) }) {
            // Once unlink succeeds, cancellation waits until its parent proof
            // and member retirement have committed in one transaction.
            try Task.checkCancellation()
            let expected = try proof(path, record: record, database: database)
            var pinnedParent = stat(), namedParent = stat(), namedRoot = stat()
            guard fstat(parent, &pinnedParent) == 0, lstat(record.directory.path, &namedParent) == 0,
                  fstatat(parent, record.name, &namedRoot, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            guard pinnedParent.st_dev == namedParent.st_dev, pinnedParent.st_ino == namedParent.st_ino,
                  namedRoot.st_ino == record.identity?.fileID,
                  Int64(namedRoot.st_birthtimespec.tv_sec) == record.identity?.birthSeconds,
                  Int64(namedRoot.st_birthtimespec.tv_nsec) == record.identity?.birthNanoseconds else {
                throw ClipboardWorkingOutputChanged()
            }
            let directory = try parentDescriptor(path, root: root, parent: parent, record: record, database: database)
            defer { close(directory) }
            let leaf = path.split(separator: "/").last.map(String.init) ?? record.name
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            let parentProof = path.isEmpty ? nil : try proof(parentPath, record: record, database: database)
            let isDirectory = expected.snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFDIR)
            while true {
                let fd = openat(directory, leaf, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                    | (expected.snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFLNK) ? O_SYMLINK : O_NOFOLLOW))
                guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                do { try verify(fd, path: path, expected: expected, record: record) }
                catch { close(fd); throw error }
                close(fd)
                var named = stat(), currentDirectory = stat()
                guard fstatat(directory, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(errno)
                }
                guard ClipboardSyncFileSnapshot(named) == expected.snapshot else { throw ClipboardWorkingOutputChanged() }
                if let parentProof {
                    guard fstat(directory, &currentDirectory) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                    guard ClipboardSyncFileSnapshot(currentDirectory) == parentProof.snapshot else { throw ClipboardWorkingOutputChanged() }
                }
                if unlinkat(directory, leaf, isDirectory ? AT_REMOVEDIR : 0) == 0 { break }
                let failure = errno
                if failure == EINTR { continue } // Reprove the exact name before retrying.
                // A new unowned child is never in the manifest and is never
                // unlinked. rmdir is the final atomic empty-directory check.
                if isDirectory, failure == ENOTEMPTY || failure == EEXIST { throw ClipboardWorkingOutputChanged() }
                throw ClipboardHistoryStorageError.fileOperationFailed(failure)
            }
            try faults.check(.workingOutputRemovalAfterUnlink)
            while fsync(directory) != 0 {
                if errno != EINTR { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            }
            var updatedParent: ClipboardWorkingOutputMember?
            if !path.isEmpty {
                var member = try read(parentPath, record: record, database: database)
                guard var previous = member.removal else { throw ClipboardWorkingOutputChanged() }
                var status = stat(), after = stat()
                guard fstat(directory, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                guard let identity = try ClipboardLinkedNativeIdentity.read(url(parentPath, record: record), status: status),
                      previous.identity.provesContinuity(with: identity), status.st_mode == previous.snapshot.mode,
                      try directoryMetadata(directory) == previous.directoryMetadata else { throw ClipboardWorkingOutputChanged() }
                guard fstat(directory, &after) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                guard ClipboardSyncFileSnapshot(status) == ClipboardSyncFileSnapshot(after) else { throw ClipboardWorkingOutputChanged() }
                previous.snapshot = .init(after)
                member.removal = previous
                updatedParent = member
            }
            try database.write { db in
                if let updatedParent {
                    var current = stat()
                    guard fstat(directory, &current) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                    guard ClipboardSyncFileSnapshot(current) == updatedParent.removal?.snapshot else { throw ClipboardWorkingOutputChanged() }
                    try db.execute(sql: "UPDATE clipboard_working_output_members SET record = ? WHERE owner_id = ? AND path = ?",
                        arguments: [try JSONEncoder().encode(updatedParent), record.id.uuidString, parentPath])
                }
                try db.execute(sql: "DELETE FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                    arguments: [record.id.uuidString, path])
            }
            try faults.check(.workingOutputRemovalAfterCheckpoint)
        }
    }

    private static func parentDescriptor(_ path: String, root: Int32, parent: Int32,
        record: ClipboardWorkingOutputRecord, database: DatabasePool) throws -> Int32 {
        var fd = dup(path.isEmpty ? parent : root)
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        do {
            if !path.isEmpty { try verify(fd, path: "", expected: proof("", record: record, database: database), record: record) }
            var prefix = ""
            for component in path.split(separator: "/").dropLast() {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                close(fd); fd = next
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                try verify(fd, path: prefix, expected: proof(prefix, record: record, database: database), record: record)
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func read(_ path: String, record: ClipboardWorkingOutputRecord,
        database: DatabasePool) throws -> ClipboardWorkingOutputMember {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                arguments: [record.id.uuidString, path]) else { throw ClipboardWorkingOutputChanged() }
            return try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: data)
        }
    }


    private static func proof(_ path: String, record: ClipboardWorkingOutputRecord,
        database: DatabasePool) throws -> ClipboardWorkingOutputRemovalProof {
        guard let proof = try read(path, record: record, database: database).removal else { throw ClipboardWorkingOutputChanged() }
        return proof
    }

    private static func verify(_ fd: Int32, path: String, expected: ClipboardWorkingOutputRemovalProof,
        record: ClipboardWorkingOutputRecord) throws {
        var status = stat(), after = stat()
        guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard ClipboardSyncFileSnapshot(status) == expected.snapshot,
              let identity = try ClipboardLinkedNativeIdentity.read(url(path, record: record), status: status),
              expected.identity.provesContinuity(with: identity) else { throw ClipboardWorkingOutputChanged() }
        if let metadata = expected.directoryMetadata {
            guard try directoryMetadata(fd) == metadata else { throw ClipboardWorkingOutputChanged() }
        }
        guard fstat(fd, &after) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard ClipboardSyncFileSnapshot(after) == expected.snapshot else { throw ClipboardWorkingOutputChanged() }
    }

    private static func url(_ path: String, record: ClipboardWorkingOutputRecord) -> URL {
        path.isEmpty ? record.url : record.url.appendingPathComponent(path)
    }

    /// Unlink changes a directory's timestamps, size and link count, but never
    /// its owner, flags, ACL or xattrs. Keep all local attributes, not only the
    /// portable subset used by the sync codec. No file bodies are read here.
    private static func directoryMetadata(_ fd: Int32) throws -> Data {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var hash = SHA256()
        for value in [UInt64(status.st_uid), UInt64(status.st_gid), UInt64(status.st_flags), UInt64(status.st_mode)] {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { hash.update(bufferPointer: $0) }
        }
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            hash.update(data: Data([1])) // An explicit ACL follows.
            let size = acl_size(acl)
            guard size >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            var bytes = try ClipboardFileMetadata.allocate(size)
            let copied = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
            guard copied >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            var length = UInt64(copied).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes.prefix(copied))
        } else {
            let failure = errno
            // Darwin reports no extended ACL as ENOENT even for this valid,
            // already-fstat'd descriptor. Do not confuse absence with failure.
            if failure == ENOENT { hash.update(data: Data([0])) }
            else if failure == ENOTSUP { hash.update(data: Data([2])) }
            else { throw ClipboardHistoryStorageError.fileOperationFailed(failure) }
        }
        let count = flistxattr(fd, nil, 0, 0)
        if count < 0, errno == ENOTSUP { return Data(hash.finalize()) }
        guard count >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var names = try ClipboardFileMetadata.allocate(count)
        if count > 0 {
            let actual = names.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0) }
            guard actual >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard actual == count else { throw ClipboardWorkingOutputChanged() }
        }
        for bytes in names.split(separator: 0).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let name = String(data: Data(bytes), encoding: .utf8) else { throw ClipboardWorkingOutputChanged() }
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            let value = try ClipboardFileMetadata.read(.init(name: name, size: Int64(size)), fd: fd)
            hash.update(data: Data(bytes)); hash.update(data: Data([0]))
            var length = UInt64(size).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: value)
        }
        return Data(hash.finalize())
    }
}
