import Darwin
import Foundation
import GRDB

struct ClipboardWorkingOutputChanged: Error {}

/// Creation and coarse progress proofs contain no key or plaintext body.
/// Recovery never infers an unrecorded write from a merely plausible prefix.
struct ClipboardWorkingOutputMember: Codable {
    var identity: ClipboardLinkedNativeIdentity
    let snapshot: ClipboardSyncFileSnapshot
    let metadata: Data
    var checkpoint: ClipboardSyncFileSnapshot?

    static func created(at url: URL, descriptor: Int32) throws -> Self {
        var status = stat(), named = stat()
        guard fstat(descriptor, &status) == 0, lstat(url.path, &named) == 0,
              ClipboardSyncFileSnapshot(status) == ClipboardSyncFileSnapshot(named),
              let identity = try ClipboardLinkedNativeIdentity.read(url, status: status) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
        return .init(identity: identity, snapshot: .init(status), metadata: try ClipboardFileMetadata.fingerprint(fd: descriptor))
    }
}

/// Replays only during an already authorized receive, using its existing key and
/// authenticated stream. No replay context or sync key is persisted here.
final class ClipboardWorkingOutputReplay {
    private let tree: ClipboardFileTree
    private let database: DatabasePool
    private let owner: UUID
    private let count: Int
    private var visited = 0
    private var stopped = false
    private var current: Member?

    private final class Member {
        let fd: Int32
        let header: ClipboardFileTree.Header
        let actual: ClipboardFileTree.Header
        var bodyOffset: Int64 = 0
        var forkOffset: Int64 = 0
        var attributeIndex = 0
        init(fd: Int32, header: ClipboardFileTree.Header, actual: ClipboardFileTree.Header) {
            self.fd = fd; self.header = header; self.actual = actual
        }
        deinit { close(fd) }
    }

    init(tree: ClipboardFileTree, database: DatabasePool, owner: UUID, root: URL) throws {
        self.tree = tree; self.database = database; self.owner = owner
        count = try database.read { try Int.fetchOne($0,
            sql: "SELECT COUNT(*) FROM clipboard_working_output_members WHERE owner_id = ?", arguments: [owner.uuidString]) ?? 0 }
        guard count > 0 else { throw ClipboardWorkingOutputChanged() }
        var found = 0
        try tree.forEachOwnershipEntry { path, snapshot in
            guard let member = try self.record(path) else { throw ClipboardWorkingOutputChanged() }
            let header = try tree.ownershipHeader(path)
            let fd = try tree.openOwnershipEntry(path, symlink: header.kind == "link")
            defer { close(fd) }
            var status = stat()
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            guard fstat(fd, &status) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard ClipboardSyncFileSnapshot(status) == snapshot,
                  let native = try ClipboardLinkedNativeIdentity.read(url, status: status),
                  member.identity.provesContinuity(with: native) else { throw ClipboardWorkingOutputChanged() }
            guard snapshot == (member.checkpoint ?? member.snapshot) else { throw ClipboardWorkingOutputChanged() }
            found += 1
        }
        guard found == count else { throw ClipboardWorkingOutputChanged() }
    }

    private func record(_ path: String) throws -> ClipboardWorkingOutputMember? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM clipboard_working_output_members WHERE owner_id = ? AND path = ?",
                arguments: [owner.uuidString, path]).map { try JSONDecoder().decode(ClipboardWorkingOutputMember.self, from: $0) }
        }
    }

    func begin(_ header: ClipboardFileTree.Header) throws {
        current = nil
        guard let proof = try record(header.path) else { stopped = true; return }
        guard !stopped else { throw ClipboardWorkingOutputChanged() }
        let actual = try tree.ownershipHeader(header.path)
        guard actual.kind == header.kind, actual.link == header.link,
              actual.mode == proof.snapshot.mode & 0o777 || actual.mode == header.mode,
              actual.size <= header.size, actual.forkSize <= header.forkSize,
              actual.attributeCount <= header.attributeCount else { throw ClipboardWorkingOutputChanged() }
        let fd = try tree.openOwnershipEntry(header.path, symlink: header.kind == "link")
        current = Member(fd: fd, header: header, actual: actual)
        visited += 1
    }

    func body(_ bytes: Data) throws {
        guard let current else { return }
        try compare(bytes, descriptor: current.fd, offset: current.bodyOffset, available: current.actual.size)
        current.bodyOffset += Int64(bytes.count)
    }

    func fork(_ bytes: Data) throws {
        guard let current else { return }
        if current.forkOffset < current.actual.forkSize {
            guard let fd = try ClipboardFileMetadata.fork(fd: current.fd) else { throw ClipboardWorkingOutputChanged() }
            defer { close(fd) }
            try compare(bytes, descriptor: fd, offset: current.forkOffset, available: current.actual.forkSize)
        }
        current.forkOffset += Int64(bytes.count)
    }

    func attribute(_ attribute: ClipboardFileMetadata.Attribute, value: Data) throws {
        guard let current else { return }
        let existing = current.actual.attributes ?? []
        if current.attributeIndex < existing.count {
            let actual = existing[current.attributeIndex]
            guard actual.name == attribute.name, actual.size == attribute.size,
                  try ClipboardFileMetadata.read(actual, fd: current.fd) == value else { throw ClipboardWorkingOutputChanged() }
        }
        current.attributeIndex += 1
    }

    func end() throws {
        guard let current else { return }
        // A short data fork cannot already have later forks or attributes.
        if current.actual.size < current.header.size {
            guard current.actual.forkSize == 0, current.actual.attributeCount == 0 else { throw ClipboardWorkingOutputChanged() }
            stopped = true
        } else if current.actual.forkSize < current.header.forkSize {
            guard current.actual.attributeCount == 0 else { throw ClipboardWorkingOutputChanged() }
            stopped = true
        } else if current.actual.attributeCount < current.header.attributeCount { stopped = true }
        self.current = nil
    }

    func raw(size: Int64, consume: (_ body: (Data) throws -> Void) throws -> Void) throws {
        guard count == 1, let member = try record("") else { throw ClipboardWorkingOutputChanged() }
        let header = ClipboardFileTree.Header(path: "", kind: "file", mode: 0o600,
            modifiedSeconds: 0, modifiedNanoseconds: 0, size: size, link: nil, forkSize: 0, attributeCount: 0)
        try begin(header)
        guard let current, try ClipboardFileMetadata.fingerprint(fd: current.fd) == member.metadata else {
            throw ClipboardWorkingOutputChanged()
        }
        try consume { try self.body($0) }
        try end()
    }

    func finish() throws {
        guard visited == count else { throw ClipboardWorkingOutputChanged() }
        try tree.verify()
    }

    private func compare(_ bytes: Data, descriptor: Int32, offset: Int64, available: Int64) throws {
        guard offset < available else { return }
        let length = Int(min(Int64(bytes.count), available - offset))
        var actual = Data(count: length)
        var read = 0
        while read < length {
            let amount = actual.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress?.advanced(by: read), length - read, off_t(offset) + off_t(read))
            }
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard amount > 0 else { throw ClipboardWorkingOutputChanged() }
            read += amount
        }
        guard actual == bytes.prefix(length) else { throw ClipboardWorkingOutputChanged() }
    }
}
