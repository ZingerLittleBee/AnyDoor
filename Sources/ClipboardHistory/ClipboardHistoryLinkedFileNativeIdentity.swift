import Darwin
import Foundation

/// Resource identifiers are not persistent across OS restarts. On filesystems
/// with persistent IDs, a mounted volume UUID plus object ID and birth stamp
/// can locate the same object. Document IDs can transfer to a new occupant of
/// the old path, so they never authorize adopting a different filesystem object.
struct ClipboardLinkedNativeIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String
    let fileID: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let supportsPersistentIDs: Bool

    static func read(_ url: URL, status: stat) throws -> Self? {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeSupportsPersistentIDsKey,
        ])
        guard let volumeUUID = values.volumeUUIDString else { return nil }
        return Self(volumeUUID: volumeUUID, fileID: UInt64(status.st_ino),
            birthSeconds: Int64(status.st_birthtimespec.tv_sec), birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec),
            supportsPersistentIDs: values.volumeSupportsPersistentIDs == true)
    }

    func provesContinuity(with current: Self) -> Bool {
        guard volumeUUID == current.volumeUUID else { return false }
        if supportsPersistentIDs, current.supportsPersistentIDs, fileID == current.fileID,
           birthSeconds == current.birthSeconds, birthNanoseconds == current.birthNanoseconds { return true }
        return false
    }

    /// Only consult already mounted, non-autofs filesystems. fsgetpath does not
    /// mount a missing volume, and its result still requires native proof.
    func locate() -> URL? {
        guard supportsPersistentIDs else { return nil }
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return nil }
        var mounts: [statfs] = .init(repeating: statfs(), count: Int(capacity) + 8)
        let count = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard count > 0 else { return nil }
        for index in 0..<min(Int(count), mounts.count) {
            var mount = mounts[index]
            let type = withUnsafeBytes(of: mount.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type != "autofs" else { continue }
            let path = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let root = URL(fileURLWithPath: path)
            guard (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volumeUUID else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = fsgetpath(&buffer, buffer.count, &mount.f_fsid, fileID)
            guard length > 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let candidate = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            var status = stat()
            guard lstat(candidate.path, &status) == 0,
                  let current = try? Self.read(candidate, status: status),
                  current.volumeUUID == volumeUUID, current.fileID == fileID,
                  current.birthSeconds == birthSeconds, current.birthNanoseconds == birthNanoseconds else { continue }
            return candidate
        }
        return nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

enum ClipboardLinkedIdentityResolution {
    static func inspect(_ source: ClipboardLinkedLocationSource) throws -> ClipboardLinkedFileProof {
        var stale = false
        let bookmarkURL = try? URL(resolvingBookmarkData: source.bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        var candidates = [bookmarkURL, source.url].compactMap { $0 }
        if let located = source.nativeIdentity?.locate() { candidates.insert(located, at: 0) }
        var visited = Set<String>()
        for url in candidates where visited.insert(url.path).inserted {
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            let native = try ClipboardLinkedNativeIdentity.read(url, status: status)
            let sameObject = ClipboardSyncFileIO.isAvailable(path: url.path, identity: source.identity)
            guard sameObject || native.map({ source.nativeIdentity?.provesContinuity(with: $0) == true }) == true else { continue }
            let proof = try ClipboardLinkedFileIO.inspect(url, expectedIdentity: sameObject ? source.identity : nil)
            guard sameObject || proof.nativeIdentity.map({ source.nativeIdentity?.provesContinuity(with: $0) == true }) == true else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            return proof
        }
        throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
    }
}
