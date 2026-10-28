import CryptoKit
import Darwin
import Foundation
import GRDB

/// A format inside the existing encrypted file transfer, not another sync
/// lifecycle. The inventory is encrypted and disk backed, including its sort.
final class ClipboardFileTree {
    static func needsEncoding(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
    struct Header: Codable {
        let path: String
        let kind: String
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: Int64
        let link: String?
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

    init(_ root: URL) throws {
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
        try database.write { db in
            try db.execute(sql: "CREATE TABLE entries(path TEXT PRIMARY KEY COLLATE BINARY, header BLOB NOT NULL, snapshot BLOB NOT NULL, scanned INTEGER NOT NULL) WITHOUT ROWID")
        }
        try insert(path: "", parent: nil, name: nil)
        while let path = try database.read({ try String.fetchOne($0, sql: "SELECT path FROM entries WHERE scanned = 0 ORDER BY path LIMIT 1") }) {
            let fd = try openEntry(path, directory: true)
            guard let stream = fdopendir(fd) else { close(fd); throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
                guard let name else { throw ClipboardSyncServiceError.accessDenied }
                if name == "." || name == ".." { continue }
                guard ClipboardSyncFileIO.validFilename(name) else { throw ClipboardSyncServiceError.accessDenied }
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
        var status = stat()
        let result = if let parent, let name { fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) } else { fstat(rootDescriptor, &status) }
        guard result == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let kind: String
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = "file"
        case mode_t(S_IFDIR): kind = "directory"
        case mode_t(S_IFLNK): kind = "link"
        default: throw ClipboardSyncServiceError.accessDenied
        }
        var link: String?
        if kind == "link", let parent, let name {
            var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count, let target = String(bytes: bytes.prefix(count), encoding: .utf8) else {
                throw ClipboardSyncServiceError.accessDenied
            }
            link = target
        }
        let header = Header(path: path, kind: kind, mode: status.st_mode & 0o777,
            modifiedSeconds: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
            size: kind == "file" ? status.st_size : 0, link: link)
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
                let headerBytes: Data = row["header"]
                let header = try JSONDecoder().decode(Header.self, from: headerBytes)
                let snapshot = try JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"])
                try check(header.path, snapshot: snapshot)
                var length = UInt32(headerBytes.count).bigEndian
                try emit(withUnsafeBytes(of: &length) { Data($0) })
                try emit(headerBytes)
                if header.kind == "file" {
                    let fd = try openEntry(header.path)
                    defer { close(fd) }
                    try Self.read(fd, size: header.size, consume: emit)
                    original = try Self.add(original, header.size)
                }
                try check(header.path, snapshot: snapshot)
            }
        }
        // A later save to an already streamed member invalidates the whole tree.
        try verify()
        return .init(original: original, encoded: encoded, digest: Data(hash.finalize()))
    }

    func verify() throws {
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, snapshot FROM entries ORDER BY path")
            while let row = try cursor.next() {
                try check(row["path"], snapshot: JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["snapshot"]))
            }
        }
    }

    private func check(_ path: String, snapshot: ClipboardSyncFileSnapshot) throws {
        var status = stat()
        if path.isEmpty {
            guard fstat(rootDescriptor, &status) == 0 else { throw ClipboardSyncServiceError.accessDenied }
            var current = stat()
            guard lstat(root.path, &current) == 0, current.st_dev == status.st_dev, current.st_ino == status.st_ino else { throw ClipboardSyncServiceError.accessDenied }
        } else {
            let components = path.split(separator: "/").map(String.init)
            let parent = try openEntry(components.dropLast().joined(separator: "/"), directory: true)
            defer { close(parent) }
            guard let name = components.last, fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClipboardSyncServiceError.accessDenied }
        }
        guard ClipboardSyncFileSnapshot(status) == snapshot else { throw ClipboardSyncServiceError.accessDenied }
    }

    private func openEntry(_ path: String, directory: Bool = false) throws -> Int32 {
        var fd = dup(rootDescriptor)
        guard fd >= 0 else { throw ClipboardSyncServiceError.localStorage }
        do {
            let components = path.split(separator: "/").map(String.init)
            for (index, name) in components.enumerated() {
                let next = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
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
