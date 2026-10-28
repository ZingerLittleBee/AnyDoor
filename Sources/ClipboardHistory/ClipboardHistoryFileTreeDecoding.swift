import CryptoKit
import Darwin
import Foundation
import GRDB

/// Parsing is performed once without output, after segment authentication, then
/// again to construct an ordinary visible candidate. No plaintext archive exists.
enum ClipboardFileTreeDecoding {
    @discardableResult
    static func decode(descriptor: ClipboardSyncFileDescriptor, encryptedDirectory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, destination: URL?,
        faults: ClipboardHistoryFaultInjector = .init(), destinationParent: Int32? = nil) throws -> ClipboardSyncFileSnapshot? {
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
        try database.write { try $0.execute(sql: "CREATE TABLE entries(path TEXT PRIMARY KEY COLLATE BINARY, kind TEXT NOT NULL, header BLOB NOT NULL, created BLOB) WITHOUT ROWID") }
        let outputTree = try destination.map { url in
            guard let destinationParent else { throw ClipboardSyncServiceError.localStorage }
            return try ClipboardFileTreeOutput(destination: url, parentDescriptor: destinationParent)
        }
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
                  header.forkSize >= 0,
                  header.attributeCount >= 0, header.attributes == nil,
                  (0..<1_000_000_000).contains(header.modifiedNanoseconds),
                  ["directory", "file", "link"].contains(header.kind),
                  header.kind == "file" || (header.size == 0 && header.forkSize == 0) else { throw ClipboardSyncServiceError.corruptData }
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
                guard let link = header.link, !link.isEmpty, !link.contains("\0"), link.utf8.count < Int(MAXPATHLEN) else { throw ClipboardSyncServiceError.corruptData }
            } else if header.link != nil { throw ClipboardSyncServiceError.corruptData }
            try database.write { try $0.execute(sql: "INSERT INTO entries(path, kind, header) VALUES (?, ?, ?)", arguments: [header.path, header.kind, bytes]) }
            previous = header.path
            let output = try outputTree?.create(header)
            defer { if let output, output >= 0 { close(output) } }
            if let output {
                var created = stat()
                guard fstat(output, &created) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                try database.write { try $0.execute(sql: "UPDATE entries SET created = ? WHERE path = ?",
                    arguments: [try JSONEncoder().encode(ClipboardSyncFileSnapshot(created)), header.path]) }
            }
            var remaining = header.size
            original = try ClipboardFileTree.add(original, remaining)
            while remaining > 0 {
                let part = try stream.read(Int(min(remaining, 64 * 1_024)))
                if let output { try write(part, to: output) }
                remaining -= Int64(part.count)
            }
            original = try ClipboardFileTree.add(original, header.forkSize)
            if header.forkSize > 0 {
                let fork = try output.flatMap { try ClipboardFileMetadata.fork(fd: $0, writing: true) }
                defer { if let fork { close(fork) } }
                remaining = header.forkSize
                while remaining > 0 {
                    let part = try stream.read(Int(min(remaining, 64 * 1_024)))
                    if let fork { try write(part, to: fork) }
                    remaining -= Int64(part.count)
                }
                if let fork, fsync(fork) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            }
            var previousAttribute: String?
            for _ in 0..<header.attributeCount {
                let attributeLength = try stream.read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard attributeLength > 0, attributeLength <= 1_024 else { throw ClipboardSyncServiceError.corruptData }
                let attribute = try JSONDecoder().decode(ClipboardFileMetadata.Attribute.self, from: stream.read(Int(attributeLength)))
                guard !attribute.name.isEmpty, !attribute.name.contains("\0"), attribute.name.utf8.count <= 127,
                      ClipboardFileMetadata.portable(attribute.name), attribute.size >= 0,
                      attribute.size <= ClipboardFileMetadata.maximumAttributeBytes,
                      previousAttribute.map({ $0.utf8.lexicographicallyPrecedes(attribute.name.utf8) }) ?? true else {
                    throw ClipboardSyncServiceError.corruptData
                }
                previousAttribute = attribute.name
                original = try ClipboardFileTree.add(original, attribute.size)
                // The validation pass discards bounded pieces. Construction
                // holds only the current value because fsetxattr is indivisible.
                var value = try output == nil ? Data() : ClipboardFileMetadata.allocate(Int(attribute.size))
                var offset = 0
                while Int64(offset) < attribute.size {
                    let part = try stream.read(Int(min(attribute.size - Int64(offset), 64 * 1_024)))
                    if output != nil { value.replaceSubrange(offset..<(offset + part.count), with: part) }
                    offset += part.count
                }
                if let output {
                    guard value.withUnsafeBytes({ fsetxattr(output, attribute.name, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                        throw ClipboardHistoryStorageError.fileOperationFailed(errno)
                    }
                }
            }
            if let output, output >= 0, header.kind != "link", fsync(output) != 0 { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        guard previous != nil, stream.consumed == encodedSize, original == descriptor.originalByteCount,
              Data(stream.hash.finalize()) == descriptor.contentDigest else { throw ClipboardSyncServiceError.corruptData }
        if let outputTree {
            try faults.check(.syncFileTreeBeforeMetadata)
            try database.read { db in
                let cursor = try Row.fetchCursor(db, sql: "SELECT header, created FROM entries ORDER BY path DESC")
                while let row = try cursor.next() {
                    try outputTree.applyMetadata(JSONDecoder().decode(ClipboardFileTree.Header.self, from: row["header"]),
                        expected: JSONDecoder().decode(ClipboardSyncFileSnapshot.self, from: row["created"]))
                }
            }
        }
        return try outputTree?.snapshot()
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
