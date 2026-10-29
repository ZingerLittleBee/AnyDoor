import Darwin
import Foundation

/// Short-lived hints for the overflow observer only. Explicit refresh, provider
/// reconciliation, native events and every publication still prove saved bytes.
/// Retain no file handles or plaintext inventory between observations.
struct ClipboardLinkedObservationCache: Sendable {
    enum Fingerprint: Equatable, Sendable {
        case file(ClipboardSyncFileSnapshot)
        case tree(Data)

        static func read(_ url: URL) throws -> Self {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                return .tree(try ClipboardFileTree(url).observationFingerprint())
            }
            return .file(.init(status))
        }
    }

    let source: ClipboardLinkedLocationSource
    let fingerprint: Fingerprint
    let checkedAt: ContinuousClock.Instant

    init(source: ClipboardLinkedLocationSource, proof: ClipboardLinkedFileProof,
        now: ContinuousClock.Instant = .now) throws {
        self.source = source
        checkedAt = now
        if proof.observationSnapshot.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), let tree = proof.treeWitness {
            fingerprint = .tree(try tree.observationFingerprint())
        } else {
            fingerprint = .file(proof.observationSnapshot)
        }
    }

    func isUnchanged(_ current: ClipboardLinkedLocationSource, now: ContinuousClock.Instant = .now) throws -> Bool {
        guard now - checkedAt < .seconds(300),
              current.id == source.id, current.revision == source.revision,
              current.url == source.url, current.identity == source.identity,
              current.nativeIdentity == source.nativeIdentity, current.baseVersionID == source.baseVersionID,
              current.baseDigest == source.baseDigest else { return false }
        return try Fingerprint.read(current.url) == fingerprint
    }
}
