import ClipboardHistory
import Darwin
import Foundation
import SwiftData

enum ClipboardHistoryLegacySourceError: Error {
    case incompleteSnapshot
    case cutoverMarkerPersistenceFailed(Int32)
}

/// A crash-resilient, read-only snapshot of the pre-v2 SwiftData store.
///
/// The production ModelContainer can remove the legacy model immediately
/// without making a failed first-launch migration destructive. The snapshot
/// is deleted only after the encrypted migration is published and every
/// plaintext payload has an independently verified retained copy.
final class ClipboardHistoryLegacySource {
    private static let snapshotDirectoryName =
        "ClipboardHistoryLegacyMigration"
    private static let snapshotStoreName = "AnyDoorLegacy.store"
    private static let snapshotPayloadDirectoryName = "Payloads"
    private static let cutoverMarkerName =
        "ClipboardHistoryLegacyCutover-v1.complete"

    private let payloadDirectory: URL
    private let snapshotDirectory: URL
    private let container: ModelContainer?

    /// Resolves the cutover before any legacy `ModelContainer` is opened.
    ///
    /// A completed marker is authoritative because `finishMigration()` makes
    /// it durable only after publication and cleanup have succeeded. A
    /// leftover snapshot is best-effort cleanup at that point, never a reason
    /// to reopen the removed schema.
    static func openIfNeeded(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
        legacySchema: Schema,
        payloadDirectory: URL
    ) throws -> ClipboardHistoryLegacySource? {
        let markerURL = cutoverMarkerURL(
            in: applicationSupportDirectory
        )
        guard !FileManager.default.fileExists(atPath: markerURL.path)
        else {
            try? FileManager.default.removeItem(
                at: snapshotDirectory(in: applicationSupportDirectory)
            )
            return nil
        }
        return try ClipboardHistoryLegacySource(
            applicationSupportDirectory: applicationSupportDirectory,
            productionStoreURL: productionStoreURL,
            legacySchema: legacySchema,
            payloadDirectory: payloadDirectory
        )
    }

    private init(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
        legacySchema: Schema,
        payloadDirectory legacyPayloadDirectory: URL
    ) throws {
        snapshotDirectory = applicationSupportDirectory
            .appendingPathComponent(
                Self.snapshotDirectoryName,
                isDirectory: true
            )
        payloadDirectory = snapshotDirectory.appendingPathComponent(
            Self.snapshotPayloadDirectoryName,
            isDirectory: true
        )
        try Self.prepareSnapshotIfNeeded(
            sourceStoreURL: productionStoreURL,
            snapshotDirectory: snapshotDirectory
        )
        let snapshotStoreURL = snapshotDirectory
            .appendingPathComponent(Self.snapshotStoreName)
        if FileManager.default.fileExists(atPath: snapshotStoreURL.path) {
            try Self.moveLegacyPayloadsIntoSnapshot(
                from: legacyPayloadDirectory,
                to: payloadDirectory
            )
            container = try ModelContainer(
                for: legacySchema,
                configurations: ModelConfiguration(url: snapshotStoreURL)
            )
        } else {
            container = nil
        }
    }

