import Darwin
import Foundation

extension ClipboardSyncFilePublication {
    static func constructTree(descriptor: ClipboardSyncFileDescriptor, encryptedDirectory: URL,
        root: URL, account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data) throws -> ClipboardSyncFileCandidate {
        try ClipboardFileTreeDecoding.decode(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
            account: account, control: control, key: key, destination: nil)
        let (directory, url) = try openDirectory(root: root, accountID: account.identifier, descriptor: descriptor)
        defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw ClipboardSyncServiceError.localStorage }
        let destination = url.appendingPathComponent(descriptor.displayName)
        var status = stat()
        if fstatat(directory, descriptor.displayName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            let measurement = try ClipboardFileTree(destination).stream { _ in }
            guard measurement.digest == descriptor.contentDigest, measurement.original == descriptor.originalByteCount else { throw ClipboardSyncServiceError.localStorage }
            return .init(directory: url, name: descriptor.displayName, pendingName: nil,
                parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(status))
        }
        guard errno == ENOENT else { throw ClipboardSyncServiceError.localStorage }
        let name = "Receiving-\(UUID().uuidString).partial"
        let pending = url.appendingPathComponent(name)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: pending) } }
        try ClipboardFileTreeDecoding.decode(descriptor: descriptor, encryptedDirectory: encryptedDirectory,
            account: account, control: control, key: key, destination: pending)
        let measurement = try ClipboardFileTree(pending).stream { _ in }
        guard measurement.digest == descriptor.contentDigest, measurement.original == descriptor.originalByteCount,
              measurement.encoded == descriptor.encodedByteCount,
              fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0, fsync(directory) == 0 else { throw ClipboardSyncServiceError.localStorage }
        succeeded = true
        return .init(directory: url, name: descriptor.displayName, pendingName: name,
            parentDevice: parent.st_dev, parentInode: parent.st_ino, snapshot: .init(status))
    }
}
