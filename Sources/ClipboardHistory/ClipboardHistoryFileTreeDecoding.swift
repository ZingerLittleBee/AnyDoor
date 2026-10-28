import CryptoKit
import Darwin
import Foundation
import GRDB

/// Parsing is performed once without output, after segment authentication, then
/// again to construct an ordinary visible candidate. No plaintext archive exists.
enum ClipboardFileTreeDecoding {
    static func decode(descriptor: ClipboardSyncFileDescriptor, encryptedDirectory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, destination: URL?) throws {
        guard let body = descriptor.body, let encodedSize = descriptor.encodedByteCount, encodedSize > 0 else {
            throw ClipboardSyncServiceError.corruptData
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDoor-tree-parse-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var configuration = Configuration()
        let scratchKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        configuration.prepareDatabase { db in
            try db.usePassphrase(scratchKey)
            try db.execute(sql: "PRAGMA temp_store = MEMORY; PRAGMA cache_size = -512")
        }
        let database = try DatabaseQueue(path: scratch.appendingPathComponent("entries.sqlite").path, configuration: configuration)
        defer { try? database.close() }
        try database.write { try $0.execute(sql: "CREATE TABLE entries(path TEXT PRIMARY KEY COLLATE BINARY, kind TEXT NOT NULL, header BLOB NOT NULL) WITHOUT ROWID") }
        var chunk = 0
        var stream = Reader {
            guard chunk < body.chunkCount else { return nil }
            defer { chunk += 1 }
            return try ClipboardSyncCodec.openFileSegment(ClipboardSyncFileTransfer.readSegment(in: encryptedDirectory, index: chunk),
                descriptor: descriptor, account: account, control: control, key: key, index: chunk)
        }
        guard try stream.read(13) == Data("AnyDoorTree1\n".utf8) else { throw ClipboardSyncServiceError.corruptData }
        var original: Int64 = 0
        var previous: String?
        while stream.consumed < encodedSize {
            let length = try stream.read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= 16 * 1_024 else { throw ClipboardSyncServiceError.corruptData }
            let bytes = try stream.read(Int(length))
            let header = try JSONDecoder().decode(ClipboardFileTree.Header.self, from: bytes)
            guard header.size >= 0, header.mode <= 0o777,
                  (0..<1_000_000_000).contains(header.modifiedNanoseconds),
                  ["directory", "file", "link"].contains(header.kind),
                  header.kind == "file" || header.size == 0 else { throw ClipboardSyncServiceError.corruptData }
            if let previous {
                let components = header.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard header.path.utf8.lexicographicallyPrecedes(previous.utf8) == false, header.path != previous,
                      components.allSatisfy(ClipboardSyncFileIO.validFilename), header.path.utf8.count < Int(MAXPATHLEN) else {
                    throw ClipboardSyncServiceError.corruptData
                }
                let parent = components.dropLast().joined(separator: "/")
                guard try database.read({ try String.fetchOne($0, sql: "SELECT kind FROM entries WHERE path = ?", arguments: [parent]) }) == "directory" else {
                    throw ClipboardSyncServiceError.corruptData
                }
            } else {
                guard header.path.isEmpty, header.kind == descriptor.kind?.rawValue else { throw ClipboardSyncServiceError.corruptData }
            }
            if header.kind == "link" {
                guard let link = header.link, !link.contains("\0"), link.utf8.count < Int(MAXPATHLEN) else { throw ClipboardSyncServiceError.corruptData }
            } else if header.link != nil { throw ClipboardSyncServiceError.corruptData }
            try database.write { try $0.execute(sql: "INSERT INTO entries VALUES (?, ?, ?)", arguments: [header.path, header.kind, bytes]) }
            previous = header.path
            let output = try destination.map { try create(header, root: $0) }
            defer { if let output, output >= 0 { close(output) } }
            var remaining = header.size
            original = try ClipboardFileTree.add(original, remaining)
            while remaining > 0 {
                let part = try stream.read(Int(min(remaining, 64 * 1_024)))
                if let output { try write(part, to: output) }
                remaining -= Int64(part.count)
            }
            if let output, output >= 0, fsync(output) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        guard previous != nil, stream.consumed == encodedSize, original == descriptor.originalByteCount,
              Data(stream.hash.finalize()) == descriptor.contentDigest else { throw ClipboardSyncServiceError.corruptData }
        if let destination {
            try database.read { db in
                let cursor = try Data.fetchCursor(db, sql: "SELECT header FROM entries ORDER BY path DESC")
                while let bytes = try cursor.next() {
                    let header = try JSONDecoder().decode(ClipboardFileTree.Header.self, from: bytes)
                    let url = header.path.isEmpty ? destination : destination.appendingPathComponent(header.path)
                    if header.kind != "link", chmod(url.path, mode_t(header.mode)) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: header.modifiedSeconds, tv_nsec: header.modifiedNanoseconds)]
                    guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                }
            }
        }
    }

    private static func create(_ header: ClipboardFileTree.Header, root: URL) throws -> Int32 {
        let url = header.path.isEmpty ? root : root.appendingPathComponent(header.path)
        let parentURL = url.deletingLastPathComponent()
        // Every parent was declared as a directory before its child. Walk again
        // without following links so a changed candidate cannot redirect writes.
        var parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ClipboardSyncServiceError.localStorage }
        defer { close(parent) }
        if parentURL != root.deletingLastPathComponent() {
            let parents = [root.lastPathComponent] + header.path.split(separator: "/").dropLast().map(String.init)
            for name in parents {
                let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClipboardSyncServiceError.localStorage }
                close(parent); parent = next
            }
        }
        switch header.kind {
        case "directory":
            guard mkdirat(parent, url.lastPathComponent, 0o700) == 0 else { throw ClipboardSyncServiceError.localStorage }
            return -1
        case "link":
            guard let link = header.link, symlinkat(link, parent, url.lastPathComponent) == 0 else { throw ClipboardSyncServiceError.localStorage }
            return -1
        default:
            let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ClipboardSyncServiceError.localStorage }
            return fd
        }
    }

    private static func write(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw ClipboardSyncServiceError.localStorage }
                offset += amount
            }
        }
    }

    private struct Reader {
        let next: () throws -> Data?
        var buffer = Data()
        var offset = 0
        var consumed: Int64 = 0
        var hash = SHA256()

        mutating func read(_ count: Int) throws -> Data {
            var output = Data()
            while output.count < count {
                try Task.checkCancellation()
                if offset == buffer.count {
                    guard let bytes = try next(), !bytes.isEmpty else { throw ClipboardSyncServiceError.corruptData }
                    buffer = bytes; offset = 0
                }
                let amount = min(count - output.count, buffer.count - offset)
                output.append(buffer[offset..<(offset + amount)])
                offset += amount
            }
            consumed = try ClipboardFileTree.add(consumed, Int64(output.count))
            hash.update(data: output)
            return output
        }
    }
}
