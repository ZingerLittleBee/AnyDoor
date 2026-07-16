import CryptoKit
import Darwin
import Foundation

/// One committed, verified final output file.
public struct CommittedOutput: Hashable, Sendable {
    public var url: URL
    var byteCount: Int64
    var sha256: String
}

enum AtomicOutputWriterError: Error, Equatable {
    case directoryUnavailable(String)
    case artifactUnreadable(String)
    case stagingFailed(code: Int32)
    case stagingWriteFailed(code: Int32)
    /// Streamed bytes/digest differ from the immutable candidate metadata.
    case contentMismatch
    case cancelled
    /// Neither exclusive rename nor hard-link creation is supported here.
    /// V1 never falls back to a TOCTOU-prone move that might replace a
    /// competing file.
    case exclusiveCommitUnsupported
    case commitFailed(code: Int32)
    case nameCandidatesExhausted
}

/// Owns output naming and commit as one operation, eliminating the
/// check-then-write race: the final name is claimed by an exclusive
/// rename/link of an already-verified staging inode, never by an existence
/// check followed by a write.
struct AtomicOutputWriter: Sendable {
    /// An immutable candidate artifact: a private temporary file plus the
    /// byte count and SHA-256 recorded when it was materialized.
    struct CandidateArtifact: Hashable, Sendable {
        var artifactURL: URL
        var byteCount: Int64
        var sha256: String
    }

    /// Where the final file goes and what it should be called. Collisions
    /// walk Finder-style names: `base.ext`, `base 2.ext`, `base 3.ext`, …
    struct DestinationPolicy: Hashable, Sendable {
        var directory: URL
        var baseName: String
        var fileExtension: String
    }

    private static let maxStagingRetries = 64
    private static let maxNameCandidates = 10_000

    /// Commit the artifact to its final name. `isCancelled` is consulted once
    /// more immediately before the irreversible commit; a successful return is
    /// the end of the fallible content path.
    func commit(
        _ artifact: CandidateArtifact,
        to destination: DestinationPolicy,
        isCancelled: () -> Bool = { false }
    ) throws -> CommittedOutput {
        let directoryPath = destination.directory.path
        let directoryFD = open(directoryPath, O_DIRECTORY | O_RDONLY)
        guard directoryFD >= 0 else {
            throw AtomicOutputWriterError.directoryUnavailable(directoryPath)
        }
        defer { close(directoryFD) }

        // 1. Exclusive hidden staging file relative to the directory
        // descriptor. EEXIST retries a fresh UUID — UUID probability is never
        // treated as the no-overwrite guarantee.
        var stagingName = ""
        var fileFD: Int32 = -1
        for _ in 0..<Self.maxStagingRetries {
            let name = ".anydoor-staging-\(UUID().uuidString)"
            let fd = name.withCString {
                openat(directoryFD, $0, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, mode_t(0o600))
            }
            if fd >= 0 {
                stagingName = name
                fileFD = fd
                break
            }
            guard errno == EEXIST else {
                throw AtomicOutputWriterError.stagingFailed(code: errno)
            }
        }
        guard fileFD >= 0 else { throw AtomicOutputWriterError.stagingFailed(code: EEXIST) }

        var committed = false
        defer {
            close(fileFD)
            if !committed {
                _ = stagingName.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }

        // 2. Stream the candidate into staging while recounting bytes and
        // SHA-256; any mismatch with the immutable metadata aborts with no
        // visible output.
        guard let source = try? FileHandle(forReadingFrom: artifact.artifactURL) else {
            throw AtomicOutputWriterError.artifactUnreadable(artifact.artifactURL.path)
        }
        defer { try? source.close() }

        var streamedBytes: Int64 = 0
        var hasher = SHA256()
        while let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = write(fileFD, raw.baseAddress! + offset, raw.count - offset)
                    guard written > 0 else {
                        throw AtomicOutputWriterError.stagingWriteFailed(code: errno)
                    }
                    offset += written
                }
            }
            hasher.update(data: chunk)
            streamedBytes += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard streamedBytes == artifact.byteCount, digest == artifact.sha256 else {
            throw AtomicOutputWriterError.contentMismatch
        }

        // 3. Flush the verified staging inode for durability before it can
        // become visible under a final name.
        if fcntl(fileFD, F_FULLFSYNC) != 0 {
            _ = fsync(fileFD)
        }

        // 4. Final cancellation gate: after this point the commit is
        // irreversible and the item counts as completed.
        if isCancelled() { throw AtomicOutputWriterError.cancelled }

        // 5–8. Claim a final name with an exclusive rename; fall back to an
        // exclusive hard link when the filesystem lacks renameatx_np. Every
        // EEXIST — file, symlink, or a name claimed by another process — is a
        // collision that advances to the next Finder-style name with the same
        // verified inode.
        var renameSupported = true
        for index in 1...Self.maxNameCandidates {
            let finalName = index == 1
                ? "\(destination.baseName).\(destination.fileExtension)"
                : "\(destination.baseName) \(index).\(destination.fileExtension)"

            if renameSupported {
                let result = stagingName.withCString { old in
                    finalName.withCString { new in
                        renameatx_np(directoryFD, old, directoryFD, new, UInt32(RENAME_EXCL))
                    }
                }
                if result == 0 {
                    committed = true
                    _ = fsync(directoryFD)
                    return CommittedOutput(
                        url: destination.directory.appendingPathComponent(finalName),
                        byteCount: streamedBytes,
                        sha256: digest
                    )
                }
                switch errno {
                case EEXIST:
                    continue
                case ENOTSUP:
                    renameSupported = false
                    // Retry this same name via the link path below.
                default:
                    throw AtomicOutputWriterError.commitFailed(code: errno)
                }
            }

            if !renameSupported {
                let result = stagingName.withCString { old in
                    finalName.withCString { new in
                        linkat(directoryFD, old, directoryFD, new, 0)
                    }
                }
                if result == 0 {
                    _ = stagingName.withCString { unlinkat(directoryFD, $0, 0) }
                    committed = true
                    _ = fsync(directoryFD)
                    return CommittedOutput(
                        url: destination.directory.appendingPathComponent(finalName),
                        byteCount: streamedBytes,
                        sha256: digest
                    )
                }
                switch errno {
                case EEXIST:
                    continue
                case ENOTSUP, EPERM, EMLINK:
                    throw AtomicOutputWriterError.exclusiveCommitUnsupported
                default:
                    throw AtomicOutputWriterError.commitFailed(code: errno)
                }
            }
        }
        throw AtomicOutputWriterError.nameCandidatesExhausted
    }
}
