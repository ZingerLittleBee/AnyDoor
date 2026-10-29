import CryptoKit
import Darwin
import Foundation
import GRDB
import os

public struct ClipboardHistoryWorkingOutputRecovery: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let reason: Reason

    public enum Reason: String, Codable, Sendable {
        case incomplete
        case changed
        case unavailable
    }
}

private struct ClipboardWorkingOutputRecord: Codable, Sendable {
    let id: UUID
    let directory: URL
    let name: String
    let parent: ClipboardLinkedNativeIdentity
    var identity: ClipboardLinkedNativeIdentity?
    var snapshot: ClipboardSyncFileSnapshot?
    var fingerprint: Data?
    var completed: Bool = false
    var reason: ClipboardHistoryWorkingOutputRecovery.Reason?
    var descriptor: ClipboardSyncFileDescriptor?
    var replayDeclined: Bool?
    var url: URL { directory.appendingPathComponent(name) }
}

struct ClipboardWorkingOutputRecoveryRequired: Error {}

/// One empty advisory-lock file belongs to the encrypted store. A shared lease
/// covers construction through discard, including other processes; recovery
/// takes an exclusive lease and never waits on an active producer.
final class ClipboardWorkingOutputLease: Sendable {
    static let fileName = "working-output.lock"
    private let descriptor: Int32

    init?(root: URL, exclusive: Bool) throws {
        let fd = open(root.appendingPathComponent(Self.fileName).path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        do { try Self.validate(fd) } catch { close(fd); throw error }
        if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { return nil }
            throw ClipboardHistoryStorageError.fileOperationFailed(failure)
        }
        descriptor = fd
    }

    /// Store replacement may remove this exact empty sidecar only while no
    /// constructor or recovery owns it. Ordinary lease release never unlinks it.
    static func forStoreReplacement(at root: URL) throws -> ClipboardWorkingOutputLease? {
        var status = stat()
        if lstat(root.path, &status) != 0 {
            if errno == ENOENT { return nil }
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ENOTDIR)
        }
        // Older stores may have no sidecar yet. Creating it is part of taking
        // the barrier, not evidence that there cannot be a concurrent producer.
        guard let lease = try ClipboardWorkingOutputLease(root: root, exclusive: true) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return lease
    }

    static func validateArtifact(at root: URL) throws {
        let fd = open(root.appendingPathComponent(fileName).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return }
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(fd) }
        try validate(fd)
    }

    private static func validate(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size == 0, status.st_nlink == 1 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(EEXIST)
        }
    }

    func removeArtifact(at root: URL) throws {
        try Self.validate(descriptor)
        var owned = stat(), current = stat()
        let url = root.appendingPathComponent(Self.fileName)
        guard fstat(descriptor, &owned) == 0, lstat(url.path, &current) == 0,
              ClipboardSyncFileSnapshot(owned) == ClipboardSyncFileSnapshot(current) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        guard unlink(url.path) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
    }

    deinit { close(descriptor) }
}

/// Short journal writes share the store's serialized writer. Construction and
/// proof reads stay on the I/O executor, without retaining the module actor.
struct ClipboardWorkingOutputJournal: Sendable {
    let database: DatabasePool
    let storeRoot: URL

    func recover() throws { _ = try ClipboardWorkingOutputOwner.recoverAllSynchronously(in: database, root: storeRoot) }

    func reserve(directory: Int32, url: URL, descriptor: ClipboardSyncFileDescriptor) throws -> ClipboardWorkingOutputOwner {
        try ClipboardWorkingOutputOwner(database: database, storeRoot: storeRoot, directory: directory, url: url, descriptor: descriptor)
    }

    func recover(directory: URL, descriptor: ClipboardSyncFileDescriptor,
        verify: @escaping (ClipboardWorkingOutputReplay) throws -> Void) throws {
        try ClipboardWorkingOutputOwner.recoverAuthenticated(in: database, root: storeRoot,
            directory: directory, descriptor: descriptor, verify: verify)
    }
}

final class ClipboardWorkingOutputOwner: Sendable {
    static let progressByteCount: Int64 = 4 * 1_024 * 1_024
    private let database: DatabasePool
    private let lease: ClipboardWorkingOutputLease
    private let rootDescriptor = OSAllocatedUnfairLock(initialState: Int32(-1))
    let id: UUID
    let directory: URL
    let name: String

