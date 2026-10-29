import CryptoKit
import Darwin
import Foundation

struct ClipboardSyncFileCandidate: Sendable {
    let directory: URL
    let name: String
    let pendingName: String?
    let parentDevice: Int32
    let parentInode: UInt64
    let snapshot: ClipboardSyncFileSnapshot
    var treeWitness: ClipboardFileTree? = nil
    var ownership: ClipboardWorkingOutputOwner? = nil
}

struct ClipboardSyncFileSnapshot: Codable, Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        mode = value.st_mode
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

enum ClipboardSyncFilePublication {
    /// Legacy inline envelopes share the same owned candidate and final gate.
    @concurrent
    static func constructInline(_ data: Data, descriptor: ClipboardSyncFileDescriptor, root: URL,
        accountID: String, ownership: ClipboardWorkingOutputJournal,
        faults: ClipboardHistoryFaultInjector) async throws -> ClipboardSyncFileCandidate {
        guard descriptor.originalByteCount == Int64(data.count),
              descriptor.contentDigest == Data(SHA256.hash(data: data)) else { throw ClipboardSyncServiceError.corruptData }
        try ownership.recover()
        let (directory, url) = try openDirectory(root: root, accountID: accountID, descriptor: descriptor)
        defer { close(directory) }
        try ownership.recover(directory: url, descriptor: descriptor) { replay in
            try replay.raw(size: Int64(data.count)) { try $0(data) }
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let existing = openat(directory, descriptor.displayName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if existing >= 0 {
            defer { close(existing) }
            var before = stat(), after = stat()
            guard fstat(existing, &before) == 0,
                  before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size == Int64(data.count),
                  try digest(existing, byteCount: before.st_size) == descriptor.contentDigest,
                  fstat(existing, &after) == 0, ClipboardSyncFileSnapshot(before) == ClipboardSyncFileSnapshot(after) else {
                throw ClipboardHistoryStorageError.fileOperationFailed(EEXIST)
            }
            return .init(directory: url, name: descriptor.displayName, pendingName: nil,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(after))
        }
        guard errno == ENOENT else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let owner = try ownership.reserve(directory: directory, url: url, descriptor: descriptor)
        let output = openat(directory, owner.name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            let failure = errno
            try? owner.recover()
            throw ClipboardHistoryStorageError.fileOperationFailed(failure)
        }
        defer { close(output) }
        do {
            try owner.created(output)
            try faults.check(.syncWorkingOutputAfterOwnership)
            try data.withUnsafeBytes { buffer in
                var written = 0
                var nextProgress = ClipboardWorkingOutputOwner.progressByteCount
                while written < buffer.count {
                    try Task.checkCancellation()
                    let amount = Darwin.write(output, buffer.baseAddress?.advanced(by: written), min(64 * 1_024, buffer.count - written))
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(amount == 0 ? EIO : errno) }
                    written += amount
                    if Int64(written) >= nextProgress {
                        try owner.checkpointMember(path: "", descriptor: output, expectedSize: Int64(written))
                        nextProgress = Int64(written) + ClipboardWorkingOutputOwner.progressByteCount
                    }
                    try faults.check(.syncWorkingOutputDuringConstruction)
                }
            }
            guard fsync(output) == 0, fsync(directory) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            var final = stat()
            guard fstat(output, &final) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            try owner.checkpoint(snapshot: .init(final), descriptor: descriptor)
            return .init(directory: url, name: descriptor.displayName, pendingName: owner.name,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(final), ownership: owner)
        } catch { try? owner.recover(); throw error }
    }

    /// The caller has verified the entire encrypted version before this pass.
    /// Plaintext construction is confined to the visible working-copy directory.
    @concurrent
    static func construct(descriptor: ClipboardSyncFileDescriptor, encryptedDirectory: URL,
        root: URL, account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        ownership: ClipboardWorkingOutputJournal, faults: ClipboardHistoryFaultInjector = .init()
    ) async throws -> ClipboardSyncFileCandidate {
        try ownership.recover()
        if descriptor.bodyFormat == .treeSegmentsV1 {
            return try constructTree(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
                root: root, account: account, control: control, key: key, ownership: ownership, faults: faults)
        }
        let (directory, url) = try openDirectory(root: root, accountID: account.identifier, descriptor: descriptor)
        defer { close(directory) }
        try ownership.recover(directory: url, descriptor: descriptor) { replay in
            guard let body = descriptor.body, let size = descriptor.originalByteCount else { throw ClipboardSyncServiceError.corruptData }
            try replay.raw(size: size) { consume in
                var hash = SHA256()
                var count: Int64 = 0
                for index in 0..<body.chunkCount {
                    try Task.checkCancellation()
                    let bytes = try ClipboardSyncCodec.openFileSegment(ClipboardSyncFileTransfer.readSegment(in: encryptedDirectory, index: index),
                        descriptor: descriptor, account: account, control: control, key: key, index: index)
                    hash.update(data: bytes)
                    count += Int64(bytes.count)
                    try consume(bytes)
                }
                guard count == size, Data(hash.finalize()) == descriptor.contentDigest else { throw ClipboardSyncServiceError.corruptData }
            }
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let existing = openat(directory, descriptor.displayName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if existing >= 0 {
            defer { close(existing) }
            var before = stat()
            guard fstat(existing, &before) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  before.st_size == descriptor.originalByteCount,
                  try digest(existing, byteCount: before.st_size) == descriptor.contentDigest else {
                throw ClipboardSyncServiceError.localStorage
            }
            var after = stat()
            guard fstat(existing, &after) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard ClipboardSyncFileSnapshot(before) == ClipboardSyncFileSnapshot(after) else {
                throw ClipboardSyncServiceError.localStorage
            }
            return .init(directory: url, name: descriptor.displayName, pendingName: nil,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(after))
        }
        guard errno == ENOENT else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard let body = descriptor.body else { throw ClipboardSyncServiceError.localStorage }
        let owner = try ownership.reserve(directory: directory, url: url, descriptor: descriptor)
        let pendingName = owner.name
        let output = openat(directory, pendingName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            let failure = errno
            try? owner.recover()
            throw ClipboardHistoryStorageError.fileOperationFailed(failure)
        }
        defer { close(output) }
        do {
            try owner.created(output)
            try faults.check(.syncWorkingOutputAfterOwnership)
            var hash = SHA256()
            var byteCount: Int64 = 0
            for index in 0..<body.chunkCount {
                try Task.checkCancellation()
                let encrypted = try ClipboardSyncFileTransfer.readSegment(in: encryptedDirectory, index: index)
                let bytes = try ClipboardSyncCodec.openFileSegment(encrypted, descriptor: descriptor,
                    account: account, control: control, key: key, index: index)
                hash.update(data: bytes)
                byteCount += Int64(bytes.count)
                try bytes.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let count = Darwin.write(output, buffer.baseAddress?.advanced(by: written), buffer.count - written)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(count == 0 ? EIO : errno) }
                        written += count
                    }
                }
                try owner.checkpointMember(path: "", descriptor: output, expectedSize: byteCount)
                try faults.check(.syncWorkingOutputDuringConstruction)
            }
            guard byteCount == descriptor.originalByteCount, Data(hash.finalize()) == descriptor.contentDigest else {
                throw ClipboardSyncServiceError.corruptData
            }
            guard fsync(output) == 0, fsync(directory) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            var final = stat()
            guard fstat(output, &final) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            try owner.checkpoint(snapshot: .init(final), descriptor: descriptor)
            return .init(directory: url, name: descriptor.displayName, pendingName: pendingName,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(final), ownership: owner)
        } catch { try? owner.recover(); throw error }
    }

