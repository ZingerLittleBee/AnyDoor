import Darwin
import Foundation

/// Resource identifiers are not persistent across OS restarts. On filesystems
/// with persistent IDs, a mounted volume UUID plus object ID and birth stamp
/// can locate the same object. Document IDs can transfer to a new occupant of
/// the old path, so they never authorize adopting a different filesystem object.
struct ClipboardLinkedNativeIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String?
    let fileID: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let supportsPersistentIDs: Bool
    let bootSessionID: UUID?
    let deviceID: Int32?

    private static let currentBootSessionID: UUID? = {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &count, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return UUID(uuidString: String(decoding: bytes, as: UTF8.self))
    }()

    static func read(_ url: URL, status: stat) throws -> Self? {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeSupportsPersistentIDsKey,
        ])
        return Self(volumeUUID: values.volumeUUIDString, fileID: UInt64(status.st_ino),
            birthSeconds: Int64(status.st_birthtimespec.tv_sec), birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec),
            supportsPersistentIDs: values.volumeSupportsPersistentIDs == true,
            bootSessionID: currentBootSessionID, deviceID: status.st_dev)
    }

    func provesContinuity(with current: Self) -> Bool {
        guard fileID == current.fileID, birthSeconds == current.birthSeconds,
              birthNanoseconds == current.birthNanoseconds else { return false }
        if let volumeUUID, volumeUUID == current.volumeUUID,
           supportsPersistentIDs, current.supportsPersistentIDs { return true }
        // An unsupported filesystem's opaque identity is only meaningful within
        // the same boot and device, never a cross-reboot persistence promise.
        return bootSessionID != nil && bootSessionID == current.bootSessionID
            && deviceID != nil && deviceID == current.deviceID
    }

    /// Only consult already mounted, non-autofs filesystems. fsgetpath does not
    /// mount a missing volume, and its result still requires native proof.
    func lookup() -> (mounted: Bool, candidate: URL?) {
        var mounted = false
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return (false, nil) }
        var mounts: [statfs] = .init(repeating: statfs(), count: Int(capacity) + 8)
        let count = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard count > 0 else { return (false, nil) }
        for index in 0..<min(Int(count), mounts.count) {
            var mount = mounts[index]
            let type = withUnsafeBytes(of: mount.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type != "autofs" else { continue }
            let path = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let root = URL(fileURLWithPath: path)
            if let volumeUUID {
                guard (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volumeUUID else { continue }
            } else {
                var rootStatus = stat()
                guard bootSessionID != nil, bootSessionID == Self.currentBootSessionID,
                      let deviceID, lstat(root.path, &rootStatus) == 0,
                      rootStatus.st_dev == deviceID else { continue }
            }
            mounted = true
            guard supportsPersistentIDs, let volumeUUID else { continue }
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
            return (true, candidate)
        }
        return (mounted, nil)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

struct ClipboardLinkedFileIdentityEvent: Sendable {
    let identity: Data
    let candidate: URL?
    let unlinked: Bool
}

enum ClipboardLinkedIdentityFailure: Error {
    case removed
    case replaced
    case unavailable
}

enum ClipboardLinkedIdentityResolution {
    static func isAvailable(path: String, identity: Data, nativeIdentity: Data?) -> Bool {
        if let nativeIdentity {
            guard let expected = try? JSONDecoder().decode(ClipboardLinkedNativeIdentity.self, from: nativeIdentity),
                  expected.lookup().mounted else { return false }
            var status = stat()
            guard lstat(path, &status) == 0,
                  let current = try? ClipboardLinkedNativeIdentity.read(URL(fileURLWithPath: path), status: status),
                  expected.provesContinuity(with: current) else { return false }
        }
        return access(path, R_OK) == 0 && ClipboardSyncFileIO.isAvailable(path: path, identity: identity)
    }

    static func inspect(_ source: ClipboardLinkedLocationSource, event: ClipboardLinkedFileIdentityEvent? = nil,
        faults: ClipboardHistoryFaultInjector = .init()) throws -> ClipboardLinkedFileProof {
        var stale = false
        let bookmarkURL = try? URL(resolvingBookmarkData: source.bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        let lookup = source.nativeIdentity?.lookup()
        guard lookup?.mounted != false else { throw ClipboardLinkedIdentityFailure.unavailable }
        let candidates = [source.url, event?.candidate, bookmarkURL, lookup?.candidate].compactMap { $0 }
        var visited = Set<String>()
        for url in candidates where visited.insert(url.path).inserted {
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(status.st_mode & mode_t(S_IFMT)) else { continue }
            let native = try ClipboardLinkedNativeIdentity.read(url, status: status)
            let sameObject = ClipboardSyncFileIO.isAvailable(path: url.path, identity: source.identity)
            let proven = source.nativeIdentity.map { expected in native.map { expected.provesContinuity(with: $0) } == true } ?? sameObject
            guard proven else { continue }
            try faults.check(.linkedFileObservationBeforeContentRead)
            let proof = try ClipboardLinkedFileIO.inspect(url, expectedIdentity: sameObject ? source.identity : nil)
            guard source.nativeIdentity.map({ expected in proof.nativeIdentity.map { expected.provesContinuity(with: $0) } == true }) ?? sameObject else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            var relationship: FileManager.URLRelationship = .other
            try FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [], toItemAt: proof.url)
            guard relationship != .contains && relationship != .same else { throw ClipboardLinkedIdentityFailure.removed }
            return proof
        }
        var occupant = stat()
        if lstat(source.url.path, &occupant) == 0 {
            if let expected = source.nativeIdentity,
               let current = try? ClipboardLinkedNativeIdentity.read(source.url, status: occupant),
               current.volumeUUID != expected.volumeUUID { throw ClipboardLinkedIdentityFailure.unavailable }
            throw ClipboardLinkedIdentityFailure.replaced
        }
        let missing = errno == ENOENT
        let parent = source.url.deletingLastPathComponent()
        var parentStatus = stat()
        if missing, event?.unlinked == true, let expected = source.nativeIdentity,
           lstat(parent.path, &parentStatus) == 0, parentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
           access(parent.path, R_OK | X_OK) == 0,
           let current = try? ClipboardLinkedNativeIdentity.read(parent, status: parentStatus),
           current.volumeUUID == expected.volumeUUID,
           lstat(source.url.path, &occupant) != 0, errno == ENOENT {
            throw ClipboardLinkedIdentityFailure.removed
        }
        throw ClipboardLinkedIdentityFailure.unavailable
    }
}
