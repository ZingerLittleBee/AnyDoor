import CryptoKit
import Darwin
import Foundation
import GRDB

/// A format inside the existing encrypted file transfer, not another sync
/// lifecycle. The inventory is encrypted and disk backed, including its sort.
/// Immutable inventory; GRDB serializes its connection and all reads use pread
/// or independently opened directory descriptors. It can travel with an I/O proof.
final class ClipboardFileTree: @unchecked Sendable {
    static func needsEncoding(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return true }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(fd) }
        return try ClipboardFileMetadata.forkSize(fd: fd) > 0 || !ClipboardFileMetadata.attributes(fd: fd).isEmpty || status.st_mode & 0o111 != 0
    }
    struct Header: Codable {
        let path: String
        let kind: String
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: Int64
        let link: String?
        let forkSize: Int64
        let attributeCount: Int
        var attributes: [ClipboardFileMetadata.Attribute]?
    }

    struct Measurement: Equatable {
        let original: Int64
        let encoded: Int64
        let digest: Data
    }

    private let root: URL
    private let scratch: URL
    private let database: DatabaseQueue
    private let rootDescriptor: Int32
    // Initialize before opening the source, so a throwing metadata read still
    // destroys this fully initialized owner and closes its FD/encrypted scratch.
    // This value is assigned only during construction.
    private var rootMetadataDigest = Data()

    init(_ root: URL) throws {
        try Task.checkCancellation()
        self.root = root
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDoor-tree-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var configuration = Configuration()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA temp_store = MEMORY; PRAGMA cache_size = -512")
        }
        database = try DatabaseQueue(path: scratch.appendingPathComponent("inventory.sqlite").path, configuration: configuration)
        rootDescriptor = open(root.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard rootDescriptor >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        rootMetadataDigest = try ClipboardFileMetadata.fingerprint(fd: rootDescriptor)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE entries(path TEXT PRIMARY KEY COLLATE BINARY, header BLOB NOT NULL, snapshot BLOB NOT NULL, scanned INTEGER NOT NULL) WITHOUT ROWID")
        }
        try insert(path: "", parent: nil, name: nil)
        while let path = try database.read({ try String.fetchOne($0, sql: "SELECT path FROM entries WHERE scanned = 0 ORDER BY path LIMIT 1") }) {
            try Task.checkCancellation()
            let fd = try openEntry(path, directory: true)
            guard let stream = fdopendir(fd) else { close(fd); throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer { closedir(stream) }
            while true {
                try Task.checkCancellation()
                // Member inspection can set errno, so reset it for every read.
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
                guard let name else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
                if name == "." || name == ".." { continue }
                guard ClipboardSyncFileIO.validFilename(name) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
                try insert(path: path.isEmpty ? name : path + "/" + name, parent: fd, name: name)
            }
            try database.write { try $0.execute(sql: "UPDATE entries SET scanned = 1 WHERE path = ?", arguments: [path]) }
        }
    }

    deinit {
        close(rootDescriptor)
        try? database.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func insert(path: String, parent: Int32?, name: String?) throws {
        try Task.checkCancellation()
        var status = stat()
        let result = if let parent, let name { fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) } else { fstat(rootDescriptor, &status) }
        guard result == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let kind: String
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = "file"
        case mode_t(S_IFDIR): kind = "directory"
        case mode_t(S_IFLNK): kind = "link"
        default: throw ClipboardHistoryStorageError.fileOperationFailed(ENOTSUP)
        }
        var link: String?
        if kind == "link", let parent, let name {
            var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count, let target = String(bytes: bytes.prefix(count), encoding: .utf8) else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            link = target
        }
        let fd = try openEntry(path, symlink: kind == "link")
        defer { if fd >= 0 { close(fd) } }
        let attributes = try ClipboardFileMetadata.attributes(fd: fd)
        let header = Header(path: path, kind: kind, mode: status.st_mode & 0o777,
            modifiedSeconds: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
            size: kind == "file" ? status.st_size : 0, link: link,
            forkSize: kind == "file" ? try ClipboardFileMetadata.forkSize(fd: fd) : 0,
            attributeCount: attributes.count, attributes: attributes)
        try database.write { try $0.execute(sql: "INSERT INTO entries VALUES (?, ?, ?, ?)", arguments: [path,
            try Self.encode(header), try JSONEncoder().encode(ClipboardSyncFileSnapshot(status)), kind == "directory" ? 0 : 1]) }
    }

    static func encode(_ header: Header) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(header)
    }

    func stream(_ consume: (Data) throws -> Void) throws -> Measurement {
        var original: Int64 = 0
        var encoded: Int64 = 0
        var hash = SHA256()
        func emit(_ data: Data) throws {
            encoded = try Self.add(encoded, Int64(data.count))
            hash.update(data: data)
            try consume(data)
        }
        try emit(Data("AnyDoorTree1\n".utf8))
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, header, snapshot FROM entries ORDER BY path")
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let header = try JSONDecoder().decode(Header.self, from: row["header"])
                var wireHeader = header
                wireHeader.attributes = nil
                let headerBytes = try Self.encode(wireHeader)
                guard headerBytes.count <= 16 * 1_024 else { throw ClipboardSyncServiceError.corruptData }
                let snapshot = try JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"])
                try check(header.path, snapshot: snapshot)
                var length = UInt32(headerBytes.count).bigEndian
                try emit(withUnsafeBytes(of: &length) { Data($0) })
                try emit(headerBytes)
                if header.kind == "file" {
                    let fd = try openEntry(header.path, symlink: header.kind == "link")
                    defer { close(fd) }
                    try Self.read(fd, size: header.size, consume: emit)
                    original = try Self.add(original, header.size)
                    if header.forkSize > 0 {
                        guard let fork = try ClipboardFileMetadata.fork(fd: fd) else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
                        defer { close(fork) }
                        try Self.read(fork, size: header.forkSize, consume: emit)
                        original = try Self.add(original, header.forkSize)
                    }
                }
                if let attributes = header.attributes, !attributes.isEmpty {
                    let fd = try openEntry(header.path, symlink: header.kind == "link")
                    defer { close(fd) }
                    for attribute in attributes {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        let metadata = try encoder.encode(attribute)
                        var attributeLength = UInt32(metadata.count).bigEndian
                        try emit(withUnsafeBytes(of: &attributeLength) { Data($0) })
                        try emit(metadata)
                        let bytes = try ClipboardFileMetadata.read(attribute, fd: fd)
                        original = try Self.add(original, Int64(bytes.count))
                        var offset = 0
                        while offset < bytes.count {
                            let end = min(offset + 64 * 1_024, bytes.count)
                            try emit(Data(bytes[offset..<end]))
                            offset = end
                        }
                    }
                }
                try check(header.path, snapshot: snapshot)
            }
        }
        // A later save to an already streamed member invalidates the whole tree.
        try verify()
        return .init(original: original, encoded: encoded, digest: Data(hash.finalize()))
    }

    @discardableResult
    func verify(at path: URL? = nil, afterExchange: Bool = false) throws -> ClipboardSyncFileSnapshot {
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, snapshot FROM entries ORDER BY path")
            while let row = try cursor.next() {
                try Task.checkCancellation()
                try check(row["path"], snapshot: JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"]),
                    rootPath: path, afterExchange: afterExchange)
            }
            guard let rootData = try Data.fetchOne(db, sql: "SELECT snapshot FROM entries WHERE path = ''") else { throw ClipboardSyncServiceError.corruptData }
            return try check("", snapshot: JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: rootData), rootPath: path, afterExchange: afterExchange)
        }
    }

    /// Includes every member's native snapshot as well as content and portable
    /// metadata. The digest is safe to persist; the inventory remains encrypted.
    func ownershipFingerprint() throws -> Data {
        var hash = SHA256()
        hash.update(data: try stream { _ in }.digest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, snapshot FROM entries ORDER BY path")
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let path: String = row["path"]
                hash.update(data: Data(path.utf8) + Data([0]))
                hash.update(data: try encoder.encode(JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"])))
            }
        }
        try verify()
        return Data(hash.finalize())
    }

    /// A local observation hint, never content or deletion authority. Include
    /// all descendants: the root directory's stamp cannot detect an in-place save.
    /// No regular-file body or resource fork is streamed by this method.
    func observationFingerprint() throws -> Data {
        var hash = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, snapshot FROM entries ORDER BY path")
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let path: String = row["path"]
                hash.update(data: Data(path.utf8) + Data([0]))
                hash.update(data: try encoder.encode(JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"])))
            }
        }
        try verify()
        return Data(hash.finalize())
    }

    func ownershipSnapshot(_ path: String) throws -> ClipboardSyncFileSnapshot {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM entries WHERE path = ?", arguments: [path]) else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            return try JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: data)
        }
    }

    func ownershipHeader(_ path: String) throws -> Header {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT header FROM entries WHERE path = ?", arguments: [path]) else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            return try JSONDecoder().decode(Header.self, from: data)
        }
    }

    func openOwnershipEntry(_ path: String, symlink: Bool) throws -> Int32 {
        try openEntry(path, symlink: symlink)
    }

    /// One encrypted inventory row at a time; callers may consult ancestors
    /// without recursively entering the inventory's database connection.
    func forEachOwnershipEntry(_ consume: (String, ClipboardSyncFileSnapshot) throws -> Void) throws {
        var previous: String?
        while let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT path, snapshot FROM entries WHERE ? IS NULL OR path < ? ORDER BY path DESC LIMIT 1",
                arguments: [previous, previous])
        }) {
            let path: String = row["path"]
            try consume(path, JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"]))
            previous = path
        }
    }

    @discardableResult
    private func check(_ path: String, snapshot: ClipboardSyncFileSnapshot, rootPath: URL? = nil, afterExchange: Bool = false) throws -> ClipboardSyncFileSnapshot {
        var status = stat()
        if path.isEmpty {
            guard fstat(rootDescriptor, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            var current = stat()
            guard lstat((rootPath ?? root).path, &current) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard current.st_dev == status.st_dev, current.st_ino == status.st_ino else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        } else {
            let components = path.split(separator: "/").map(String.init)
            let parent = try openEntry(components.dropLast().joined(separator: "/"), directory: true)
            defer { close(parent) }
            guard let name = components.last else { throw ClipboardSyncServiceError.corruptData }
            guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        let current = ClipboardSyncFileSnapshot(status)
        if path.isEmpty, afterExchange {
            guard current.device == snapshot.device, current.inode == snapshot.inode, current.size == snapshot.size,
                  current.mode == snapshot.mode, current.modifiedSeconds == snapshot.modifiedSeconds,
                  current.modifiedNanoseconds == snapshot.modifiedNanoseconds else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
            guard try ClipboardFileMetadata.fingerprint(fd: rootDescriptor) == rootMetadataDigest else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
            var after = stat()
            guard fstat(rootDescriptor, &after) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard ClipboardSyncFileSnapshot(after) == current else { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        } else if current != snapshot { throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE) }
        return current
    }

    private func openEntry(_ path: String, directory: Bool = false, symlink: Bool = false) throws -> Int32 {
        var fd = dup(rootDescriptor)
        guard fd >= 0 else { throw ClipboardSyncServiceError.localStorage }
        do {
            let components = path.split(separator: "/").map(String.init)
            for (index, name) in components.enumerated() {
                let next = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                    | (symlink && index == components.count - 1 ? O_SYMLINK : O_NOFOLLOW)
                    | (directory || index < components.count - 1 ? O_DIRECTORY : 0))
                guard next >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    static func read(_ fd: Int32, size: Int64, consume: (Data) throws -> Void) throws {
        var offset: Int64 = 0
        var bytes = Data(count: 64 * 1_024)
        while offset < size {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(min(Int64($0.count), size - offset)), off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(count == 0 ? ESTALE : errno) }
            try consume(Data(bytes.prefix(count)))
            offset += Int64(count)
        }
    }

    static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard right >= 0, !result.overflow else { throw ClipboardSyncServiceError.corruptData }
        return result.partialValue
    }
}