    fileprivate init(database: DatabasePool, storeRoot: URL, directory: Int32, url: URL,
        descriptor: ClipboardSyncFileDescriptor) throws {
        guard let lease = try ClipboardWorkingOutputLease(root: storeRoot, exclusive: false) else {
            throw ClipboardWorkingOutputRecoveryRequired()
        }
        self.lease = lease
        var status = stat(), atPath = stat()
        guard let resolved = realpath(url.path, nil) else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved))
        guard fstat(directory, &status) == 0, lstat(canonical.path, &atPath) == 0,
              status.st_dev == atPath.st_dev, status.st_ino == atPath.st_ino,
              let parent = try ClipboardLinkedNativeIdentity.read(canonical, status: status) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        self.database = database
        id = UUID()
        self.directory = canonical
        name = "Receiving-\(id.uuidString).partial"
        let record = ClipboardWorkingOutputRecord(id: id, directory: canonical, name: name, parent: parent, descriptor: descriptor)
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_working_outputs WHERE directory = ?)",
                arguments: [canonical.path]) != true else { throw ClipboardWorkingOutputRecoveryRequired() }
            try db.execute(sql: "INSERT INTO clipboard_working_outputs(id, directory, record) VALUES (?, ?, ?)",
                arguments: [id.uuidString, canonical.path, try JSONEncoder().encode(record)])
        }
    }

    deinit { let fd = rootDescriptor.withLock { $0 }; if fd >= 0 { close(fd) } }

    func created(_ descriptor: Int32) throws {
        var status = stat(), atPath = stat()
        let url = directory.appendingPathComponent(name)
        guard fstat(descriptor, &status) == 0, lstat(url.path, &atPath) == 0,
              status.st_dev == atPath.st_dev, status.st_ino == atPath.st_ino,
              let identity = try ClipboardLinkedNativeIdentity.read(url, status: status) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let pinned = dup(descriptor)
        guard pinned >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        rootDescriptor.withLock { $0 = pinned }
        let tree = try ClipboardFileTree(url)
        guard try tree.verify() == ClipboardSyncFileSnapshot(status) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        let fingerprint = try tree.ownershipFingerprint()
        guard try tree.verify() == ClipboardSyncFileSnapshot(status) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        try update { $0.identity = identity; $0.snapshot = .init(status); $0.fingerprint = fingerprint }
        try memberCreated(path: "", descriptor: descriptor)
    }

    func willCreateMember(path: String, parent: Int32) throws {
        guard !path.isEmpty else { return }
        let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
        var status = stat()
        guard fstat(parent, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                arguments: [id.uuidString, parentPath]) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
            let member = try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: data)
            guard ClipboardSyncFileSnapshot(status) == member.checkpoint else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        }
    }

    func memberCreated(path: String, descriptor: Int32, parent: Int32? = nil) throws {
        let root = directory.appendingPathComponent(name)
        let member = try ClipboardWorkingOutputMember.created(at: path.isEmpty ? root : root.appendingPathComponent(path),
            descriptor: descriptor)
        try database.write { db in
            if let parent, !path.isEmpty {
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                var status = stat()
                guard fstat(parent, &status) == 0,
                      let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                        arguments: [id.uuidString, parentPath]) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
                var parentMember = try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: data)
                guard status.st_dev == parentMember.snapshot.device, status.st_ino == parentMember.snapshot.inode,
                      status.st_mode == parentMember.snapshot.mode,
                      Int64(status.st_birthtimespec.tv_sec) == parentMember.identity.birthSeconds,
                      Int64(status.st_birthtimespec.tv_nsec) == parentMember.identity.birthNanoseconds else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
                }
                parentMember.checkpoint = .init(status)
                try db.execute(sql: "UPDATE clipboard_working_output_members SET record = ? WHERE owner_id = ? AND path = ?",
                    arguments: [try JSONEncoder().encode(parentMember), id.uuidString, parentPath])
            }
            try db.execute(sql: "INSERT INTO clipboard_working_output_members(owner_id, path, record) VALUES (?, ?, ?)",
                arguments: [id.uuidString, path, try JSONEncoder().encode(member)])
        }
    }

    func checkpointMember(path: String, descriptor: Int32, metadataApplied: Bool = false,
        expectedSize: Int64? = nil) throws {
        let root = directory.appendingPathComponent(name)
        let url = path.isEmpty ? root : root.appendingPathComponent(path)
        var status = stat(), named = stat()
        guard fstat(descriptor, &status) == 0, lstat(url.path, &named) == 0,
              ClipboardSyncFileSnapshot(status) == ClipboardSyncFileSnapshot(named),
              expectedSize == nil || status.st_size == expectedSize else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        let current = ClipboardSyncFileSnapshot(status)
        let identity = metadataApplied ? try ClipboardLinkedNativeIdentity.read(url, status: status) : nil
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                arguments: [id.uuidString, path]) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
            var member = try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: data)
            guard member.snapshot.device == current.device, member.snapshot.inode == current.inode else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            if !metadataApplied, current.mode != member.snapshot.mode {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            member.checkpoint = current
            if metadataApplied {
                guard let identity else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
                member.identity = identity
                if path.isEmpty {
                    guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_outputs WHERE id = ?", arguments: [id.uuidString]) else {
                        throw ClipboardHistoryModuleError.operationUnavailable
                    }
                    var record = try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: data)
                    record.identity = identity
                    try db.execute(sql: "UPDATE clipboard_working_outputs SET record = ? WHERE id = ?",
                        arguments: [try JSONEncoder().encode(record), id.uuidString])
                }
            }
            try db.execute(sql: "UPDATE clipboard_working_output_members SET record = ? WHERE owner_id = ? AND path = ?",
                arguments: [try JSONEncoder().encode(member), id.uuidString, path])
        }
    }

    func checkpoint(snapshot: ClipboardSyncFileSnapshot, tree: ClipboardFileTree? = nil,
        descriptor: ClipboardSyncFileDescriptor) throws {
        let url = directory.appendingPathComponent(name)
        let proof = try tree ?? ClipboardFileTree(url)
        guard try proof.verify() == snapshot else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        if descriptor.bodyFormat != .treeSegmentsV1 {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer { close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, ClipboardSyncFileSnapshot(current) == snapshot else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            var digest = SHA256()
            try ClipboardFileTree.read(fd, size: current.st_size) { digest.update(data: $0) }
            guard current.st_size == descriptor.originalByteCount, Data(digest.finalize()) == descriptor.contentDigest else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
        }
        let fingerprint = try proof.ownershipFingerprint()
        var current = stat(), atPath = stat()
        let pinned = rootDescriptor.withLock { $0 }
        guard pinned >= 0, fstat(pinned, &current) == 0, lstat(url.path, &atPath) == 0,
              ClipboardSyncFileSnapshot(current) == snapshot, ClipboardSyncFileSnapshot(atPath) == snapshot,
              let identity = try ClipboardLinkedNativeIdentity.read(url, status: current) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        // Applying the authenticated portable mtime can adjust APFS birth time.
        // The original FD and exact name still prove this is our created root.
        try update { $0.identity = identity; $0.snapshot = snapshot; $0.fingerprint = fingerprint; $0.completed = true }
    }

    func recover() throws {
        guard let record = try Self.record(id, database: database) else { return }
        try Self.recover(record, database: database)
    }

    private func update(_ mutate: (inout ClipboardWorkingOutputRecord) throws -> Void) throws {
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_outputs WHERE id = ?", arguments: [id.uuidString]) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            var record = try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: data)
            try mutate(&record)
            try db.execute(sql: "UPDATE clipboard_working_outputs SET record = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(record), id.uuidString])
        }
    }

    private static func record(_ id: UUID, database: DatabasePool) throws -> ClipboardWorkingOutputRecord? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_outputs WHERE id = ?", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: $0) }
        }
    }

    @concurrent
    static func recoverAll(in database: DatabasePool, root: URL) async throws {
        while try !recoverAllSynchronously(in: database, root: root) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    fileprivate static func recoverAllSynchronously(in database: DatabasePool, root: URL) throws -> Bool {
        guard let lease = try ClipboardWorkingOutputLease(root: root, exclusive: true) else {
            // Another recovery owns an exclusive lease: let a concurrent list
            // read its settled notices. Active producers instead remain hidden.
            guard let producer = try ClipboardWorkingOutputLease(root: root, exclusive: false) else { return false }
            withExtendedLifetime(producer) {}
            return true
        }
        defer { withExtendedLifetime(lease) {} }
        let ids = try database.read { try String.fetchAll($0, sql: "SELECT id FROM clipboard_working_outputs ORDER BY id") }
        for value in ids {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: value) else { continue }
            if let record = try record(id, database: database) { try recover(record, database: database) }
        }
        return true
    }

    static func keep(_ id: UUID, in database: DatabasePool, root: URL) throws {
        guard let lease = try ClipboardWorkingOutputLease(root: root, exclusive: true) else { throw ClipboardHistoryModuleError.operationUnavailable }
        defer { withExtendedLifetime(lease) {} }
        try retire(id, database: database)
    }

    fileprivate static func recoverAuthenticated(in database: DatabasePool, root: URL, directory: URL,
        descriptor: ClipboardSyncFileDescriptor, verify: @escaping (ClipboardWorkingOutputReplay) throws -> Void) throws {
        guard let lease = try ClipboardWorkingOutputLease(root: root, exclusive: true) else {
            throw ClipboardWorkingOutputRecoveryRequired()
        }
        defer { withExtendedLifetime(lease) {} }
        guard let resolved = realpath(directory.path, nil) else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { free(resolved) }
        let path = String(cString: resolved)
        let record = try database.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_outputs WHERE directory = ?", arguments: [path])
                .map { try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: $0) }
        }
        guard let record, record.descriptor == descriptor, !record.completed, record.replayDeclined != true,
              record.reason == nil || record.reason == .incomplete else { return }
        try recover(record, database: database) { tree in
            let replay = try ClipboardWorkingOutputReplay(tree: tree, database: database, owner: record.id, root: record.url)
            try verify(replay)
            try replay.finish()
        }
    }

    private static func recover(_ record: ClipboardWorkingOutputRecord, database: DatabasePool,
        verifyIncomplete: ((ClipboardFileTree) throws -> Void)? = nil) throws {
        let reason: ClipboardHistoryWorkingOutputRecovery.Reason
        do {
            guard let parent = try openParent(record.directory) else {
                guard record.parent.lookup().mounted else { throw RecoveryFailure.unavailable }
                try retire(record.id, database: database)
                return
            }
            defer { close(parent) }
            var parentStatus = stat(), status = stat()
            guard fstat(parent, &parentStatus) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            let parentIdentity = try ClipboardLinkedNativeIdentity.read(record.directory, status: parentStatus)
            guard fstatat(parent, record.name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT {
                    guard parentIdentity.map({ record.parent.provesContinuity(with: $0) }) == true
                        || record.parent.lookup().mounted else { throw RecoveryFailure.unavailable }
                    try retire(record.id, database: database)
                    return
                }
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            guard let parentIdentity, record.parent.provesContinuity(with: parentIdentity) else { throw RecoveryFailure.changed }
            guard let expected = record.identity else { throw RecoveryFailure.incomplete }
            guard let current = try ClipboardLinkedNativeIdentity.read(record.url, status: status),
                  expected.provesContinuity(with: current) else { throw RecoveryFailure.changed }
            // A retained notice is no longer automatic deletion authority.
            // Refreshes only notice disappearance or identity changes; they do
            // not repeatedly read a potentially enormous user-modified tree.
            if record.reason != nil, verifyIncomplete == nil { return }
            guard let fingerprint = record.fingerprint else { throw RecoveryFailure.incomplete }
            if verifyIncomplete == nil, ClipboardSyncFileSnapshot(status) != record.snapshot {
                if record.completed { throw RecoveryFailure.changed }
                throw RecoveryFailure.incomplete
            }
            let tree = try ClipboardFileTree(record.url)
            if !record.completed, let verifyIncomplete {
                try verifyIncomplete(tree)
            } else if try ClipboardSyncFileSnapshot(status) != record.snapshot || tree.ownershipFingerprint() != fingerprint {
                if record.completed { throw RecoveryFailure.changed }
                throw RecoveryFailure.incomplete
            }
            try remove(tree, record: record, parent: parent)
            guard fsync(parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            try retire(record.id, database: database)
            return
        } catch is CancellationError { throw CancellationError() }
        catch let error as DatabaseError { throw error }
        catch let error as ClipboardSyncServiceError { throw error }
        catch is ClipboardWorkingOutputChanged { reason = .changed }
        catch RecoveryFailure.incomplete { reason = .incomplete }
        catch RecoveryFailure.changed { reason = .changed }
        catch { reason = .unavailable }
        var retained = record
        retained.reason = reason
        if verifyIncomplete != nil { retained.replayDeclined = true }
        try database.write { try $0.execute(sql: "UPDATE clipboard_working_outputs SET record = ? WHERE id = ?",
            arguments: [try JSONEncoder().encode(retained), record.id.uuidString]) }
    }

    private enum RecoveryFailure: Error { case incomplete, changed, unavailable }

    private static func retire(_ id: UUID, database: DatabasePool) throws {
        try database.write { try $0.execute(sql: "DELETE FROM clipboard_working_outputs WHERE id = ?", arguments: [id.uuidString]) }
    }

    private static func openParent(_ url: URL) throws -> Int32? {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        do {
            for component in url.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT { close(fd); return nil }
                guard next >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func remove(_ tree: ClipboardFileTree, record: ClipboardWorkingOutputRecord, parent: Int32) throws {
        try tree.verify()
        let root = openat(parent, record.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard root >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(root) }
        try tree.forEachOwnershipEntry { path, expected in
            try Task.checkCancellation()
            guard let currentParent = try openParent(record.directory) else { throw RecoveryFailure.changed }
            defer { close(currentParent) }
            var parentStatus = stat(), pinnedParent = stat()
            guard fstat(currentParent, &parentStatus) == 0, fstat(parent, &pinnedParent) == 0,
                  parentStatus.st_dev == pinnedParent.st_dev, parentStatus.st_ino == pinnedParent.st_ino else { throw RecoveryFailure.changed }
            var top = stat()
            guard fstatat(parent, record.name, &top, AT_SYMLINK_NOFOLLOW) == 0,
                  top.st_ino == record.identity?.fileID,
                  Int64(top.st_birthtimespec.tv_sec) == record.identity?.birthSeconds,
                  Int64(top.st_birthtimespec.tv_nsec) == record.identity?.birthNanoseconds else { throw RecoveryFailure.changed }
            var directory = dup(path.isEmpty ? parent : root)
            guard directory >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer { close(directory) }
            let components = path.split(separator: "/").map(String.init)
            for index in components.indices.dropLast() {
                let next = openat(directory, components[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                close(directory); directory = next
                let ancestor = try tree.ownershipSnapshot(components[...index].joined(separator: "/"))
                var current = stat()
                guard fstat(directory, &current) == 0, current.st_dev == ancestor.device,
                      current.st_ino == ancestor.inode else { throw RecoveryFailure.changed }
            }
            let name = components.last ?? record.name
            var current = stat()
            guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            let isDirectory = current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            if isDirectory {
                // Our preceding child unlinks changed directory timestamps.
                guard current.st_dev == expected.device, current.st_ino == expected.inode,
                      current.st_mode == expected.mode else { throw RecoveryFailure.changed }
            } else if ClipboardSyncFileSnapshot(current) != expected { throw RecoveryFailure.changed }
            guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
        }
    }
}

extension ClipboardHistoryModule {
    static func hasWorkingOutputOwnership(in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_working_outputs)") == true
    }

    static func createWorkingOutputRecoverySchema(in database: Database) throws {
        try database.execute(sql: "CREATE TABLE clipboard_working_outputs(id TEXT PRIMARY KEY NOT NULL, directory TEXT UNIQUE NOT NULL, record BLOB NOT NULL)")
    }

    static func createWorkingOutputMemberSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_working_output_members(
                owner_id TEXT NOT NULL REFERENCES clipboard_working_outputs(id) ON DELETE CASCADE,
                path TEXT NOT NULL COLLATE BINARY, record BLOB NOT NULL,
                PRIMARY KEY(owner_id, path)
            ) WITHOUT ROWID
            """)
    }

    func workingOutputJournal() throws -> ClipboardWorkingOutputJournal { .init(database: try requiredDatabase(), storeRoot: storeRoot) }

    func recoverWorkingOutputs() async throws {
        let database = try requiredDatabase()
        try await ClipboardWorkingOutputOwner.recoverAll(in: database, root: storeRoot)
    }

    public func workingOutputRecoveries() async throws -> [ClipboardHistoryWorkingOutputRecovery] {
        try await recoverWorkingOutputs()
        return try await requiredDatabase().read { database in
            try Data.fetchAll(database, sql: "SELECT record FROM clipboard_working_outputs ORDER BY id").compactMap {
                let record = try JSONDecoder().decode(ClipboardWorkingOutputRecord.self, from: $0)
                return record.reason.map { .init(id: record.id, url: record.url, reason: $0) }
            }
        }
    }

    /// Keeps the file exactly where it is and relinquishes cleanup ownership.
    public func keepWorkingOutput(_ id: UUID) async throws {
        try await waitForWriteTurn()
        try ClipboardWorkingOutputOwner.keep(id, in: requiredDatabase(), root: storeRoot)
        notificationCenter.post(name: .clipboardHistoryV2DidMutate, object: nil)
    }
}