    /// Only this short operation runs between the owning actor's final admission
    /// and completion transaction. All long reads/hash/write work is finished.
    static func publish(_ candidate: ClipboardSyncFileCandidate, descriptor: ClipboardSyncFileDescriptor,
        root: URL, accountID: String, faults: ClipboardHistoryFaultInjector) throws -> ClipboardSyncPublishedFile {
        let (directory, url) = try openDirectory(root: root, accountID: accountID, descriptor: descriptor)
        defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard parent.st_dev == candidate.parentDevice,
              parent.st_ino == candidate.parentInode, url == candidate.directory else {
            throw ClipboardSyncServiceError.localStorage
        }
        let sourceName = candidate.pendingName ?? candidate.name
        var source = stat()
        guard fstatat(directory, sourceName, &source, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard ClipboardSyncFileSnapshot(source) == candidate.snapshot else { throw ClipboardSyncServiceError.localStorage }
        try faults.check(.syncFileBeforePublication)
        if let pending = candidate.pendingName {
            guard renameatx_np(directory, pending, directory, candidate.name, UInt32(RENAME_EXCL)) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard fsync(directory) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        }
        let destination = url.appendingPathComponent(candidate.name)
        var atPath = stat()
        guard lstat(url.path, &atPath) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard parent.st_dev == atPath.st_dev, parent.st_ino == atPath.st_ino else {
            throw ClipboardSyncServiceError.localStorage
        }
        guard fstatat(directory, candidate.name, &atPath, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard atPath.st_dev == source.st_dev, atPath.st_ino == source.st_ino,
              atPath.st_size == source.st_size, atPath.st_mtimespec.tv_sec == source.st_mtimespec.tv_sec,
              atPath.st_mtimespec.tv_nsec == source.st_mtimespec.tv_nsec else { throw ClipboardSyncServiceError.localStorage }
        let values = try destination.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let identity = values.fileResourceIdentifier as? NSObject else {
            throw ClipboardSyncServiceError.localStorage
        }
        let bookmark = try destination.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
        var verified = stat()
        guard fstatat(directory, candidate.name, &verified, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard ClipboardSyncFileSnapshot(verified) == ClipboardSyncFileSnapshot(atPath) else { throw ClipboardSyncServiceError.localStorage }
        try faults.check(.syncFileAfterPublication)
        return .init(url: destination, bookmark: bookmark,
            identity: try NSKeyedArchiver.archivedData(withRootObject: identity, requiringSecureCoding: true))
    }

    @concurrent
    static func discard(_ candidate: ClipboardSyncFileCandidate) async {
        try? candidate.ownership?.recover()
    }

    static func openDirectory(root: URL, accountID: String,
        descriptor: ClipboardSyncFileDescriptor) throws -> (Int32, URL) {
        guard ClipboardSyncFileIO.validFilename(descriptor.displayName), accountID.count == 64,
              accountID.allSatisfy(\.isHexDigit) else { throw ClipboardSyncServiceError.corruptData }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        var url = root
        do {
            for component in [accountID, descriptor.objectID.uuidString.lowercased(), descriptor.versionID.uuidString.lowercased()] {
                if mkdirat(directory, component, 0o700) != 0, errno != EEXIST { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
                guard fsync(directory) == 0 else {
                    let failure = errno
                    close(child)
                    throw ClipboardHistoryStorageError.fileOperationFailed(failure)
                }
                close(directory)
                directory = child
                url.appendPathComponent(component, isDirectory: true)
            }
            return (directory, url)
        } catch { close(directory); throw error }
    }

    private static func digest(_ descriptor: Int32, byteCount: Int64) throws -> Data {
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: ClipboardSyncCodec.chunkByteCount)
        var offset: Int64 = 0
        while offset < byteCount {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, Int(min(Int64($0.count), byteCount - offset)), off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(count == 0 ? EIO : errno) }
            hash.update(data: Data(bytes.prefix(count)))
            offset += Int64(count)
        }
        return Data(hash.finalize())
    }
}
