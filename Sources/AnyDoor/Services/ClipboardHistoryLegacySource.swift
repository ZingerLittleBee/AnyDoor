import ClipboardHistory
import Foundation
import SwiftData

enum ClipboardHistoryLegacySourceError: Error {
    case incompleteSnapshot
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

    private let payloadDirectory: URL
    private let snapshotDirectory: URL
    private let container: ModelContainer?

    init(
        applicationSupportDirectory: URL,
        productionStoreURL: URL,
        legacySchema: Schema,
        payloadDirectory: URL
    ) throws {
        self.payloadDirectory = payloadDirectory
        snapshotDirectory = applicationSupportDirectory
            .appendingPathComponent(
                Self.snapshotDirectoryName,
                isDirectory: true
            )
        try Self.prepareSnapshotIfNeeded(
            sourceStoreURL: productionStoreURL,
            snapshotDirectory: snapshotDirectory
        )
        let snapshotStoreURL = snapshotDirectory
            .appendingPathComponent(Self.snapshotStoreName)
        if FileManager.default.fileExists(atPath: snapshotStoreURL.path) {
            container = try ModelContainer(
                for: legacySchema,
                configurations: ModelConfiguration(url: snapshotStoreURL)
            )
        } else {
            container = nil
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
}
