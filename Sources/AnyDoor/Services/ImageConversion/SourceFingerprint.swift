import CryptoKit
import Foundation

/// Proof that a conversion source is unchanged between an exact preview and
/// the final commit. A candidate may be reused only when the fingerprints
/// match; the engine revalidates immediately before the irreversible commit.
struct SourceFingerprint: Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case file(
            standardizedPath: String,
            resourceIdentifier: String?,
            fileSize: Int64,
            modificationDate: Date
        )
        case bitmap(basketItemID: UUID)
    }

    var origin: Origin
    /// SHA-256 of the source content, lowercase hex.
    var contentDigest: String

    enum FingerprintError: Error, Equatable {
        case unreadable(String)
    }

    static func forFile(at url: URL) throws -> SourceFingerprint {
        let standardized = url.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try standardized.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
            ])
        } catch {
            throw FingerprintError.unreadable(standardized.path)
        }
        let resourceIdentifier = (values.fileResourceIdentifier as? NSObject).map { "\($0)" }
        return SourceFingerprint(
            origin: .file(
                standardizedPath: standardized.path,
                resourceIdentifier: resourceIdentifier,
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            ),
            contentDigest: try streamedSHA256(of: standardized)
        )
    }

    static func forBitmap(_ data: Data, basketItemID: UUID) -> SourceFingerprint {
        SourceFingerprint(
            origin: .bitmap(basketItemID: basketItemID),
            contentDigest: hex(SHA256.hash(data: data))
        )
    }

    /// Streamed digest in 1 MiB chunks — an entire file is never loaded into
    /// memory solely to hash it.
    static func streamedSHA256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FingerprintError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