    private static func moveLegacyPayloadsIntoSnapshot(
        from sourceDirectory: URL,
        to snapshotPayloadDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: snapshotPayloadDirectory,
            withIntermediateDirectories: true
        )
        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            return
        }
        let children = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        let hasV2Store = children.contains {
            $0.lastPathComponent == "history.sqlite"
        }
        let v2Names: Set<String> = [
            "history.sqlite",
            "history.sqlite-wal",
            "history.sqlite-shm",
            "payloads",
            "staging",
        ]
        for child in children {
            if hasV2Store, v2Names.contains(child.lastPathComponent) {
                continue
            }
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                values.isDirectory != true,
                values.isSymbolicLink != true
            else {
                throw ClipboardHistoryLegacySourceError.incompleteSnapshot
            }
            let destination = snapshotPayloadDirectory
                .appendingPathComponent(child.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ClipboardHistoryLegacySourceError.incompleteSnapshot
            }
            try fileManager.moveItem(at: child, to: destination)
        }
    }

    @MainActor
    func makeMigrationRequest(
        defaults: UserDefaults = .standard
    ) throws -> ClipboardHistoryLegacyMigrationRequest {
        guard let container else {
            return ClipboardHistoryLegacyMigrationRequest(
                transfer: ClipboardHistoryLegacyTransfer(
                    entries: [],
                    tags: [],
                    categoryOrder: [],
                    retentionPeriod: .default
                ),
                payloadDirectory: payloadDirectory
            )
        }
        return try ClipboardHistoryLegacyAdapter.makeMigrationRequest(
            modelContext: container.mainContext,
            defaults: defaults,
            payloadDirectory: payloadDirectory
        )
    }

    @MainActor
    func finishMigration() throws {
        // Persist completion before deleting the snapshot. If marker
        // persistence fails, every readable legacy row remains available for
        // the next launch. If snapshot deletion fails after the marker, the
        // next launch retries only that deletion without opening its schema.
        try Self.persistCutoverMarker(
            in: snapshotDirectory.deletingLastPathComponent()
        )
        guard FileManager.default.fileExists(
            atPath: snapshotDirectory.path
        ) else {
            return
        }
        try FileManager.default.removeItem(at: snapshotDirectory)
    }

    static func snapshotDirectory(
        in applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory.appendingPathComponent(
            snapshotDirectoryName,
            isDirectory: true
        )
    }

    private static func prepareSnapshotIfNeeded(
        sourceStoreURL: URL,
        snapshotDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let snapshotStoreURL = snapshotDirectory
            .appendingPathComponent(snapshotStoreName)
        if fileManager.fileExists(atPath: snapshotStoreURL.path) {
            return
        }
        guard fileManager.fileExists(atPath: sourceStoreURL.path) else {
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                try fileManager.removeItem(at: snapshotDirectory)
            }
            return
        }

        let parent = snapshotDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let stagingDirectory = parent.appendingPathComponent(
            ".\(snapshotDirectoryName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        do {
            for suffix in ["", "-wal", "-shm"] {
                let sourceURL = URL(
                    fileURLWithPath: sourceStoreURL.path + suffix
                )
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    continue
                }
                let destinationName = snapshotStoreName + suffix
                try fileManager.copyItem(
                    at: sourceURL,
                    to: stagingDirectory
                        .appendingPathComponent(destinationName)
                )
            }
            guard fileManager.fileExists(
                atPath: stagingDirectory
                    .appendingPathComponent(snapshotStoreName).path
            ) else {
                throw ClipboardHistoryLegacySourceError.incompleteSnapshot
            }
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                try fileManager.removeItem(at: snapshotDirectory)
            }
            try fileManager.moveItem(
                at: stagingDirectory,
                to: snapshotDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func cutoverMarkerURL(
        in applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory.appendingPathComponent(
            cutoverMarkerName
        )
    }

    private static func persistCutoverMarker(
        in applicationSupportDirectory: URL
    ) throws {
        let markerURL = cutoverMarkerURL(
            in: applicationSupportDirectory
        )
        guard !FileManager.default.fileExists(atPath: markerURL.path)
        else {
            return
        }
        let stagingURL = applicationSupportDirectory
            .appendingPathComponent(
                ".\(cutoverMarkerName)-\(UUID().uuidString)"
            )
        let descriptor = Darwin.open(
            stagingURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        var closeRequired = true
        defer {
            if closeRequired {
                Darwin.close(descriptor)
            }
            try? FileManager.default.removeItem(at: stagingURL)
        }
        let marker = Data("completed\n".utf8)
        let writeSucceeded = marker.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    return false
                }
                written += result
            }
            return true
        }
        guard writeSucceeded else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0
            || Darwin.fsync(descriptor) == 0
        else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        let closeResult = Darwin.close(descriptor)
        closeRequired = false
        guard closeResult == 0 else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        guard Darwin.rename(stagingURL.path, markerURL.path) == 0 else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        let directoryDescriptor = Darwin.open(
            applicationSupportDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
        defer {
            Darwin.close(directoryDescriptor)
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw ClipboardHistoryLegacySourceError
                .cutoverMarkerPersistenceFailed(errno)
        }
    }
}
