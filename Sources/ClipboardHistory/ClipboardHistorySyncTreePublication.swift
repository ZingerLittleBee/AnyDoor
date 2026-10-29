import Darwin
import Foundation

extension ClipboardSyncFilePublication {
    static func constructTree(descriptor: ClipboardSyncFileDescriptor, encryptedDirectory: URL,
        root: URL, account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        ownership: ClipboardWorkingOutputJournal, faults: ClipboardHistoryFaultInjector) throws -> ClipboardSyncFileCandidate {
        try ClipboardFileTreeDecoding.decode(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
            account: account, control: control, key: key, destination: nil)
        let (directory, url) = try openDirectory(root: root, accountID: account.identifier, descriptor: descriptor)
        defer { close(directory) }
        try ownership.recover(directory: url, descriptor: descriptor) { replay in
            try ClipboardFileTreeDecoding.decode(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
                account: account, control: control, key: key, destination: nil, replay: replay)
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let destination = url.appendingPathComponent(descriptor.displayName)
        var status = stat()
        if fstatat(directory, descriptor.displayName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            let tree = try ClipboardFileTree(destination)
            let measurement = try tree.stream { _ in }
            guard measurement.digest == descriptor.contentDigest, measurement.original == descriptor.originalByteCount else {
                throw ClipboardHistoryStorageError.fileOperationFailed(EEXIST)
            }
            return .init(directory: url, name: descriptor.displayName, pendingName: nil,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(status), treeWitness: tree)
        }
        guard errno == ENOENT else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        let owner = try ownership.reserve(directory: directory, url: url, descriptor: descriptor)
        let name = owner.name
        let pending = url.appendingPathComponent(name)
        do {
            let created = try ClipboardFileTreeDecoding.decode(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
                account: account, control: control, key: key, destination: pending, faults: faults, destinationParent: directory,
                rootCreated: { fd in
                    try owner.created(fd)
                    try faults.check(.syncWorkingOutputAfterOwnership)
                }, ownership: owner)
            let tree = try ClipboardFileTree(pending)
            let measurement = try tree.stream { _ in }
            guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  fsync(directory) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            guard measurement.digest == descriptor.contentDigest, measurement.original == descriptor.originalByteCount,
                  measurement.encoded == descriptor.encodedByteCount,
                  status.st_dev == created?.device, status.st_ino == created?.inode else { throw ClipboardSyncServiceError.localStorage }
            try owner.checkpoint(snapshot: .init(status), tree: tree, descriptor: descriptor)
            return .init(directory: url, name: descriptor.displayName, pendingName: name,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(status), treeWitness: tree, ownership: owner)
        } catch { try? owner.recover(); throw error }
    }

    /// Completion is still unpublished in the store. The recursive proof runs
    /// off the module actor; a revoke can complete while it reads metadata.
    @concurrent
    static func verifyPublished(_ file: ClipboardSyncPublishedFile, candidate: ClipboardSyncFileCandidate,
        faults: ClipboardHistoryFaultInjector) async throws {
        guard let tree = candidate.treeWitness else { return }
        try faults.check(.syncFileTreeBeforeOutputVerification)
        try Task.checkCancellation()
        try tree.verify(at: file.url, afterExchange: true)
    }
}
