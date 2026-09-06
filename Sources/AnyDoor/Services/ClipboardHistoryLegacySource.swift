import ClipboardHistory
import Darwin
import Foundation

enum ClipboardHistoryLegacySourceError: Error {
    case incompleteSnapshot
    case cutoverAlreadyCompleted
    case cutoverMarkerPersistenceFailed(Int32)
}

enum ClipboardHistoryLegacyCleanupState: Equatable {
    case incomplete
    case snapshotDeletionPending
    case completed
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
    /// The copied v1 store, or nil when there was never one to migrate.
    private let snapshotStoreURL: URL?

    /// Resolves the cutover before the legacy snapshot is opened.
    ///
    /// A completed marker is authoritative because `finishMigration()` makes
    /// it durable only after publication and cleanup have succeeded. A
    /// leftover snapshot is retried as a visible filesystem operation, never
    /// a reason to reread the removed schema.
    static func openIfNeeded(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
        payloadDirectory: URL
    ) throws -> ClipboardHistoryLegacySource? {
        switch cleanupState(in: applicationSupportDirectory) {
        case .completed:
            return nil
        case .snapshotDeletionPending:
            try retrySnapshotDeletion(
                in: applicationSupportDirectory
            )
            return nil
        case .incomplete:
            return try openForMigration(
                applicationSupportDirectory: applicationSupportDirectory,
                productionStoreURL: productionStoreURL,
                payloadDirectory: payloadDirectory
            )
        }
    }

    static func openForMigration(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
        payloadDirectory: URL
    ) throws -> ClipboardHistoryLegacySource {
        guard cleanupState(in: applicationSupportDirectory) == .incomplete
        else {
            throw ClipboardHistoryLegacySourceError
                .cutoverAlreadyCompleted
        }
        return try ClipboardHistoryLegacySource(
            applicationSupportDirectory: applicationSupportDirectory,
            productionStoreURL: productionStoreURL,
            payloadDirectory: payloadDirectory
        )
    }

    private init(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
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
        let storeURL = snapshotDirectory
            .appendingPathComponent(Self.snapshotStoreName)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try Self.moveLegacyPayloadsIntoSnapshot(
                from: legacyPayloadDirectory,
                to: payloadDirectory
            )
            snapshotStoreURL = storeURL
        } else {
            snapshotStoreURL = nil
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
        // No snapshot means there was never a v1 store, so there is nothing to
        // carry over — not even the v1 settings, which only ever described
        // history this install never had.
        guard let snapshotStoreURL else {
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
            storeURL: snapshotStoreURL,
            defaults: defaults,
            payloadDirectory: payloadDirectory
        )
    }

    @MainActor
    func finishMigration() throws {
        try Self.finishMigration(
            in: snapshotDirectory.deletingLastPathComponent()
        )
    }

    static func snapshotDirectory(
        in applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory.appendingPathComponent(
            snapshotDirectoryName,
            isDirectory: true
        )
    }

    static func snapshotPayloadDirectory(
        in applicationSupportDirectory: URL
    ) -> URL {
        snapshotDirectory(in: applicationSupportDirectory)
            .appendingPathComponent(
                snapshotPayloadDirectoryName,
                isDirectory: true
            )
    }

    static func prepareSnapshotIfNeeded(
        applicationSupportDirectory: URL,
        productionStoreURL: URL
    ) throws {
        guard cleanupState(in: applicationSupportDirectory) == .incomplete
        else {
            return
        }
        try prepareSnapshotIfNeeded(
            sourceStoreURL: productionStoreURL,
            snapshotDirectory: snapshotDirectory(
                in: applicationSupportDirectory
            )
        )
    }

    static func cleanupState(
        in applicationSupportDirectory: URL
    ) -> ClipboardHistoryLegacyCleanupState {
        let fileManager = FileManager.default
        let markerExists = fileManager.fileExists(
            atPath: cutoverMarkerURL(
                in: applicationSupportDirectory
            ).path
        )
        guard markerExists else {
            return .incomplete
        }
        return fileManager.fileExists(
            atPath: snapshotDirectory(
                in: applicationSupportDirectory
            ).path
        )
            ? .snapshotDeletionPending
            : .completed
    }

    static func finishMigration(
        in applicationSupportDirectory: URL
    ) throws {
        try persistCutoverMarker(in: applicationSupportDirectory)
        try retrySnapshotDeletion(in: applicationSupportDirectory)
    }

    static func retrySnapshotDeletion(
        in applicationSupportDirectory: URL
    ) throws {
        let directory = snapshotDirectory(
            in: applicationSupportDirectory
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
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
